import XCTest
@testable import MyClipCore

@MainActor
final class CaptureFilterTests: XCTestCase {
    private var directory: URL!
    private var store: LibraryStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try LibraryStore(root: directory)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultFilterIncludesEveryTrigger() async throws {
        let reasons: [CaptureReason] = [.pointerIdle, .clickIdle, .clickAfterIdle, .scrollIdle, .enter, .manual]
        for reason in reasons { try await record(reason: reason) }
        let result = try await store.snapshot(captureFilter: CaptureFilter())
        XCTAssertEqual(result.captures.count, reasons.count)
        XCTAssertEqual(result.captureCount, reasons.count)
        XCTAssertFalse(CaptureFilter().isActive)
    }

    func testApplicationFilterUsesExactNames() async throws {
        let expected = try await record(app: "O'Reilly")
        try await record(app: "O'Reilly Notes")
        try await record(app: "全部应用")
        let result = try await store.snapshot(captureFilter: CaptureFilter(appName: "O'Reilly"))
        XCTAssertEqual(result.captures.map(\.id), [expected])
        let namedAll = try await store.snapshot(captureFilter: CaptureFilter(appName: "全部应用"))
        XCTAssertEqual(namedAll.captures.map(\.appName), ["全部应用"])
    }

    func testMouseFilterIncludesLegacyClicksAndScrolls() async throws {
        let mouseReasons: [CaptureReason] = [.pointerIdle, .clickIdle, .clickAfterIdle, .scrollIdle]
        for reason in mouseReasons + [.enter, .manual] { try await record(reason: reason) }
        let mouse = try await store.snapshot(captureFilter: CaptureFilter(event: .mouse))
        XCTAssertEqual(Set(mouse.captures.map(\.reason)), Set(mouseReasons))
        let keyboard = try await store.snapshot(captureFilter: CaptureFilter(event: .keyboard))
        XCTAssertEqual(keyboard.captures.map(\.reason), [.enter])
    }

    func testDateRangeIncludesWholeLocalDays() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = date("2026-09-18T04:00:00Z")
        let end = date("2026-09-19T04:00:00Z")
        try await record(at: date("2026-09-17T15:59:59Z"))
        let first = try await record(at: date("2026-09-17T16:00:00Z"))
        let last = try await record(at: date("2026-09-19T15:59:59Z"))
        try await record(at: date("2026-09-19T16:00:00Z"))
        let result = try await store.snapshot(captureFilter: CaptureFilter(dateRange: start...end), calendar: calendar)
        XCTAssertEqual(result.captures.map(\.id), [last, first])
    }

    func testSingleDayRangeHandlesDaylightSavingChanges() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (startText, endText) in [("2026-03-08T08:00:00Z", "2026-03-09T07:00:00Z"),
                                     ("2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z")] {
            let start = date(startText)
            let end = date(endText)
            try await record(at: start.addingTimeInterval(-1))
            let first = try await record(at: start)
            let last = try await record(at: end.addingTimeInterval(-1))
            try await record(at: end)
            let result = try await store.snapshot(captureFilter: CaptureFilter(dateRange: start...start), calendar: calendar)
            XCTAssertEqual(result.captures.map(\.id), [last, first])
        }
    }

    func testFiltersIntersectWithKeywordSearch() async throws {
        let day = date("2026-09-19T04:00:00Z")
        let expected = try await record(title: "Review notes", reason: .enter, at: day)
        try await record(app: "Review Tool", reason: .enter, at: day)
        try await record(title: "Review yesterday", reason: .enter, at: day.addingTimeInterval(-86_400))
        try await record(title: "Review click", reason: .clickAfterIdle, at: day)
        try await record(title: "Unrelated", reason: .enter, at: day)
        let filter = CaptureFilter(appName: "Notes", dateRange: day...day, event: .keyboard)
        let result = try await store.snapshot(query: "Review", captureFilter: filter)
        XCTAssertEqual(result.captures.map(\.id), [expected])
        XCTAssertEqual(result.captureCount, 1)
        XCTAssertEqual(result.captureAppNames, ["Notes", "Review Tool"])
        let empty = try await store.snapshot(query: "Missing", captureFilter: filter)
        XCTAssertTrue(empty.captures.isEmpty)
        XCTAssertEqual(empty.captureCount, 0)
        XCTAssertEqual(empty.captureAppNames, result.captureAppNames)
    }

    func testFiltersFindCapturesBeforeTheLatestFiveHundred() async throws {
        let day = date("2026-09-18T04:00:00Z")
        let expected = try await record(reason: .enter, at: day)
        for index in 0..<500 {
            try await record(app: "Safari", at: day.addingTimeInterval(86_400 + Double(index)))
        }
        let library = try await store.snapshot()
        XCTAssertEqual(library.captures.count, 500)
        XCTAssertEqual(library.captureCount, 501)
        XCTAssertEqual(library.captureAppNames, ["Notes", "Safari"])
        for filter in [CaptureFilter(appName: "Notes"), CaptureFilter(dateRange: day...day), CaptureFilter(event: .keyboard)] {
            let result = try await store.snapshot(captureFilter: filter)
            XCTAssertEqual(result.captures.map(\.id), [expected])
            XCTAssertEqual(result.captureCount, 1)
        }
    }

    func testClearingFiltersRestoresAllCaptures() async throws {
        try await record()
        try await record(app: "Safari", reason: .manual)
        let day = Date()
        for active in [CaptureFilter(appName: "Missing"), CaptureFilter(dateRange: day...day), CaptureFilter(event: .keyboard)] {
            var filter = active
            XCTAssertTrue(filter.isActive)
            let empty = try await store.snapshot(captureFilter: filter)
            XCTAssertTrue(empty.captures.isEmpty)
            filter = CaptureFilter()
            XCTAssertFalse(filter.isActive)
            let restored = try await store.snapshot(captureFilter: filter)
            XCTAssertEqual(restored.captures.count, 2)
        }
    }

    @discardableResult
    private func record(app: String = "Notes", title: String = "Window", reason: CaptureReason = .clickAfterIdle,
                        at date: Date = Date(timeIntervalSince1970: 100)) async throws -> UUID {
        let context = CaptureContext(appName: app, bundleID: "test.\(app)", windowTitle: title, windowID: 1, reason: reason, date: date)
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: false)
        return context.id
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
}
