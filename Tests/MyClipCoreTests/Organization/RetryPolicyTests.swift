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
        XCTAssertEqual(RetryPolicy.classify(LibraryError.agentStopped), .transient)
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

    func testCertificateAndInternalErrorsUseBoundedRetries() {
        for message in ["Internal error: unknown certificate verification error", "certificate verify failed",
                        "unable to verify the first certificate", "CERT_HAS_EXPIRED", "SELF_SIGNED_CERT_IN_CHAIN",
                        "unable_to_verify_leaf_signature", "fetch failed", "Agent 响应超时，可以重试。"] {
            XCTAssertEqual(RetryPolicy.classify(ACPError.remote(code: -32000, message: message)), .transient, message)
            XCTAssertEqual(RetryPolicy.classify(message: message), .transient, "Persisted error: \(message)")
        }
        XCTAssertEqual(RetryPolicy.classify(ACPError.remote(code: -32603, message: "Internal error")), .transient)
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                     .serverCertificateHasBadDate, .serverCertificateNotYetValid] {
            XCTAssertEqual(RetryPolicy.classify(URLError(code)), .transient)
        }
        XCTAssertEqual(RetryPolicy.classify(ACPError.remote(code: -32603, message: "Authentication required")), .permanent)
        XCTAssertEqual(RetryPolicy.classify(message: "Invalid API key: fetch failed"), .permanent)
    }

    func testLegacyCertificatePauseRecoversWithoutResettingAttempts() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(at: 100), agent: .opencode, organize: true)
        let claimed = try await store.claimNextJob(at: date(400))
        let first = try XCTUnwrap(claimed)
        let error = "Internal error: unknown certificate verification error"
        try await store.finishJob(id: first.id, state: .failed, error: error)
        let failedAt = Date()
        let reopened = try LibraryStore(root: directory)

        let wrongAgent = try await reopened.recoverRetryableOrganizationFailure(agent: .codex, at: failedAt)
        XCTAssertFalse(wrongAgent, "Recovery keeps the failed batch on its selected Agent")
        let recovered = try await reopened.recoverRetryableOrganizationFailure(agent: .opencode, at: failedAt)
        XCTAssertTrue(recovered)
        let snapshot = try await reopened.snapshot()
        let retry = try XCTUnwrap(snapshot.jobs.first)
        XCTAssertFalse(snapshot.queue.paused)
        XCTAssertNil(snapshot.queue.pauseReason)
        XCTAssertEqual(retry.id, first.id)
        XCTAssertEqual(retry.attempts, 1)
        XCTAssertEqual(retry.error, error)
        XCTAssertTrue(retry.isAwaitingRetry)
        XCTAssertEqual(try XCTUnwrap(retry.retryAt).timeIntervalSince(failedAt), RetryPolicy.delay(afterAttempt: 1), accuracy: 1)
        let early = try await reopened.claimNextJob(at: failedAt)
        XCTAssertNil(early, "Restoring a paused queue still respects backoff")
        let duplicate = try await reopened.recoverRetryableOrganizationFailure(agent: .opencode, at: failedAt)
        XCTAssertFalse(duplicate, "Repeated worker ticks do not reschedule the batch")
        let next = try await reopened.claimNextJob(at: try XCTUnwrap(retry.retryAt))
        XCTAssertEqual(next?.id, first.id)
        XCTAssertEqual(next?.attempts, 2)
    }

    func testRecoveryRespectsManualPausePermanentFailureAndAttemptLimit() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(at: 100), agent: .opencode, organize: true)
        let claimed = try await store.claimNextJob(at: date(400))
        let first = try XCTUnwrap(claimed)
        try await store.finishJob(id: first.id, state: .failed, error: "Authentication required")
        var recovered = try await store.recoverRetryableOrganizationFailure(agent: .opencode)
        XCTAssertFalse(recovered, "A login problem requires user action")

        try await store.retryJob(id: first.id)
        for attempt in 1...RetryPolicy.maxAttempts {
            _ = try await store.claimNextJob(immediately: true, jobID: first.id)
            if attempt < RetryPolicy.maxAttempts {
                try await store.scheduleRetry(id: first.id, error: "timeout", at: date(500))
            }
        }
        try await store.finishJob(id: first.id, state: .failed, error: "Internal error: unknown certificate verification error")
        recovered = try await store.recoverRetryableOrganizationFailure(agent: .opencode)
        XCTAssertFalse(recovered, "Background recovery cannot reset an exhausted budget")
        let exhausted = try await store.snapshot()
        XCTAssertTrue(exhausted.queue.paused)
        XCTAssertEqual(exhausted.jobs.first?.attempts, RetryPolicy.maxAttempts)

        try await store.retryJob(id: first.id)
        _ = try await store.claimNextJob(immediately: true, jobID: first.id)
        try await store.finishJob(id: first.id, state: .failed, error: "certificate verify failed")
        try await store.setOrganizationPaused(true)
        recovered = try await store.recoverRetryableOrganizationFailure(agent: .opencode)
        XCTAssertFalse(recovered, "A later manual pause revokes automatic recovery")
        let paused = try await store.snapshot()
        XCTAssertTrue(paused.queue.paused)
        XCTAssertNil(paused.queue.pauseReason)
    }

    func testAttemptsAreCappedWithGrowingBackoff() {
        XCTAssertTrue(RetryPolicy.canRetry(afterAttempt: 1))
        XCTAssertTrue(RetryPolicy.canRetry(afterAttempt: 5))
        XCTAssertFalse(RetryPolicy.canRetry(afterAttempt: 6))
        for attempt in 1..<5 { XCTAssertLessThan(RetryPolicy.delay(afterAttempt: attempt), RetryPolicy.delay(afterAttempt: attempt + 1)) }
        let window = (1..<RetryPolicy.maxAttempts).map(RetryPolicy.delay(afterAttempt:)).reduce(0, +)
        XCTAssertGreaterThanOrEqual(window, 3600, "Retries span a network outage of at least an hour")
        XCTAssertEqual(RetryPolicy.delay(afterAttempt: 99), 3600)
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

        // A capture that is also due does not overtake the unfinished batch.
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 500), agent: .claude, organize: true)
        try await store.scheduleRetry(id: second.id, error: "again", at: date(1300))
        snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.queue.pendingCount, 2)
        let thirdClaimed = try await store.claimNextJob(at: date(1300))

        let third = try XCTUnwrap(thirdClaimed)
        XCTAssertEqual(third.id, first.id)
        XCTAssertEqual(third.attempts, 3)
    }

    func testDueRetryRunsBeforeOlderCapturesAndPendingBackoffLetsCapturesRun() async throws {
        let store = try LibraryStore(root: directory)
        for offset in 0..<9 {
            try await store.record(image: fixtureImage(changed: true, x: offset), context: fixtureContext(at: 100 + TimeInterval(offset)), agent: .claude, organize: true)
        }
        let firstClaimed = try await store.claimNextJob(at: date(400))
        let first = try XCTUnwrap(firstClaimed)
        XCTAssertEqual(first.sourceIDs.count, 8, "One older capture stays behind the batch")

        // Backoff shorter than the queue interval: the retry is due at the next start and goes before the older capture.
        try await store.scheduleRetry(id: first.id, error: "Agent 响应超时，可以重试。", at: date(460))
        var queue = try await store.organizationQueue(at: date(600))
        XCTAssertEqual(queue.readyAt, date(700), "Nothing starts before the interval since the last start")
        XCTAssertEqual(queue.pendingCount, 9)
        let secondClaimed = try await store.claimNextJob(at: date(700))
        let second = try XCTUnwrap(secondClaimed)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.attempts, 2)

        // Backoff longer than the interval: the queue keeps working on fresh captures and picks the retry up afterwards.
        try await store.scheduleRetry(id: first.id, error: "again", at: date(1180))
        queue = try await store.organizationQueue(at: date(800))
        XCTAssertEqual(queue.readyAt, date(1000), "The capture batch is due before the retry's backoff ends")
        let early = try await store.claimNextJob(at: date(800))
        XCTAssertNil(early)
        let freshClaimed = try await store.claimNextJob(at: date(1000))
        let fresh = try XCTUnwrap(freshClaimed)
        XCTAssertNotEqual(fresh.id, first.id)
        XCTAssertEqual(fresh.sourceIDs.count, 1)
        try await store.commit(jobID: fresh.id, drafts: [])
        queue = try await store.organizationQueue(at: date(1100))
        XCTAssertEqual(queue.readyAt, date(1300), "The retry waits out both its backoff and the interval since the capture batch started")
        let tooSoon = try await store.claimNextJob(at: date(1200))
        XCTAssertNil(tooSoon)
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
        try await store.recoverInterruptedJobs(at: date(800))
        var snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.state, .queued)
        XCTAssertFalse(snapshot.queue.paused)
        XCTAssertEqual(snapshot.queue.readyAt, date(800 + RetryPolicy.delay(afterAttempt: 1)))

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
