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

    func testMouseAndKeyboardSendImagesEvenWhenOCRExists() async throws {
        let store = try LibraryStore(root: directory)
        for (index, reason) in [CaptureReason.clickAfterIdle, .enter].enumerated() {
            var context = fixtureContext(at: 100 + Double(index))
            context.reason = reason
            try await store.record(image: fixtureImage(changed: true, x: index), context: context,
                agent: .codex, organize: true, extractedText: "OCR \(index)")
        }
        let job = try await claim(store, at: 400)
        let captures = try await store.organizationCaptures(jobID: job.id)
        XCTAssertEqual(captures.count, 2)
        let prompt = MemoryPrompt.filePrompt(captures: captures)
        XCTAssertEqual(prompt.components(separatedBy: "content=image · 图片附件").count, 3)
        XCTAssertFalse(prompt.contains("OCR 0"))
        XCTAssertFalse(prompt.contains("OCR 1"))
    }

    func testLegacyFrozenOCRIsNotSentOnRetry() async throws {
        let store = try LibraryStore(root: directory)
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: true,
            extractedText: "Legacy OCR")
        let job = try await claim(store, at: 400)
        let database = try SQLiteConnection(url: directory.appendingPathComponent("Library.sqlite"))
        try database.run("INSERT INTO job_inputs(job_id,capture_id,ocr_text) VALUES(?,?,?) ON CONFLICT(job_id,capture_id) DO UPDATE SET ocr_text=excluded.ocr_text",
            [job.id.uuidString, context.id.uuidString, "Legacy OCR"])
        try await store.finishJob(id: job.id, state: .failed)
        let reopened = try LibraryStore(root: directory)
        try await reopened.retryJob(id: job.id)
        _ = try await reopened.claimNextJob(at: date(700), immediately: true, jobID: job.id)
        let captures = try await reopened.organizationCaptures(jobID: job.id)
        XCTAssertEqual(captures.count, 1)
        XCTAssertFalse(MemoryPrompt.filePrompt(captures: captures).contains("Legacy OCR"))
    }

    func testMouseCapturesUseEightImageBatchLimitInChronologicalOrder() async throws {
        let store = try LibraryStore(root: directory)
        var sources: [UUID] = []
        for index in 0..<35 {
            var context = fixtureContext(at: 100 + Double(index))
            context.reason = .scrollIdle
            sources.append(context.id)
            try await store.record(image: fixtureImage(changed: true, x: index), context: context,
                agent: .codex, organize: true, extractedText: "OCR \(index)")
        }
        let job = try await claim(store, at: 400)
        XCTAssertEqual(job.sourceIDs, Array(sources.prefix(8)))
    }

    func testLongOCRDoesNotLimitImageBatch() async throws {
        let store = try LibraryStore(root: directory)
        var sources: [UUID] = []
        for index in 0..<3 {
            var context = fixtureContext(at: 100 + Double(index))
            context.reason = index == 2 ? .enter : .clickAfterIdle
            sources.append(context.id)
            try await store.record(image: fixtureImage(changed: true, x: index), context: context,
                agent: .codex, organize: true, extractedText: String(repeating: "文", count: 7_000))
        }
        let job = try await claim(store, at: 400)
        XCTAssertEqual(job.sourceIDs, sources)
    }

    func testMixedTriggersKeepSameImageSourcesOnRetry() async throws {
        let store = try LibraryStore(root: directory)
        var sources: [UUID] = []
        for index in 0..<9 {
            var context = fixtureContext(at: 100 + Double(index))
            context.reason = index.isMultiple(of: 2) ? .enter : .scrollIdle
            sources.append(context.id)
            try await store.record(image: fixtureImage(changed: true, x: index), context: context,
                agent: .codex, organize: true, extractedText: "OCR \(index)")
        }
        let first = try await claim(store, at: 400)
        XCTAssertEqual(first.sourceIDs, Array(sources.prefix(8)))
        let original = try await store.organizationCaptures(jobID: first.id)
        try await store.indexImageText(id: original[1].imageID, text: "Changed OCR")
        try await store.finishJob(id: first.id, state: .failed)
        let reopened = try LibraryStore(root: directory)
        try await reopened.retryJob(id: first.id)
        let retried = try await reopened.claimNextJob(at: date(700), immediately: true, jobID: first.id)
        let retry = try XCTUnwrap(retried)
        let captures = try await reopened.organizationCaptures(jobID: retry.id)
        XCTAssertEqual(retry.id, first.id)
        XCTAssertEqual(captures.map(\.id), first.sourceIDs)
        XCTAssertFalse(MemoryPrompt.filePrompt(captures: captures).contains("Changed OCR"))
    }

    func testMouseFallbackAndManualReorganizationUseImages() async throws {
        let store = try LibraryStore(root: directory)
        for (index, text) in [nil, " \n", String(repeating: "x", count: 12_001), "useful text"].enumerated() {
            try await store.record(image: fixtureImage(changed: true, x: index), context: fixtureContext(at: 100 + Double(index)),
                agent: .codex, organize: true, extractedText: text)
        }
        let job = try await claim(store, at: 400)
        let captures = try await store.organizationCaptures(jobID: job.id)
        XCTAssertEqual(captures.count, 4)
        try await store.finishJob(id: job.id, state: .cancelled)
        let manual = try await store.enqueue(sourceIDs: [captures[3].id], agent: .codex)
        let manualCaptures = try await store.organizationCaptures(jobID: manual)
        XCTAssertEqual(manualCaptures.map(\.id), [captures[3].id])
    }

    func testVersionSevenMigrationKeepsLegacyJobImagesAndBlocksOlderReaders() async throws {
        let store = try LibraryStore(root: directory)
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: false, extractedText: "existing OCR")
        let job = try await store.enqueue(sourceIDs: [context.id], agent: .codex)
        let database = try SQLiteConnection(url: directory.appendingPathComponent("Library.sqlite"))
        try database.script("DROP TABLE job_inputs; PRAGMA user_version=7;")
        let migrated = try LibraryStore(root: directory)
        let captures = try await migrated.organizationCaptures(jobID: job)
        XCTAssertEqual(captures.map(\.id), [context.id])
        let migratedVersion = try XCTUnwrap(database.run("PRAGMA user_version").first?["user_version"].flatMap(Int.init))
        XCTAssertGreaterThanOrEqual(migratedVersion, 9, "Version 9 added the retry columns")
        let columns = Set(try database.run("PRAGMA table_info(jobs)").compactMap { $0["name"] })
        XCTAssertTrue(columns.isSuperset(of: ["attempts", "retry_at"]), "Legacy jobs gain the retry columns")
        _ = try LibraryStore(root: directory)
        XCTAssertEqual(try database.run("PRAGMA user_version").first?["user_version"], String(migratedVersion), "Reopening must not downgrade the schema version")
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
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 399, windowID: 2), agent: .codex, organize: true)
        let early = try await store.claimNextJob(at: date(399))
        XCTAssertNil(early)
        let onTime = try await store.claimNextJob(at: date(400))
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
        let first = try await claim(store, at: 400)
        XCTAssertEqual(first.sourceIDs, Array(sources.prefix(8)))
        let simultaneous = try await store.claimNextJob(at: date(600), immediately: true)
        XCTAssertNil(simultaneous)
        try await store.commit(jobID: first.id, drafts: [])
        let reopened = try LibraryStore(root: directory)
        let early = try await reopened.claimNextJob(at: date(699))
        XCTAssertNil(early)
        let second = try await claim(reopened, at: 700)
        XCTAssertEqual(second.sourceIDs, Array(sources[8..<16]))
        try await reopened.commit(jobID: second.id, drafts: [])
        let third = try await claim(reopened, at: 1000)
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
        let first = try await claim(store, at: 400)
        XCTAssertEqual(first.sourceIDs, [codex.id])
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 401), agent: .codex, organize: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.sourceIDs, [codex.id])
        XCTAssertEqual(snapshot.queue.pendingCounts, [.codex: 1, .claude: 1])
        try await store.commit(jobID: first.id, drafts: [])
        let second = try await claim(store, at: 700)
        XCTAssertEqual(second.agent, .claude)
        XCTAssertEqual(second.sourceIDs, [claude.id])
    }

    func testChangingDefaultAgentRetargetsPendingCapturesWithoutResettingQueue() async throws {
        let store = try LibraryStore(root: directory)
        let first = fixtureContext()
        let second = fixtureContext(at: 101)
        try await store.record(image: fixtureImage(), context: first, agent: .codex, organize: true)
        try await store.record(image: fixtureImage(changed: true), context: second, agent: .claude, organize: true)
        try await store.setOrganizationPaused(true, reason: "Offline")
        let before = try await store.organizationQueue()

        try await store.reassignPendingCaptures(to: .claude)

        let reopened = try LibraryStore(root: directory)
        let after = try await reopened.organizationQueue()
        XCTAssertEqual(after.pendingCounts, [.claude: 2])
        XCTAssertEqual(after.nextAgent, .claude)
        XCTAssertEqual(after.readyAt, before.readyAt)
        XCTAssertEqual(after.lastStartedAt, before.lastStartedAt)
        XCTAssertTrue(after.paused)
        XCTAssertEqual(after.pauseReason, "Offline")
        let automatic = try await reopened.claimNextJob(at: date(1000))
        XCTAssertNil(automatic)
        let manual = try await reopened.claimNextJob(at: date(200), immediately: true)
        XCTAssertEqual(manual?.agent, .claude)
        XCTAssertEqual(manual?.sourceIDs, [first.id, second.id])
    }

    func testDefaultChangePreservesRunningBatchAndExplicitAgentChoice() async throws {
        let store = try LibraryStore(root: directory)
        let first = fixtureContext()
        try await store.record(image: fixtureImage(), context: first, agent: .codex, organize: true)
        let running = try await claim(store, at: 400)
        let pending = fixtureContext(at: 401)
        try await store.record(image: fixtureImage(changed: true), context: pending, agent: .codex, organize: true)
        let selected = fixtureContext(at: 402)
        try await store.record(image: fixtureImage(changed: true, x: 2), context: selected, agent: .codex, organize: false)
        let explicitID = try await store.enqueue(sourceIDs: [selected.id], agent: .codex)

        try await store.reassignPendingCaptures(to: .claude)

        let snapshot = try await store.snapshot()
        let unchanged = try XCTUnwrap(snapshot.jobs.first { $0.id == running.id })
        XCTAssertEqual(unchanged.state, .running)
        XCTAssertEqual(unchanged.agent, .codex)
        XCTAssertEqual(unchanged.sourceIDs, [first.id])
        XCTAssertEqual(snapshot.queue.pendingCounts, [.codex: 1, .claude: 1])
        XCTAssertEqual(snapshot.queue.lastStartedAt, date(400))
        try await store.commit(jobID: running.id, drafts: [])
        let next = try await claim(store, at: 701)
        XCTAssertEqual(next.agent, .claude)
        XCTAssertEqual(next.sourceIDs, [pending.id])
        try await store.commit(jobID: next.id, drafts: [])
        let explicit = try await store.claimNextJob(immediately: true, jobID: explicitID)
        XCTAssertEqual(explicit?.agent, .codex)
        XCTAssertEqual(explicit?.sourceIDs, [selected.id])
        let completed = try await store.snapshot().jobs.first { $0.id == running.id }
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(completed?.agent, .codex)
    }

    func testDefaultChangeMergesDuplicatePendingSourcesAtTheirOldestTime() async throws {
        let store = try LibraryStore(root: directory)
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: true)
        let database = try SQLiteConnection(url: directory.appendingPathComponent("Library.sqlite"))
        try database.run("INSERT INTO pending_captures VALUES(?,'claude',200)", [context.id.uuidString])

        try await store.reassignPendingCaptures(to: .claude)
        try await store.reassignPendingCaptures(to: .claude)

        let queue = try await store.organizationQueue()
        XCTAssertEqual(queue.pendingCounts, [.claude: 1])
        XCTAssertEqual(queue.readyAt, date(400))
        let job = try await claim(store, at: 400)
        XCTAssertEqual(job.agent, .claude)
        XCTAssertEqual(job.sourceIDs, [context.id])
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.queue.pendingCount, 0)
        XCTAssertEqual(snapshot.captures.count, 1)
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
        let paused = try await store.claimNextJob(at: date(500))
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
        let early = try await store.claimNextJob(at: date(409))
        XCTAssertNil(early)
        let second = try await store.claimNextJob(at: date(410))
        XCTAssertEqual(second?.sourceIDs.count, 2)
    }

    func testFailurePausesAcrossRestartAndExplicitRetryKeepsSameSources() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        let first = try await claim(store, at: 400)
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 401), agent: .codex, organize: true)
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

    func testInterruptionPreservesPartialMemoryAndRetriesAfterBackoff() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        let first = try await claim(store, at: 400)
        _ = try await store.beginMemoryEditing(jobID: first.id)
        let path = directory.appendingPathComponent("Memory/Wiki/Topics/partial.md")
        try "# Partial\n\nKeep this work.\n".write(to: path, atomically: true, encoding: .utf8)
        let reopened = try LibraryStore(root: directory)
        try await reopened.recoverInterruptedJobs(at: date(420))
        try await reopened.recoverInterruptedJobs(at: date(420))
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.state, .queued)
        XCTAssertEqual(snapshot.jobs.first?.isAwaitingRetry, true)
        XCTAssertEqual(snapshot.jobs.first?.sourceIDs, first.sourceIDs)
        XCTAssertFalse(snapshot.queue.paused)
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains("Keep this work."))
        let early = try await reopened.claimNextJob(at: date(420 + RetryPolicy.delay(afterAttempt: 1) - 1))
        XCTAssertNil(early, "Not before the backoff has passed")
        let automatic = try await reopened.claimNextJob(at: date(1000))
        XCTAssertEqual(automatic?.id, first.id)
        XCTAssertEqual(automatic?.attempts, 2)
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
            try database.run("INSERT INTO jobs(id,agent,state,created_at,error) VALUES(?,?,'queued',?,NULL)", [id, index == 11 ? "claude" : "codex", String(100 + index)])
            try database.run("INSERT INTO job_sources VALUES(?,?)", [id, context.id.uuidString])
        }
        let running = UUID().uuidString
        try database.run("INSERT INTO jobs(id,agent,state,created_at,error) VALUES(?,'codex','running',90,NULL)", [running])
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
        try await reopened.recoverInterruptedJobs(at: date(280))
        // The interrupted legacy batch runs again first, then the unstarted jobs are rebatched.
        let resumed = try await claim(reopened, at: 570)
        XCTAssertEqual(resumed.id.uuidString, running)
        XCTAssertEqual(resumed.sourceIDs, [sources[0]])
        try await reopened.finishJob(id: resumed.id, state: .cancelled)
        let batch = try await claim(reopened, at: 870)
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
