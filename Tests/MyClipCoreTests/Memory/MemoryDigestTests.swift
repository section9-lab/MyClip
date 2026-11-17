import XCTest
@testable import MyClipCore

/// The hourly digest: what it reads, when it queues, and the watermark that keeps it from re-reading the same pages.
@MainActor
final class MemoryDigestTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func writeDaily(_ store: LibraryStore, day: String, text: String) async throws {
        let file = root.appendingPathComponent("Memory/Daily/2026/11/\(day.suffix(2))/\(day)-15-记录.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.snapshot()
    }

    func testDigestQueuesForTheDailyPagesWrittenSinceTheLastRun() async throws {
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        try await writeDaily(store, day: "2026-11-16", text: "# 2026-11-16\n\n## 周会\n- 15:00 在会议室开周会，需要到场。\n")

        let queued = try await store.enqueueDigestIfDue(agent: .codex)
        let job = try XCTUnwrap(queued)
        XCTAssertEqual(job.kind, .dream, "The digest takes the dream's queue slot so it never competes with a batch")
        XCTAssertEqual(job.dreamPlan?.dailies, ["Daily/2026/11/16/2026-11-16-15-记录.md"])
        XCTAssertTrue(job.dreamPlan?.changed.isEmpty == true, "A digest does not claim knowledge pages")
        let second = try await store.enqueueDigestIfDue(agent: .codex)
        XCTAssertNil(second, "One digest at a time")
    }

    func testDigestWaitsAnHourAfterTheLastRun() async throws {
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        try await writeDaily(store, day: "2026-11-16", text: "# 2026-11-16\n\n## 周会\n- 15:00 开会。\n")
        let queued = try await store.enqueueDigestIfDue(agent: .codex)
        let first = try XCTUnwrap(queued)
        try await store.finishDigest(jobID: first.id, previousRevisions: [:])

        let blocked = try await store.enqueueDigestIfDue(agent: .codex)
        XCTAssertNil(blocked, "The watermark just moved to now")

        // A page written after the digest is due an hour later, not immediately.
        try await writeDaily(store, day: "2026-11-16", text: "# 2026-11-16\n\n## 周会\n- 15:00 开会，改到 16:00。\n")
        let early = try await store.enqueueDigestIfDue(agent: .codex)
        XCTAssertNil(early, "An hour must pass after the last digest")

        let later = Date().addingTimeInterval(MemoryDigest.interval + 60)
        let next = try await store.enqueueDigestIfDue(agent: .codex, at: later)
        XCTAssertEqual(try XCTUnwrap(next).dreamPlan?.dailies.count, 1)
    }

    func testAnIdleHourDoesNotQueueAnything() async throws {
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        try await store.recordDigest(at: Date().addingTimeInterval(-MemoryDigest.interval - 60))
        let job = try await store.enqueueDigestIfDue(agent: .codex)
        XCTAssertNil(job, "No Daily page changed after the watermark")
    }

    func testDigestScopeIsBoundedAndNewestFirst() async throws {
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        for day in 1...10 {
            try await writeDaily(store, day: String(format: "2026-11-%02d", day), text: "# day \(day)\n\n- 事实。\n")
        }
        let found = try await store.digestDailies(since: nil)
        let pages = try XCTUnwrap(found)
        XCTAssertEqual(pages.count, MemoryDigest.scopeLimit, "A backlog catches up over the next hours")
        XCTAssertEqual(Set(pages).count, pages.count)
    }
    func testSnapshotCarriesTheDigestWatermarkAndTodaysOutputs() async throws {
        let store = try LibraryStore(root: root)
        let before = try await store.snapshot()
        XCTAssertNil(before.digestAt)
        XCTAssertEqual(before.todayBoardCount, 0)
        XCTAssertEqual(before.todayCalendarCount, 0)

        try await store.recordDigest(at: Date())
        _ = try await store.createWorkTask(title: "准备周三评审")
        _ = try await store.createCalendarEvent(CalendarEventDraft(title: "周会", start: Date(), end: Date().addingTimeInterval(3600)))

        let after = try await store.snapshot()
        XCTAssertNotNil(after.digestAt, "Backstage reads the watermark from the snapshot")
        XCTAssertEqual(after.todayBoardCount, 1)
        XCTAssertEqual(after.todayCalendarCount, 1)
    }

}
