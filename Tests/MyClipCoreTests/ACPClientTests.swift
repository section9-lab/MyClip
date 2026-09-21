import XCTest
@testable import MyClipCore

@MainActor
final class ACPClientTests: XCTestCase {
    func command(_ scenario: String = "success") -> ACPCommand {
        ACPCommand(executable: URL(fileURLWithPath: "/usr/bin/env"),
                   arguments: ["python3", Bundle.module.url(forResource: "acp_agent", withExtension: "py", subdirectory: "Fixtures")!.path],
                   environment: ["MYCLIP_ACP_SCENARIO": scenario])
    }

    func testImagePromptReceivesStreamAndCompletion() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        let handshake = try await client.connect(command: command())
        XCTAssertTrue(handshake.supportsImages)
        let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
        XCTAssertFalse(session.isEmpty)
        let response = try await client.prompt(sessionID: session, text: "整理截图", images: [fixtureImage().pngData])
        XCTAssertEqual(response.text, "你好，已整理")
        XCTAssertEqual(response.stopReason, "end_turn")
    }

    func testImageCapabilityMustBeNegotiated() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("no_images"))
        let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
        do {
            _ = try await client.prompt(sessionID: session, text: "image", images: [fixtureImage().pngData])
            XCTFail("Must not send images without advertised capability")
        } catch ACPError.unsupportedImages { }
    }

    func testPermissionRoundTripPreservesAgentOptionID() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        let received = expectation(description: "permission request")
        let observer = Task {
            for await event in client.events {
                if case .permission(let request) = event {
                    XCTAssertEqual(request.title, "查看来源")
                    try await client.respondToPermission(id: request.id, optionID: "allow1")
                    received.fulfill()
                }
            }
        }
        defer { observer.cancel() }
        _ = try await client.connect(command: command("permission"))
        let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
        let result = try await client.prompt(sessionID: session, text: "permission", images: [])
        XCTAssertEqual(result.text, "allow1")
        await fulfillment(of: [received], timeout: 2)
    }

    func testFullAccessApprovesRepeatedToolCallsWithoutPermissionEvents() async throws {
        for mode in ["agent-full-access", "bypassPermissions"] {
            let client = ACPClient()
            addTeardownBlock { await client.close() }
            let observer = Task {
                for await event in client.events {
                    if case .permission(let request) = event {
                        XCTFail("Full access must not require user confirmation")
                        try await client.respondToPermission(id: request.id, optionID: nil)
                    }
                }
            }
            defer { observer.cancel() }
            _ = try await client.connect(command: command("permission_choices"))
            let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
            try await client.setMode(sessionID: session, modeID: mode)
            for _ in 0..<2 {
                let result = try await client.prompt(sessionID: session, text: "read memory", images: [])
                XCTAssertEqual(result.text, "allow1", "Full access should allow each call without saving extra permission rules")
            }
            await client.close()
        }
    }

    func testFullAccessHandlesRemainingPermissionOptionsWithoutPrompting() async throws {
        for (scenario, expected) in [("permission_always", "always7"), ("permission_unavailable", "cancelled")] {
            let client = ACPClient()
            addTeardownBlock { await client.close() }
            let observer = Task {
                for await event in client.events {
                    if case .permission(let request) = event {
                        XCTFail("Full access must resolve tool permissions without a confirmation card")
                        try await client.respondToPermission(id: request.id, optionID: nil)
                    }
                }
            }
            defer { observer.cancel() }
            _ = try await client.connect(command: command(scenario))
            let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
            try await client.setMode(sessionID: session, modeID: "bypassPermissions")
            let result = try await client.prompt(sessionID: session, text: "read memory", images: [])
            XCTAssertEqual(result.text, expected, "Use a supported allow option, otherwise cancel instead of guessing")
            await client.close()
        }
    }

    func testFullAccessCancelsPermissionRequestsReceivedAfterCancellation() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        let observer = Task {
            for await event in client.events {
                switch event {
                case .tool: try await client.cancel(sessionID: "s1")
                case .permission(let request):
                    XCTFail("A cancelled task must not display or approve a late permission request")
                    try await client.respondToPermission(id: request.id, optionID: nil)
                default: break
                }
            }
        }
        defer { observer.cancel() }
        _ = try await client.connect(command: command("permission_after_cancel"))
        let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
        try await client.setMode(sessionID: session, modeID: "agent-full-access")
        let result = try await client.prompt(sessionID: session, text: "cancel before approval", images: [])
        XCTAssertEqual(result.text, "cancelled")
    }

    func testCancellationEndsPromptWithoutKillingConnection() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        let active = expectation(description: "active prompt")
        let observer = Task {
            for await event in client.events {
                if case .tool = event { active.fulfill() }
            }
        }
        defer { observer.cancel() }
        _ = try await client.connect(command: command("hang"))
        let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
        let prompt = Task { try await client.prompt(sessionID: session, text: "wait", images: []) }
        await fulfillment(of: [active], timeout: 2)
        try await client.cancel(sessionID: session)
        let result = try await prompt.value
        XCTAssertEqual(result.stopReason, "cancelled")
        let next = try await client.newSession(directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(next, "s1")
    }

    func testActivePromptCanFinishAfterInitialIdleWindow() async throws {
        let client = ACPClient(promptIdleTimeout: .milliseconds(600), promptMaximumDuration: .seconds(3))
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("slow_progress"))
        let result = try await client.prompt(sessionID: "s1", text: "compact then organize", images: [])
        XCTAssertEqual(result.text, "working:done")
        XCTAssertEqual(result.stopReason, "end_turn")
        // A completed prompt must not leave an expiry that closes an idle connection.
        try await Task.sleep(for: .milliseconds(700))
        let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(session, "s1")
    }

    func testSilentPromptStillTimesOutAndClosesConnection() async throws {
        let client = ACPClient(promptIdleTimeout: .milliseconds(400), promptMaximumDuration: .seconds(3))
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("hang"))
        do {
            _ = try await client.prompt(sessionID: "s1", text: "wait", images: [])
            XCTFail("A silent prompt must time out")
        } catch ACPError.timeout { }
        do {
            _ = try await client.newSession(directory: FileManager.default.temporaryDirectory)
            XCTFail("A timed-out process must be closed before another job starts")
        } catch ACPError.disconnected { }
    }

    func testUnrelatedOrUsageUpdatesDoNotKeepPromptAlive() async throws {
        for scenario in ["other_session_progress", "metadata_progress"] {
            let client = ACPClient(promptIdleTimeout: .milliseconds(400), promptMaximumDuration: .seconds(3))
            _ = try await client.connect(command: command(scenario))
            do {
                _ = try await client.prompt(sessionID: "s1", text: "wait", images: [])
                XCTFail("Unrelated or usage-only updates must not extend the idle timeout")
            } catch ACPError.timeout { }
            await client.close()
        }
    }

    func testContinuousProgressCannotExceedMaximumDuration() async throws {
        let client = ACPClient(promptIdleTimeout: .milliseconds(600), promptMaximumDuration: .milliseconds(1100))
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("continuous_progress"))
        let start = ContinuousClock.now
        do {
            _ = try await client.prompt(sessionID: "s1", text: "keep working", images: [])
            XCTFail("Even an active prompt must have an overall time limit")
        } catch ACPError.timeout { }
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(1000), "Progress should extend the idle window until the overall limit")
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testUnknownFractionalMetadataDoesNotBreakMessageStream() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("float_metadata"))
        let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
        let result = try await client.prompt(sessionID: session, text: "metadata", images: [])
        XCTAssertEqual(result.text, "你好，已整理")
    }

    func testCaptureToAgentToSearchableWikiPipeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let image = try fixtureImage()
        let context = fixtureContext()
        try await store.record(image: image, context: context, agent: .codex, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let inputs = try await store.captures(ids: job.sourceIDs)
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("knowledge"))
        let session = try await client.newSession(directory: root)
        let result = try await client.prompt(sessionID: session, text: KnowledgeComposer.prompt(captures: inputs, existing: []), images: [image.pngData])
        XCTAssertEqual(result.stopReason, "end_turn")
        try await store.commit(jobID: job.id, drafts: KnowledgeComposer.parse(result.text))
        let found = try await store.snapshot(query: "回车")
        XCTAssertEqual(found.entries.count, 1)
        XCTAssertEqual(found.entries.first?.sourceIDs, [context.id])
        XCTAssertEqual(found.jobs.first?.state, .completed)
    }

    func testProcessExitFailsPendingRequest() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("crash"))
        let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
        do {
            _ = try await client.prompt(sessionID: session, text: "crash", images: [])
            XCTFail("Pending request must fail when the process exits")
        } catch ACPError.disconnected { }
    }

    func testEachPromptReportsItsOwnUsageWithoutDoubleCountingThinking() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("usage"))
        let session = try await client.newSession(directory: FileManager.default.temporaryDirectory)
        for multiplier in 1...2 {
            let result = try await client.prompt(sessionID: session, text: "usage", images: [])
            let usage = try XCTUnwrap(result.usage)
            XCTAssertEqual(usage.totalTokens, 120 * multiplier)
            XCTAssertEqual(usage.inputTokens, 70 * multiplier)
            XCTAssertEqual(usage.outputTokens, 30 * multiplier)
            XCTAssertEqual(usage.cachedReadTokens, 20 * multiplier)
            XCTAssertEqual(usage.thoughtTokens, 10 * multiplier)
            XCTAssertNil(usage.cachedWriteTokens)
        }
    }

    func testComprehensiveModelUsageIncludesSubagentsOnlyOnce() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("model_usage"))
        let result = try await client.prompt(sessionID: "s1", text: "usage", images: [])
        XCTAssertEqual(result.usage?.totalTokens, 170)
        XCTAssertEqual(result.usage?.inputTokens, 90)
        XCTAssertEqual(result.usage?.cachedReadTokens, 35)
        XCTAssertEqual(result.usage?.cachedWriteTokens, 5)
        XCTAssertEqual(result.usage?.outputTokens, 40)
    }

    func testCodexQuotaReportsInputOutputAndCachedTokens() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("quota_usage"))
        let result = try await client.prompt(sessionID: "s1", text: "usage", images: [])
        XCTAssertEqual(result.usage?.totalTokens, 120)
        XCTAssertEqual(result.usage?.inputTokens, 90)
        XCTAssertEqual(result.usage?.outputTokens, 30)
        XCTAssertEqual(result.usage?.cachedReadTokens, 20)
        XCTAssertEqual(result.usage?.thoughtTokens, 10)
    }

    func testStatusOnlyToolUpdatePreservesItsTitle() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        let completed = expectation(description: "completed tool retains its command")
        let observer = Task {
            for await event in client.events {
                if case .tool(_, let title, let status) = event, status == "completed" {
                    XCTAssertEqual(title, "cat Memory/notes.md")
                    completed.fulfill()
                }
            }
        }
        defer { observer.cancel() }
        _ = try await client.connect(command: command("tool_details"))
        _ = try await client.prompt(sessionID: "s1", text: "inspect", images: [])
        await fulfillment(of: [completed], timeout: 2)
    }

    func testMalformedModelUsageFallsBackToPromptUsage() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("invalid_model_usage"))
        let result = try await client.prompt(sessionID: "s1", text: "usage", images: [])
        XCTAssertEqual(result.usage?.totalTokens, 15)
    }

    func testContextUsageIsNotTokenConsumption() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("context_usage"))
        let result = try await client.prompt(sessionID: "s1", text: "usage", images: [])
        XCTAssertNil(result.usage)
        XCTAssertEqual(result.stopReason, "end_turn")
    }

    func testInvalidOrMissingUsageDoesNotBreakCompletion() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command("invalid_usage"))
        for _ in 0..<4 {
            let result = try await client.prompt(sessionID: "s1", text: "usage", images: [])
            XCTAssertNil(result.usage)
            XCTAssertEqual(result.text, "你好，已整理")
        }
    }

    func testCancelledPromptStillReportsConsumedTokens() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        let observer = Task {
            for await event in client.events {
                if case .tool = event { await client.cancelAndClose(sessionID: "s1") }
            }
        }
        defer { observer.cancel() }
        _ = try await client.connect(command: command("cancel_usage"))
        let result = try await client.prompt(sessionID: "s1", text: "usage", images: [])
        XCTAssertEqual(result.stopReason, "cancelled")
        XCTAssertEqual(result.usage?.totalTokens, 12)
    }

    func testThinkingSignalsProgressWithoutBecomingResponseText() async throws {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        let thinking = expectation(description: "thinking progress")
        let observer = Task {
            for await event in client.events {
                if case .thinking(let session) = event {
                    XCTAssertEqual(session, "s1")
                    thinking.fulfill()
                }
            }
        }
        defer { observer.cancel() }
        _ = try await client.connect(command: command("thinking"))
        let result = try await client.prompt(sessionID: "s1", text: "think", images: [])
        XCTAssertEqual(result.text, "你好，已整理")
        await fulfillment(of: [thinking], timeout: 2)
    }

    func testConnectionRefusedExplainsAgentProxyFailure() {
        let raw = "Internal error: API Error: Connection refused (ConnectionRefused)"
        let message = ACPError.remote(code: -32603, message: raw).localizedDescription
        XCTAssertTrue(message.contains("服务或代理"))
        XCTAssertTrue(message.contains(raw))
    }

    func testUnavailableModelExplainsConfigurationFailure() {
        let raw = "503 No available channel for model claude-opus-5"
        let message = ACPError.remote(code: -32603, message: raw).localizedDescription
        XCTAssertTrue(message.contains("模型不可用"))
        XCTAssertTrue(message.contains(raw))
    }
}
