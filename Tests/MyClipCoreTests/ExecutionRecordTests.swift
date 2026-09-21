import XCTest
@testable import MyClipCore

@MainActor
final class ExecutionRecordTests: XCTestCase {
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func client(_ scenario: String) async throws -> ACPClient {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: ACPCommand(executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", Bundle.module.url(forResource: "acp_agent", withExtension: "py", subdirectory: "Fixtures")!.path],
            environment: ["MYCLIP_ACP_SCENARIO": scenario]))
        return client
    }

    private func job(in store: LibraryStore) async throws -> ClipJob {
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .claude, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        return try XCTUnwrap(claimed)
    }

    func testToolDetailsAndRetriesSurviveReopeningWithoutDuplicatingCalls() async throws {
        let store = try LibraryStore(root: directory)
        let job = try await job(in: store)
        let client = try await client("execution_details")
        let session = try await client.newSession(directory: directory)
        for _ in 0..<2 {
            _ = try await store.executePrompt(client, agent: .claude, sessionID: session, text: "organize", images: [], jobID: job.id)
        }
        let reopened = try LibraryStore(root: directory)
        let records = try await reopened.executionRecords(jobID: job.id)
        XCTAssertEqual(records.count, 2)
        XCTAssertNotEqual(records[0].id, records[1].id)
        XCTAssertEqual(records.map(\.cost?.amount), [Decimal(string: "0.125"), Decimal(string: "0.125")])
        for record in records {
            XCTAssertEqual(record.sessionID, session)
            XCTAssertEqual(record.stopReason, "end_turn")
            XCTAssertEqual(record.response, "你好，已整理")
            XCTAssertNotNil(record.finishedAt)
            XCTAssertEqual(record.usage?.cachedWriteTokens, 5)
            XCTAssertEqual(record.tools.count, 2)
            let read = record.tools[0]
            XCTAssertEqual(read.title, "cat Memory/notes.md")
            XCTAssertEqual(read.status, "completed")
            XCTAssertEqual(read.kind, "execute")
            XCTAssertTrue(read.rawInput?.contains("cat Memory/notes.md") == true)
            XCTAssertTrue(read.rawOutput?.contains("exitCode") == true)
            XCTAssertEqual(read.locations.first?.line, 3)
            XCTAssertEqual(read.content.first?.text, "Stored notes")
            let edit = record.tools[1]
            XCTAssertEqual(edit.kind, "edit")
            XCTAssertEqual(edit.content.first?.path, "/workspace/Memory/notes.md")
            XCTAssertEqual(edit.content.first?.oldText, "Before")
            XCTAssertEqual(edit.content.first?.newText, "After")
        }
        let stats = try await reopened.tokenUsageStatistics()
        XCTAssertEqual(stats.jobs[job.id]?.calls, 2)
        XCTAssertEqual(stats.jobs[job.id]?.totalTokens, 40)
        let other = try await reopened.executionRecords(jobID: UUID())
        XCTAssertTrue(other.isEmpty)
    }

    func testFailureKeepsToolsAndReportedCost() async throws {
        let store = try LibraryStore(root: directory)
        let job = try await job(in: store)
        let client = try await client("execution_failure")
        let session = try await client.newSession(directory: directory)
        do {
            _ = try await store.executePrompt(client, agent: .claude, sessionID: session, text: "fail", images: [], jobID: job.id)
            XCTFail("Fixture should fail after recording tool activity")
        } catch ACPError.remote { }
        let records = try await store.executionRecords(jobID: job.id)
        let record = try XCTUnwrap(records.first)
        XCTAssertNotNil(record.error)
        XCTAssertNotNil(record.finishedAt)
        XCTAssertEqual(record.tools.count, 2)
        XCTAssertEqual(record.cost?.amount, Decimal(string: "0.125"))
        XCTAssertNil(record.usage)
        let stats = try await store.tokenUsageStatistics()
        XCTAssertEqual(stats.jobs[job.id]?.calls, 1)
        XCTAssertEqual(stats.jobs[job.id]?.reportedCalls, 0)
    }

    func testRestoredSessionDoesNotAttributeEarlierCostToCurrentPrompt() async throws {
        let client = try await client("cumulative_cost")
        // A restored session has no known zero baseline until the first cost report.
        let first = try await client.prompt(sessionID: "restored", text: "first", images: [])
        let second = try await client.prompt(sessionID: "restored", text: "second", images: [])
        XCTAssertNil(first.cost)
        XCTAssertEqual(second.cost?.amount, Decimal(string: "0.125"))
    }

    func testMissingCostBreaksTheBaselineAndCurrencyChangesStayUnknown() async throws {
        let client = try await client("cost_gaps")
        let session = try await client.newSession(directory: directory)
        var costs: [ExecutionCost?] = []
        for _ in 0..<5 {
            costs.append(try await client.prompt(sessionID: session, text: "cost", images: []).cost)
        }
        XCTAssertEqual(costs[0]?.amount, Decimal(string: "0.125"))
        XCTAssertNil(costs[1])
        XCTAssertNil(costs[2], "Do not include an unreported previous prompt's spend")
        XCTAssertNil(costs[3], "Amounts in different currencies cannot be subtracted")
        XCTAssertNil(costs[4], "A reset or decreasing cumulative total is not a negative task cost")
    }

    func testLegacyTokenUsageRemainsAvailableWithoutInventingAnExecution() async throws {
        let store = try LibraryStore(root: directory)
        let job = try await job(in: store)
        try await store.recordTokenUsage(agent: .claude, jobID: job.id,
            usage: TokenUsage(totalTokens: 20, inputTokens: 15, outputTokens: 5))
        let legacy = try SQLiteConnection(url: directory.appendingPathComponent("Library.sqlite"))
        try legacy.script("DROP TABLE execution_tools; DROP TABLE execution_records;")
        let reopened = try LibraryStore(root: directory)
        let records = try await reopened.executionRecords(jobID: job.id)
        let stats = try await reopened.tokenUsageStatistics()
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(stats.jobs[job.id]?.totalTokens, 20)
    }

    func testRunningToolsAreReadableAndCancellationPreservesUsage() async throws {
        let store = try LibraryStore(root: directory)
        let job = try await job(in: store)
        let client = try await client("cancel_usage")
        let session = try await client.newSession(directory: directory)
        let running = expectation(description: "tool is running")
        let observer = Task {
            for await event in client.events {
                if case .tool = event { running.fulfill() }
            }
        }
        defer { observer.cancel() }
        let prompt = Task {
            try await store.executePrompt(client, agent: .claude, sessionID: session, text: "wait", images: [], jobID: job.id)
        }
        await fulfillment(of: [running], timeout: 2)
        let pending = try await store.executionRecords(jobID: job.id)
        XCTAssertEqual(pending.first?.tools.first?.status, "in_progress")
        XCTAssertNil(pending.first?.finishedAt)
        await client.cancelAndClose(sessionID: session)
        let result = try await prompt.value
        XCTAssertEqual(result.stopReason, "cancelled")
        let records = try await store.executionRecords(jobID: job.id)
        XCTAssertEqual(records.first?.stopReason, "cancelled")
        XCTAssertEqual(records.first?.usage?.totalTokens, 12)
        XCTAssertNotNil(records.first?.finishedAt)
    }
}
