import XCTest
@testable import MyClipCore

@MainActor
final class OrganizationQueueTests: XCTestCase {
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCapturesWaitWithoutCreatingExecutionJobs() async throws {
        let store = try LibraryStore(root: directory)
        for index in 0..<20 {
            try await store.record(image: fixtureImage(changed: true, x: index), context: fixtureContext(at: 100 + Double(index)), agent: .codex, organize: true)
        }
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.captures.count, 20)
        XCTAssertTrue(snapshot.jobs.isEmpty, "An execution batch should only be created when dispatching")
    }

    func testDispatchCombinesOldTinyBatchesIntoEightImages() async throws {
        let store = try LibraryStore(root: directory)
        for index in 0..<20 {
            try await store.record(image: fixtureImage(changed: true, x: index), context: fixtureContext(at: 100 + Double(index)), agent: .codex, organize: true)
        }
        let job = try await store.claimNextJob()
        XCTAssertEqual(job?.sourceIDs.count, 8)
    }

    func testOldestCaptureSetsDeadlineAndNewCapturesDoNotResetIt() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 279, windowID: 2), agent: .codex, organize: true)
        let early = try await store.claimNextJob(at: date(279))
        XCTAssertNil(early)
        let onTime = try await store.claimNextJob(at: date(280))
        XCTAssertEqual(onTime?.sourceIDs.count, 2)
    }

    func testTwentyCapturesDispatchEightEightFourWithPersistentStartInterval() async throws {
        let store = try LibraryStore(root: directory)
        var sources: [UUID] = []
        for index in 0..<20 {
            let context = fixtureContext(at: 100 + Double(index), windowID: UInt32(index % 3))
            sources.append(context.id)
            try await store.record(image: fixtureImage(changed: true, x: index), context: context, agent: .codex, organize: true)
        }
        let first = try await claim(store, at: 280)
        XCTAssertEqual(first.sourceIDs, Array(sources.prefix(8)))
        let simultaneous = try await store.claimNextJob(at: date(600), immediately: true)
        XCTAssertNil(simultaneous)
        try await store.commit(jobID: first.id, drafts: [])
        let reopened = try LibraryStore(root: directory)
        let early = try await reopened.claimNextJob(at: date(459))
        XCTAssertNil(early)
        let second = try await claim(reopened, at: 460)
        XCTAssertEqual(second.sourceIDs, Array(sources[8..<16]))
        try await reopened.commit(jobID: second.id, drafts: [])
        let third = try await claim(reopened, at: 640)
        XCTAssertEqual(third.sourceIDs, Array(sources.suffix(4)))
        let status = try await reopened.organizationQueue()
        XCTAssertEqual(status.pendingCount, 0)
    }

    func testRunningInputsAreFrozenAndProvidersStaySeparate() async throws {
        let store = try LibraryStore(root: directory)
        let codex = fixtureContext()
        let claude = fixtureContext(at: 101)
        try await store.record(image: fixtureImage(), context: codex, agent: .codex, organize: true)
        // Switching agent must not suppress an identical screenshot for the new agent.
        try await store.record(image: fixtureImage(), context: claude, agent: .claude, organize: true)
        let first = try await claim(store, at: 280)
        XCTAssertEqual(first.sourceIDs, [codex.id])
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 281), agent: .codex, organize: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.sourceIDs, [codex.id])
        XCTAssertEqual(snapshot.queue.pendingCounts, [.codex: 1, .claude: 1])
        try await store.commit(jobID: first.id, drafts: [])
        let second = try await claim(store, at: 460)
        XCTAssertEqual(second.agent, .claude)
        XCTAssertEqual(second.sourceIDs, [claude.id])
    }

    func testExactDuplicatesKeepOccurrencesAndOnePixelChangesRemainPending() async throws {
        let store = try LibraryStore(root: directory)
        for index in 0..<3 {
            try await store.record(image: fixtureImage(), context: fixtureContext(at: 100 + Double(index)), agent: .codex, organize: true)
        }
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 103), agent: .codex, organize: true)
        try await store.record(image: fixtureImage(), context: fixtureContext(at: 104), agent: .codex, organize: true)
        try await store.record(image: fixtureImage(), context: fixtureContext(at: 105, windowID: 2), agent: .codex, organize: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.captures.count, 6)
        XCTAssertEqual(snapshot.imageCount, 2)
        XCTAssertEqual(snapshot.queue.pendingCount, 4)
    }

    func testManualFlushBypassesTimerOnceAndStillAdvancesAutomaticClock() async throws {
        let store = try LibraryStore(root: directory)
        for index in 0..<10 {
            try await store.record(image: fixtureImage(changed: true, x: index), context: fixtureContext(at: 100 + Double(index)), agent: .codex, organize: true)
        }
        try await store.setOrganizationPaused(true)
        let paused = try await store.claimNextJob(at: date(400))
        XCTAssertNil(paused)
        let first = try await store.claimNextJob(at: date(110), immediately: true)
        let job = try XCTUnwrap(first)
        XCTAssertEqual(job.sourceIDs.count, 8)
        let doubleClick = try await store.claimNextJob(at: date(110), immediately: true)
        XCTAssertNil(doubleClick)
        try await store.commit(jobID: job.id, drafts: [])
        let status = try await store.organizationQueue()
        XCTAssertTrue(status.paused, "A one-off manual flush must not silently resume a paused queue")
        try await store.setOrganizationPaused(false)
        let early = try await store.claimNextJob(at: date(289))
        XCTAssertNil(early)
        let second = try await store.claimNextJob(at: date(290))
        XCTAssertEqual(second?.sourceIDs.count, 2)
    }

    func testFailurePausesAcrossRestartAndExplicitRetryKeepsSameSources() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        let first = try await claim(store, at: 280)
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 281), agent: .codex, organize: true)
        try await store.finishJob(id: first.id, state: .failed, error: "Offline")
        let reopened = try LibraryStore(root: directory)
        let status = try await reopened.organizationQueue()
        XCTAssertTrue(status.paused)
        XCTAssertEqual(status.pauseReason, "Offline")
        let automatic = try await reopened.claimNextJob(at: date(1000))
        XCTAssertNil(automatic)
        try await reopened.expireImages(before: date(2000))
        try await reopened.retryJob(id: first.id)
        let retried = try await reopened.claimNextJob(at: date(1001), immediately: true, jobID: first.id)
        XCTAssertEqual(retried?.sourceIDs, first.sourceIDs)
        XCTAssertEqual(retried?.id, first.id)
        let resumed = try await reopened.organizationQueue()
        XCTAssertFalse(resumed.paused)
    }

    func testManuallySelectingPendingCaptureDoesNotQueueItTwice() async throws {
        let store = try LibraryStore(root: directory)
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: true)
        let id = try await store.enqueue(sourceIDs: [context.id], agent: .codex)
        let status = try await store.organizationQueue()
        XCTAssertEqual(status.pendingCount, 1)
        let claimed = try await store.claimNextJob(immediately: true, jobID: id)
        XCTAssertEqual(claimed?.sourceIDs, [context.id])
        let after = try await store.organizationQueue()
        XCTAssertEqual(after.pendingCount, 0)
    }

    func testInterruptionPreservesPartialMemoryAndRequiresManualRetry() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        let first = try await claim(store, at: 280)
        _ = try await store.beginMemoryEditing(jobID: first.id)
        let path = directory.appendingPathComponent("Memory/Wiki/Topics/partial.md")
        try "# Partial\n\nKeep this work.\n".write(to: path, atomically: true, encoding: .utf8)
        let reopened = try LibraryStore(root: directory)
        try await reopened.recoverInterruptedJobs()
        try await reopened.recoverInterruptedJobs()
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.state, .failed)
        XCTAssertEqual(snapshot.jobs.first?.sourceIDs, first.sourceIDs)
        XCTAssertTrue(snapshot.queue.paused)
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains("Keep this work."))
        let automatic = try await reopened.claimNextJob(at: date(1000))
        XCTAssertNil(automatic)
    }

    func testVersionFiveMigrationRebatchesOnlyUnstartedJobsWithoutLosingSources() async throws {
        let store = try LibraryStore(root: directory)
        var sources: [UUID] = []
        let database = try SQLiteConnection(url: directory.appendingPathComponent("Library.sqlite"))
        for index in 0..<12 {
            let context = fixtureContext(at: 100 + Double(index))
            sources.append(context.id)
            try await store.record(image: fixtureImage(changed: true, x: index), context: context, agent: .codex, organize: false)
            let id = UUID().uuidString
            try database.run("INSERT INTO jobs VALUES(?,?,'queued',?,NULL)", [id, index == 11 ? "claude" : "codex", String(100 + index)])
            try database.run("INSERT INTO job_sources VALUES(?,?)", [id, context.id.uuidString])
        }
        let running = UUID().uuidString
        try database.run("INSERT INTO jobs VALUES(?,'codex','running',90,NULL)", [running])
        try database.run("INSERT INTO job_sources VALUES(?,?)", [running, sources[0].uuidString])
        try database.run("INSERT INTO job_times VALUES(?,270,NULL)", [running])
        try database.script("PRAGMA user_version=5;")
        let migrated = try LibraryStore(root: directory)
        let beforeRecovery = try await migrated.snapshot()
        XCTAssertEqual(beforeRecovery.jobs.count, 1)
        XCTAssertEqual(beforeRecovery.jobs.first?.state, .running)
        XCTAssertEqual(beforeRecovery.jobs.first?.sourceIDs, [sources[0]])
        XCTAssertEqual(beforeRecovery.queue.pendingCounts, [.codex: 11, .claude: 1])
        XCTAssertEqual(beforeRecovery.queue.lastStartedAt, date(270))
        let reopened = try LibraryStore(root: directory)
        try await reopened.recoverInterruptedJobs()
        try await reopened.setOrganizationPaused(false)
        let batch = try await claim(reopened, at: 450)
        XCTAssertEqual(batch.sourceIDs, Array(sources.prefix(8)))
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.captures.count, 12)
        XCTAssertEqual(snapshot.queue.pendingCount, 4)
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func claim(_ store: LibraryStore, at seconds: TimeInterval) async throws -> ClipJob {
        let job = try await store.claimNextJob(at: date(seconds))
        return try XCTUnwrap(job)
    }
}
