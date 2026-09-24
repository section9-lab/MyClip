import XCTest
@testable import MyClipCore

@MainActor
final class TokenUsageTests: XCTestCase {
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRetriesAndDiscoveryPersistWithAgentAndJobTotals() async throws {
        let store = try LibraryStore(root: directory)
        let source = fixtureContext()
        try await store.record(image: fixtureImage(), context: source, agent: .claude, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let first = UUID()
        let usage = TokenUsage(totalTokens: 150, inputTokens: 80, outputTokens: 20, cachedReadTokens: 40, cachedWriteTokens: 10)
        try await store.recordTokenUsage(id: first, agent: .claude, jobID: job.id, usage: usage)
        try await store.finishJob(id: job.id, state: .failed, error: "failed after consuming tokens")
        // Re-delivery must not count the same response twice; a retry is a new attempt.
        try await store.recordTokenUsage(id: first, agent: .claude, jobID: job.id, usage: usage)
        try await store.recordTokenUsage(agent: .claude, jobID: job.id, usage: usage)
        try await store.recordTokenUsage(agent: .codex, usage: .init(totalTokens: 25, inputTokens: 20, outputTokens: 5))
        let reopened = try LibraryStore(root: directory)
        let stats = try await reopened.tokenUsageStatistics()
        XCTAssertEqual(stats.total.calls, 3)
        XCTAssertEqual(stats.total.reportedCalls, 3)
        XCTAssertEqual(stats.total.totalTokens, 325)
        XCTAssertEqual(stats.total.inputTokens, 180)
        XCTAssertEqual(stats.total.outputTokens, 45)
        XCTAssertEqual(stats.total.cachedReadTokens, 80)
        XCTAssertEqual(stats.total.cachedWriteTokens, 20)
        XCTAssertEqual(stats.agents[.claude]?.totalTokens, 300)
        XCTAssertEqual(stats.agents[.codex]?.totalTokens, 25)
        XCTAssertEqual(stats.jobs[job.id]?.totalTokens, 300)
        XCTAssertEqual(stats.jobs[job.id]?.calls, 2)
    }

    func testUnreportedCallsAreUnknownInsteadOfZero() async throws {
        let store = try LibraryStore(root: directory)
        let empty = try await store.tokenUsageStatistics()
        XCTAssertNil(empty.total.totalTokens)
        XCTAssertEqual(empty.total.calls, 0)
        try await store.recordTokenUsage(agent: .claude, usage: nil)
        let unknown = try await store.tokenUsageStatistics()
        XCTAssertNil(unknown.total.totalTokens)
        XCTAssertEqual(unknown.total.calls, 1)
        XCTAssertEqual(unknown.total.reportedCalls, 0)
        try await store.recordTokenUsage(agent: .codex, usage: .init(totalTokens: 0, inputTokens: 0, outputTokens: 0))
        let zero = try await store.tokenUsageStatistics()
        XCTAssertEqual(zero.total.totalTokens, 0)
        XCTAssertEqual(zero.total.calls, 2)
        XCTAssertEqual(zero.total.reportedCalls, 1)
        XCTAssertNil(zero.agents[.claude]?.totalTokens)
    }
    func testDailyHistorySplitsByAgentAndFeedsPeriodSummaries() async throws {
        let store = try LibraryStore(root: directory)
        try await store.recordTokenUsage(agent: .claude, usage: .init(totalTokens: 100, inputTokens: 40, outputTokens: 10, cachedReadTokens: 50, cachedWriteTokens: 0))
        try await store.recordTokenUsage(agent: .claude, usage: nil)
        try await store.recordTokenUsage(agent: .codex, usage: .init(totalTokens: 30, inputTokens: 20, outputTokens: 10))
        let stats = try await store.tokenUsageStatistics()
        XCTAssertEqual(stats.history.count, 1, "Everything recorded just now lands on today")
        let today = try XCTUnwrap(stats.history.first)
        XCTAssertEqual(today.day, Calendar.current.startOfDay(for: Date()))
        XCTAssertEqual(today.total.calls, 3)
        XCTAssertEqual(today.total.reportedCalls, 2)
        XCTAssertEqual(today.total.totalTokens, 130)
        XCTAssertEqual(today.agents[.claude]?.totalTokens, 100)
        XCTAssertEqual(today.agents[.claude]?.calls, 2)
        XCTAssertEqual(today.agents[.codex]?.totalTokens, 30)
        XCTAssertEqual(stats.summary(days: 7).totalTokens, 130)
        XCTAssertEqual(stats.summary(days: nil).totalTokens, stats.total.totalTokens)
        XCTAssertEqual(stats.previousSummary(days: 7).calls, 0)
        let hitRate = try XCTUnwrap(today.agents[.claude]?.cacheHitRate)
        XCTAssertEqual(hitRate, 50.0 / 90.0, accuracy: 0.001)
        XCTAssertNil(today.agents[.codex]?.cacheHitRate.map { $0 > 0 ? true : nil } ?? nil, "No cache reported means a zero-share, not a missing rate")
    }
}
