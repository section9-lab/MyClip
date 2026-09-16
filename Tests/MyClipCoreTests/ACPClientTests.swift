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
}
