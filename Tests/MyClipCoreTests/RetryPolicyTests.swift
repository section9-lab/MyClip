import XCTest
@testable import MyClipCore

@MainActor
final class RetryPolicyTests: XCTestCase {
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTransportAndOverloadFailuresAreTransient() {
        XCTAssertEqual(RetryPolicy.classify(ACPError.timeout), .transient)
        XCTAssertEqual(RetryPolicy.classify(ACPError.disconnected("响应超时。")), .transient)
        XCTAssertEqual(RetryPolicy.classify(ACPError.protocolError("unexpected EOF")), .transient)
        XCTAssertEqual(RetryPolicy.classify(ACPError.remote(code: -32000, message: "connect ECONNREFUSED 127.0.0.1:7890")), .transient)
        XCTAssertEqual(RetryPolicy.classify(ACPError.remote(code: 529, message: "overloaded_error")), .transient)
        XCTAssertEqual(RetryPolicy.classify(ACPError.remote(code: -32603, message: "Rate limit reached, please try again later")), .transient)
        XCTAssertEqual(RetryPolicy.classify(LibraryError.invalidResult("Agent 在完成前停止，请重试。")), .transient)
        XCTAssertEqual(RetryPolicy.classify(LibraryError.rolledBack("Wiki/Projects/项目.md（正文过长）")), .transient)
        XCTAssertEqual(RetryPolicy.classify(URLError(.timedOut)), .transient)
    }

    func testConfigurationAndDataFailuresWaitForTheUser() {
        XCTAssertEqual(RetryPolicy.classify(ACPError.unsupportedImages), .permanent)
        XCTAssertEqual(RetryPolicy.classify(ACPError.remote(code: 401, message: "unauthorized")), .permanent)
        XCTAssertEqual(RetryPolicy.classify(ACPError.remote(code: -32000, message: "model_not_found: claude-x")), .permanent)
        XCTAssertEqual(RetryPolicy.classify(ACPError.remote(code: -32000, message: "Not logged in. Run `claude login`.")), .permanent)
        XCTAssertEqual(RetryPolicy.classify(LibraryError.conflict), .permanent)
        XCTAssertEqual(RetryPolicy.classify(LibraryError.missingSource), .permanent)
        XCTAssertEqual(RetryPolicy.classify(CancellationError()), .permanent)
        XCTAssertEqual(RetryPolicy.classify(NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])), .permanent)
    }

    func testAttemptsAreCappedWithGrowingBackoff() {
        XCTAssertTrue(RetryPolicy.canRetry(afterAttempt: 1))
        XCTAssertTrue(RetryPolicy.canRetry(afterAttempt: 2))
        XCTAssertFalse(RetryPolicy.canRetry(afterAttempt: 3))
        XCTAssertLessThan(RetryPolicy.delay(afterAttempt: 1), RetryPolicy.delay(afterAttempt: 2))
    }

    func testTransientFailureRequeuesWithoutPausingAndHonoursBackoff() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(at: 100), agent: .claude, organize: true)
        let firstClaimed = try await store.claimNextJob(at: date(400))

        let first = try XCTUnwrap(firstClaimed)
        XCTAssertEqual(first.attempts, 1)

        try await store.scheduleRetry(id: first.id, error: "Agent 响应超时，可以重试。", at: date(1000))
        var snapshot = try await store.snapshot()
        let queued = try XCTUnwrap(snapshot.jobs.first)
        XCTAssertEqual(queued.state, .queued)
        XCTAssertEqual(queued.attempts, 1)
        XCTAssertEqual(queued.retryAt, date(1000))
        XCTAssertTrue(queued.isAwaitingRetry)
        XCTAssertEqual(queued.error, "Agent 响应超时，可以重试。", "The failure stays visible while the batch waits")
        XCTAssertFalse(snapshot.queue.paused, "Automatic retries do not stop the queue")
        XCTAssertNil(snapshot.queue.pauseReason)
        XCTAssertEqual(snapshot.queue.pendingCount, 1)
        XCTAssertEqual(snapshot.queue.readyAt, date(1000), "The batch is not due before its backoff")

        let early = try await store.claimNextJob(at: date(900))
        XCTAssertNil(early)
        let secondClaimed = try await store.claimNextJob(at: date(1000))

        let second = try XCTUnwrap(secondClaimed)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.attempts, 2)
        XCTAssertNil(second.retryAt)
        XCTAssertEqual(second.error, "Agent 响应超时，可以重试。", "The retry carries the previous attempt's reason for its prompt")

        // A newer capture behind the retry does not overtake it.
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 500), agent: .claude, organize: true)
        try await store.scheduleRetry(id: second.id, error: "again", at: date(1300))
        snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.queue.pendingCount, 2)
        let thirdClaimed = try await store.claimNextJob(at: date(1300))

        let third = try XCTUnwrap(thirdClaimed)
        XCTAssertEqual(third.id, first.id)
        XCTAssertEqual(third.attempts, 3)
    }

    func testGivingUpPausesAndManualRetryStartsOver() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(at: 100), agent: .claude, organize: true)
        let jobClaimed = try await store.claimNextJob(at: date(400))

        let job = try XCTUnwrap(jobClaimed)
        try await store.scheduleRetry(id: job.id, error: "timeout", at: date(500))
        let reclaimed = try await store.claimNextJob(at: date(700))

        XCTAssertNotNil(reclaimed)
        try await store.finishJob(id: job.id, state: .failed, error: "Agent 响应超时，可以重试。")
        var snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.queue.paused)
        XCTAssertEqual(snapshot.jobs.first?.attempts, 2)

        try await store.retryJob(id: job.id)
        snapshot = try await store.snapshot()
        XCTAssertFalse(snapshot.queue.paused)
        XCTAssertEqual(snapshot.jobs.first?.state, .queued)
        XCTAssertEqual(snapshot.jobs.first?.attempts, 0, "A manual retry resets the automatic budget")
        XCTAssertNil(snapshot.jobs.first?.retryAt)
        XCTAssertFalse(try XCTUnwrap(snapshot.jobs.first).isAwaitingRetry)
    }

    func testInterruptedJobsRetryOnceBeforePausing() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(at: 100), agent: .claude, organize: true)
        let jobClaimed = try await store.claimNextJob(at: date(400))

        let job = try XCTUnwrap(jobClaimed)
        try await store.recoverInterruptedJobs(at: date(600))
        var snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.state, .queued)
        XCTAssertFalse(snapshot.queue.paused)
        XCTAssertEqual(snapshot.queue.readyAt, date(600 + RetryPolicy.delay(afterAttempt: 1)))

        for attempt in 2...RetryPolicy.maxAttempts {
            let claimedClaimed = try await store.claimNextJob(at: date(100_000 * Double(attempt)))

            let claimed = try XCTUnwrap(claimedClaimed)
            XCTAssertEqual(claimed.id, job.id)
            XCTAssertEqual(claimed.attempts, attempt)
            try await store.recoverInterruptedJobs(at: date(100_000 * Double(attempt) + 10))
        }
        snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.state, .failed)
        XCTAssertTrue(snapshot.queue.paused)
        XCTAssertEqual(snapshot.queue.pauseReason?.contains("已重试"), true)
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
}
