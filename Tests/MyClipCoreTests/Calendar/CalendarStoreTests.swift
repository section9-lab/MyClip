import XCTest
@testable import MyClipCore

final class CalendarStoreTests: XCTestCase {
    var root: URL!
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    let now = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!

    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testMemoryEventBecomesEventAndReplayDoesNotDuplicate() async throws {
        let store = try LibraryStore(root: root)
        let source = try await capture(in: store)
        let memory = try await addMemory(store, source: source, start: "2026-11-17T10:00:00Z", end: "2026-11-17T11:00:00Z",
                                         precision: "range", evidence: "明天上午10点")

        let firstChanged = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)
        XCTAssertEqual(firstChanged, 1)
        let events = try await store.calendarEvents()
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.title, "客户电话")
        XCTAssertEqual(event.origin, .memory)
        XCTAssertEqual(event.memoryID, memory)
        XCTAssertEqual(event.start, date("2026-11-17T10:00:00Z"))
        XCTAssertEqual(event.end, date("2026-11-17T11:00:00Z"))
        XCTAssertFalse(event.isAllDay)
        XCTAssertTrue(event.evidence.contains("明天上午10点"))
        XCTAssertFalse(event.evidence.contains("myclip-event"))

        let replayChanged = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)
        XCTAssertEqual(replayChanged, 0)
        let replayEvents = try await store.calendarEvents()
        XCTAssertEqual(replayEvents.count, 1)
    }

    func testDayPrecisionBecomesAllDayWithExclusiveEnd() async throws {
        let store = try LibraryStore(root: root)
        let source = try await capture(in: store)
        _ = try await addMemory(store, source: source, start: "2026-11-20T00:00:00Z", end: "2026-11-21T00:00:00Z",
                                precision: "day", evidence: "11月20日")

        _ = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)
        let allDayEvents = try await store.calendarEvents()
        let event = try XCTUnwrap(allDayEvents.first)
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.start, date("2026-11-20T00:00:00Z"))
        XCTAssertEqual(event.end, date("2026-11-21T00:00:00Z"))
    }

    func testEventThatAlreadyEndedIsNotImported() async throws {
        let store = try LibraryStore(root: root)
        let source = try await capture(in: store)
        _ = try await addMemory(store, source: source, start: "2026-11-15T10:00:00Z", end: "2026-11-15T11:00:00Z",
                                precision: "range", evidence: "昨天上午10点")

        let changed = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)
        XCTAssertEqual(changed, 0)
        let events = try await store.calendarEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testUserEditIsNotOverwrittenOrDuplicated() async throws {
        let store = try LibraryStore(root: root)
        let source = try await capture(in: store)
        let memory = try await addMemory(store, source: source, start: "2026-11-17T10:00:00Z", end: "2026-11-17T11:00:00Z",
                                         precision: "range", evidence: "明天上午10点")
        _ = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)
        let before = try await store.calendarEvents()
        let original = try XCTUnwrap(before.first)

        try await store.updateCalendarEvent(original.id, CalendarEventDraft(
            title: "改过的名字", project: "客户协作", kind: .meeting,
            start: date("2026-11-17T10:00:00Z"), end: date("2026-11-17T11:00:00Z")))
        let unchanged = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)
        XCTAssertEqual(unchanged, 0)

        let events = try await store.calendarEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.title, "改过的名字")
        XCTAssertEqual(events.first?.memoryID, memory)
        XCTAssertEqual(events.first?.edited, true)

        // A later agent pass still recognizes the same passage, but leaves the edited event alone.
        try await addMemory(store, id: memory, revision: 2, source: source,
                            start: "2026-11-17T12:00:00Z", end: "2026-11-17T13:00:00Z",
                            precision: "range", evidence: "明天上午10点")
        let afterRewrite = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)
        XCTAssertEqual(afterRewrite, 0)
        let edited = try await store.calendarEvents()
        XCTAssertEqual(edited.first?.start, date("2026-11-17T10:00:00Z"))
    }

    func testDismissedEventStaysDismissedAcrossSync() async throws {
        let store = try LibraryStore(root: root)
        let source = try await capture(in: store)
        _ = try await addMemory(store, source: source, start: "2026-11-18T10:00:00Z", end: "2026-11-18T11:00:00Z",
                                precision: "range", evidence: "周三上午10点")
        _ = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)
        let scheduled = try await store.calendarEvents()
        let event = try XCTUnwrap(scheduled.first)

        try await store.dismissCalendarEvent(event.id)
        let visible = try await store.calendarEvents()
        XCTAssertTrue(visible.isEmpty)
        let restored = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)
        XCTAssertEqual(restored, 0)
        let stillHidden = try await store.calendarEvents()
        XCTAssertTrue(stillHidden.isEmpty)
    }

    func testAgentRewriteUpdatesTimeWithoutAddingAnEvent() async throws {
        let store = try LibraryStore(root: root)
        let source = try await capture(in: store)
        let memory = try await addMemory(store, source: source, start: "2026-11-17T10:00:00Z", end: "2026-11-17T11:00:00Z",
                                         precision: "range", evidence: "明天上午10点")
        _ = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)

        _ = try await addMemory(store, id: memory, revision: 2, source: source,
                                start: "2026-11-17T14:00:00Z", end: "2026-11-17T15:00:00Z",
                                precision: "range", evidence: "明天下午2点")
        let firstChanged = try await store.synchronizeCalendarEvents(now: now, calendar: calendar)
        XCTAssertEqual(firstChanged, 1)
        let events = try await store.calendarEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.start, date("2026-11-17T14:00:00Z"))
        XCTAssertTrue(events.first?.evidence.contains("下午2点") == true)
    }

    func testManualAllDayRangeIsNormalizedAndValidated() async throws {
        let store = try LibraryStore(root: root)
        let sameDay = try await store.createCalendarEvent(CalendarEventDraft(
            title: "出差", kind: .travel, start: date("2026-11-20T08:00:00Z"), end: date("2026-11-20T09:00:00Z"),
            isAllDay: true), calendar: calendar)
        let createdEvents = try await store.calendarEvents()
        let event = try XCTUnwrap(createdEvents.first { $0.id == sameDay })
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.start, date("2026-11-20T00:00:00Z"))
        XCTAssertEqual(event.end, date("2026-11-21T00:00:00Z"))

        do {
            _ = try await store.createCalendarEvent(CalendarEventDraft(title: "", start: now, end: now.addingTimeInterval(60)), calendar: calendar)
            XCTFail("An empty title must be rejected")
        } catch {}
        do {
            _ = try await store.createCalendarEvent(CalendarEventDraft(title: "倒序", start: now, end: now.addingTimeInterval(-60)), calendar: calendar)
            XCTFail("An end before the start must be rejected")
        } catch {}
    }

    func testCalendarTitleStripsPresentationAndKeepsFirstSentence() {
        XCTAssertEqual(LibraryStore.calendarTitle(from: "- **客户电话**。明天上午10点。来源：截图 `ABC`", fallback: "备份"), "客户电话")
        XCTAssertEqual(LibraryStore.calendarTitle(from: "## 同步 [[Wiki/Projects/客户协作|客户]] 交付", fallback: "备份"), "同步 客户 交付")
        XCTAssertEqual(LibraryStore.calendarTitle(from: "<!---->", fallback: "备份"), "备份")
        XCTAssertEqual(LibraryStore.calendarTitle(from: "", fallback: "备份"), "备份")
    }

    // MARK: - Helpers

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func capture(in store: LibraryStore) async throws -> CaptureContext {
        let context = fixtureContext(at: 1_000)
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: false)
        return context
    }

    @discardableResult
    private func addMemory(_ store: LibraryStore, id: UUID = UUID(), revision: Int = 1, source: CaptureContext,
                           start: String, end: String, precision: String, evidence: String) async throws -> UUID {
        let annotation = "<!-- myclip-event {\"start\":\"\(start)\",\"end\":\"\(end)\",\"precision\":\"\(precision)\",\"evidence\":\"\(evidence)\"} -->"
        let body = annotation + "\n- 客户电话。\(evidence)。来源：截图 `\(source.id.uuidString)`"
        _ = try await store.saveEntry(id: id, kind: .memory, title: "客户电话", body: body, revision: revision,
                                      agent: .codex, sourceIDs: [source.id], updatedAt: now)
        return id
    }
}
