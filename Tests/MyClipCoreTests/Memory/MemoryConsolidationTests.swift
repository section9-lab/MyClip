import XCTest
@testable import MyClipCore

@MainActor
final class MemoryConsolidationTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func write(_ path: String, title: String, body: String, sources: [UUID] = [], extra: String = "") throws {
        let url = root.appendingPathComponent("Memory/\(path)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MemoryDocument.encode(id: UUID(), title: title, body: body, revision: 1, agent: .codex, sourceIDs: sources, path: path, extraMetadata: extra)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func database() throws -> SQLiteConnection { try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite")) }

    private func age(hours: Double) throws {
        try database().run("UPDATE entries SET updated_at=updated_at-?", [String(hours * 3600)])
    }

    private func local(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testPlanCoversChangedPagesNeighboursAndAPatrolOfOldPages() async throws {
        try write("Wiki/Projects/MyClip.md", title: "MyClip", body: "应用。相关 [[Wiki/Topics/ACP|ACP]]。")
        try write("Wiki/Topics/ACP.md", title: "ACP", body: "协议。")
        try write("Wiki/Topics/Old.md", title: "Old", body: "很久以前。")
        try write("Wiki/Archives/历史.md", title: "历史", body: "归档 [[Wiki/Projects/MyClip]]。")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        try age(hours: 48)
        let project = try await store.readMemory(path: "Wiki/Projects/MyClip.md")
        try await store.updateEntry(id: project.id, title: project.title, body: project.body + "\n新进展。", expectedRevision: project.revision)

        let planned = try await store.dreamPlan(at: Date(), calendar: calendar)
        let plan = try XCTUnwrap(planned)
        XCTAssertEqual(plan.changed, ["Wiki/Projects/MyClip.md"])
        XCTAssertEqual(plan.neighbours, ["Wiki/Topics/ACP.md"], "Links in both directions, never archives or unrelated pages")
        XCTAssertEqual(plan.patrol, ["Wiki/Topics/Old.md"], "Untouched knowledge pages outside today's scope are patrolled")
        let turns = MemoryPrompt.dreamTurns(plan: plan, handoff: nil)
        XCTAssertEqual(turns.map(\.title), ["整理今天", "巡检旧记忆"])
        XCTAssertTrue(turns[1].text.contains("- Wiki/Topics/Old.md（例行巡检）"))
    }

    func testDreamIsQueuedOncePerDreamDayWhenIdleAndOnlyWhenNothingWaits() async throws {
        try write("Wiki/Topics/A.md", title: "A", body: "事实。")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        // 02:30 local yesterday: still the dream day before. All moments stay in the past so real edits count as changes.
        let lateNight = calendar.date(bySettingHour: 2, minute: 30, second: 0, of: Date().addingTimeInterval(-86_400))!
        try await store.record(image: fixtureImage(), context: fixtureContext(at: lateNight.timeIntervalSince1970 - 5 * 60), agent: .claude, organize: false)
        let busy = try await store.enqueueDreamIfDue(agent: .claude, at: lateNight, calendar: calendar)
        XCTAssertNil(busy, "The user was active five minutes ago")

        let away = lateNight.addingTimeInterval(MemoryDream.idleInterval)
        let queued = try await store.enqueueDreamIfDue(agent: .claude, at: away, calendar: calendar)
        let dream = try XCTUnwrap(queued)
        XCTAssertEqual(dream.kind, .dream)
        XCTAssertTrue(dream.sourceIDs.isEmpty)
        XCTAssertEqual(dream.dreamPlan?.changed.contains("Wiki/Topics/A.md"), true)
        let twice = try await store.enqueueDreamIfDue(agent: .claude, at: away.addingTimeInterval(60), calendar: calendar)
        XCTAssertNil(twice, "One dream is queued or running at a time")

        let claimed = try await store.claimNextJob(at: away.addingTimeInterval(OrganizationQueue.interval), immediately: false)
        XCTAssertEqual(claimed?.id, dream.id, "The dream goes through the ordinary queue")
        let before = try await store.beginConsolidation()
        _ = try await store.finishDream(jobID: dream.id, previousRevisions: before, at: away.addingTimeInterval(600))
        let sameDay = try await store.enqueueDreamIfDue(agent: .claude, at: lateNight.addingTimeInterval(89 * 60), calendar: calendar)
        XCTAssertNil(sameDay, "03:59 local is still the same dream day")
        try write("Wiki/Topics/B.md", title: "B", body: "新事实。")
        let nextDay = try await store.enqueueDreamIfDue(agent: .claude, at: lateNight.addingTimeInterval(120 * 60), calendar: calendar)
        XCTAssertEqual(nextDay?.dreamPlan?.changed.contains("Wiki/Topics/B.md"), true, "After 04:00 local a new dream day begins")
    }

    func testManualDreamSkipsTheWaitGoesAheadOfScreenshotsAndStillPatrolsAQuietDay() async throws {
        try write("Wiki/Topics/A.md", title: "A", body: "事实。")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        try age(hours: 72)
        let now = Date()
        try await store.record(image: fixtureImage(), context: fixtureContext(at: now.timeIntervalSince1970 - 60), agent: .claude, organize: true)
        let automatic = try await store.enqueueDreamIfDue(agent: .claude, at: now, calendar: calendar)
        XCTAssertNil(automatic, "The automatic dream waits for idle time and an empty queue")
        let queued = try await store.enqueueDreamNow(agent: .claude, at: now, calendar: calendar)
        let dream = try XCTUnwrap(queued, "Nothing changed lately, but a manual dream still patrols")
        XCTAssertEqual(dream.dreamPlan?.patrol, ["Wiki/Topics/A.md"])
        XCTAssertEqual(dream.dreamPlan?.changed, [])
        let again = try await store.enqueueDreamNow(agent: .claude, at: now, calendar: calendar)
        XCTAssertNil(again, "One dream at a time")
        let claimed = try await store.claimNextJob(at: now, immediately: true)
        XCTAssertEqual(claimed?.id, dream.id, "The dream goes before screenshots that were already waiting")
        let pending = try await store.organizationQueue().pendingCount
        XCTAssertEqual(pending, 1, "The screenshot is still waiting for its batch")
        let before = try await store.beginConsolidation()
        _ = try await store.finishDream(jobID: dream.id, previousRevisions: before, at: now)
        let sameDay = try await store.enqueueDreamIfDue(agent: .claude, at: now.addingTimeInterval(3600), calendar: calendar)
        XCTAssertNil(sameDay, "A manual dream counts as the day's dream")
    }

    func testPendingScreenshotsKeepTheDreamWaiting() async throws {
        let store = try LibraryStore(root: root)
        try await store.record(image: fixtureImage(), context: fixtureContext(at: 100), agent: .claude, organize: true)
        let dream = try await store.enqueueDreamIfDue(agent: .claude, at: Date(timeIntervalSince1970: 100 + 86_400), calendar: calendar)
        XCTAssertNil(dream, "Screenshots waiting to be organized come first")
    }

    func testFinishedDreamMovesTheBaselineAndReviewClockButAFailedOneDoesNot() async throws {
        try write("Wiki/Topics/A.md", title: "A", body: "事实甲。")
        try write("Wiki/Topics/B.md", title: "B", body: "事实乙。")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let start = Date()
        let failedQueued = try await store.enqueueDreamIfDue(agent: .claude, at: start, calendar: calendar)
        let failed = try XCTUnwrap(failedQueued)
        _ = try await store.claimNextJob(immediately: true)
        let before = try await store.beginConsolidation()
        _ = try await store.finishDream(jobID: failed.id, previousRevisions: before, error: "Agent 响应超时。明天会再做。")
        let failedRow = try await store.snapshot().jobs.first { $0.id == failed.id }
        XCTAssertEqual(failedRow?.state, .failed)
        let queue = try await store.organizationQueue()
        XCTAssertFalse(queue.paused, "A dream never pauses the queue")
        XCTAssertTrue(try database().run("SELECT value FROM vault_meta WHERE key='consolidated_at'").isEmpty, "An unfinished dream keeps the baseline")
        XCTAssertTrue(try database().run("SELECT * FROM memory_reviews").isEmpty)

        let tomorrow = start.addingTimeInterval(86_400)
        let nextQueued = try await store.enqueueDreamIfDue(agent: .claude, at: tomorrow, calendar: calendar)
        let next = try XCTUnwrap(nextQueued)
        XCTAssertEqual(Set(next.dreamPlan?.changed ?? []).isSuperset(of: ["Wiki/Topics/A.md", "Wiki/Topics/B.md"]), true, "Yesterday's pages are still in scope")
        _ = try await store.claimNextJob(immediately: true)
        let again = try await store.beginConsolidation()
        _ = try await store.finishDream(jobID: next.id, previousRevisions: again, at: tomorrow)
        XCTAssertEqual(try database().run("SELECT * FROM memory_reviews").count, next.dreamPlan?.pages.count)
    }

    func testInterruptedDreamGetsOneMoreTryWithoutPausingTheQueue() async throws {
        try write("Wiki/Topics/A.md", title: "A", body: "事实。")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let queued = try await store.enqueueDreamIfDue(agent: .claude, calendar: calendar)
        let dream = try XCTUnwrap(queued)
        _ = try await store.claimNextJob(immediately: true)
        try await store.recoverInterruptedJobs(at: Date())
        var row = try await store.snapshot().jobs.first { $0.id == dream.id }
        XCTAssertEqual(row?.state, .queued)
        XCTAssertEqual(row?.retryAt.map { Int($0.timeIntervalSinceNow / 60) }, Int(MemoryDream.retryDelay / 60) - 1)
        _ = try await store.claimNextJob(immediately: true, jobID: dream.id)
        try await store.recoverInterruptedJobs(at: Date())
        row = try await store.snapshot().jobs.first { $0.id == dream.id }
        XCTAssertEqual(row?.state, .failed, "The second interruption ends the dream for today")
        let paused = try await store.organizationQueue().paused
        XCTAssertFalse(paused)
    }

    func testFirstDreamOfAWeekWritesLastWeeksSummaryInItsOwnTurn() async throws {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let monday = local("2026-09-21T02:00:00Z")  // 10:00 local, week 39
        for day in ["2026-09-14", "2026-09-16"] {
            try write("Daily/2026/09/\(day).md", title: day, body: "\(day) 的记录。")
        }
        try write("Daily/2026/09/2026-09-21.md", title: "2026-09-21", body: "本周。")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let planned = try await store.dreamPlan(at: monday, calendar: iso)
        let plan = try XCTUnwrap(planned)
        XCTAssertEqual(plan.weekly, WeeklySummary(path: "Daily/2026/Weekly/2026-W38.md", dailies: ["Daily/2026/09/2026-09-14.md", "Daily/2026/09/2026-09-16.md"]))
        let turns = MemoryPrompt.dreamTurns(plan: plan, handoff: nil)
        XCTAssertEqual(turns.first?.title, "回顾上周")
        XCTAssertTrue(turns[0].text.contains("新建 Daily/2026/Weekly/2026-W38.md"))
        XCTAssertTrue(turns[0].text.contains("[[Daily/2026/09/2026-09-14]]"))
        XCTAssertFalse(turns.dropFirst().contains { $0.text.contains("Weekly") }, "The summary has its own turn")

        try write("Daily/2026/Weekly/2026-W38.md", title: "2026-W38", body: "上周汇总。")
        let next = try await store.dreamPlan(at: monday, calendar: iso)
        XCTAssertNil(next?.weekly, "An existing summary is not written twice")
    }

    func testSettleRestoresDeletedRootFilesAndRejectedWritesAndRecomputesEvidence() async throws {
        let cited = UUID()
        try write("Wiki/Topics/A.md", title: "A", body: "事实甲。来源：截图 `\(cited)`。", sources: [cited])
        try write("Wiki/Topics/B.md", title: "B", body: "事实乙。")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let before = try await store.beginConsolidation()
        let directory = root.appendingPathComponent("Memory")
        // The agent merges A into B, deletes A, removes Now.md by mistake and empties Memory.md.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Wiki/Topics/A.md"))
        let bURL = directory.appendingPathComponent("Wiki/Topics/B.md")
        let bText = try String(contentsOf: bURL, encoding: .utf8).replacingOccurrences(of: "事实乙。", with: "事实乙。\n\n事实甲。来源：截图 `\(cited)`。")
        try bText.write(to: bURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Now.md"))
        let memoryURL = directory.appendingPathComponent("Memory.md")
        let index = try String(contentsOf: memoryURL, encoding: .utf8)
        try String(index[..<index.range(of: "\n---\n")!.upperBound]).write(to: memoryURL, atomically: true, encoding: .utf8)

        let changed = try await store.settleConsolidation(previousRevisions: before)
        XCTAssertEqual(changed, 2, "B changed and A was merged away")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Now.md").path), "A deleted root file comes back")
        let restoredIndex = try await store.readMemory(path: "Memory.md")
        XCTAssertFalse(restoredIndex.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "An emptied page goes back to its last revision")
        let merged = try await store.readMemory(path: "Wiki/Topics/B.md")
        XCTAssertEqual(merged.sourceIDs, [], "Citations of unknown screenshots are not evidence unless the page had them before")
        XCTAssertTrue(merged.body.contains("事实甲"))
        let untouched = try await store.settleConsolidation(previousRevisions: [:])
        XCTAssertEqual(untouched, 0, "Without a starting point nothing is treated as edited")
    }

    func testMisfiledPagesLeadTheScopeWithinTheLimit() async throws {
        for index in 0..<6 { try write("Inbox/某产品\(index)帖文.md", title: "某产品\(index)帖文", body: "外部帖子 \(index)。") }
        for index in 0..<20 { try write("Wiki/Topics/T\(index).md", title: "T\(index)", body: "主题 \(index)。") }
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let planned = try await store.dreamPlan(at: Date(), calendar: calendar)
        let plan = try XCTUnwrap(planned)
        XCTAssertEqual(plan.misfiled.count, MemoryDream.misfiledLimit)
        XCTAssertEqual(plan.misfiled.count + plan.changed.count + plan.neighbours.count, MemoryDream.scopeLimit)
        XCTAssertTrue(Set(plan.changed).isDisjoint(with: plan.misfiled))
        XCTAssertEqual(plan.patrol.count, MemoryDream.patrolLimit)
        XCTAssertTrue(Set(plan.patrol).isDisjoint(with: plan.misfiled + plan.changed + plan.neighbours))
        let prompt = MemoryPrompt.consolidationPrompt(plan: plan, handoff: nil)
        XCTAssertTrue(prompt.contains("- \(plan.misfiled[0])（需要归位）"))
    }


}
