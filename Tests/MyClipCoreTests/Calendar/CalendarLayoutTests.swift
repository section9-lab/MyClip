import XCTest
@testable import MyClipCore

final class CalendarLayoutTests: XCTestCase {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }()

    func testOverlappingEventsShareLanesWhileSeparateEventsKeepFullWidth() {
        let first = event("A", start: "2026-11-16T10:00:00Z", end: "2026-11-16T11:00:00Z")
        let second = event("B", start: "2026-11-16T10:30:00Z", end: "2026-11-16T11:30:00Z")
        let later = event("C", start: "2026-11-16T13:00:00Z", end: "2026-11-16T14:00:00Z")
        let slots = CalendarLayout.slots(on: date("2026-11-16T00:00:00Z"), in: [first, second, later], calendar: calendar)
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots.first { $0.event.id == first.id }?.lane, 0)
        XCTAssertEqual(slots.first { $0.event.id == second.id }?.lane, 1)
        XCTAssertEqual(slots.first { $0.event.id == first.id }?.laneCount, 2)
        XCTAssertEqual(slots.first { $0.event.id == later.id }?.lane, 0)
        XCTAssertEqual(slots.first { $0.event.id == later.id }?.laneCount, 1)
    }

    func testMultiDayEventCoversEveryLocalDayAndIsExclusiveAtTheEnd() {
        let travel = event("出差", start: "2026-11-16T00:00:00Z", end: "2026-11-19T00:00:00Z", allDay: true)
        let days = CalendarLayout.daysCovered(by: travel, calendar: calendar)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days.first, date("2026-11-16T00:00:00Z"))
        XCTAssertEqual(days.last, date("2026-11-18T00:00:00Z"))
        XCTAssertFalse(CalendarLayout.intersects(travel, day: date("2026-11-19T00:00:00Z"), calendar: calendar))
    }

    func testMonthGroupsListAllDayFirstAndSkipEmptyDays() {
        let allDay = event("出差", start: "2026-11-16T00:00:00Z", end: "2026-11-18T00:00:00Z", allDay: true)
        let meeting = event("评审", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")
        let groups = CalendarLayout.groups(for: date("2026-11-01T00:00:00Z"), events: [meeting, allDay], calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.date, date("2026-11-16T00:00:00Z"))
        XCTAssertEqual(groups.first?.events.first?.title, "出差")
        XCTAssertEqual(groups.first?.events.count, 2)
        XCTAssertEqual(groups.last?.date, date("2026-11-17T00:00:00Z"))
        XCTAssertEqual(groups.last?.events.map(\.title), ["出差"])
    }

    func testDaylightSavingDayKeepsCalendarDayBoundaries() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let event = event("跨夜", start: "2026-10-24T21:00:00Z", end: "2026-10-25T22:00:00Z")
        let days = CalendarLayout.daysCovered(by: event, calendar: berlin)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0], berlin.startOfDay(for: event.start))
        XCTAssertEqual(days[1], berlin.startOfDay(for: event.end.addingTimeInterval(-1)))
    }

    func testWeekStartsOnTheCalendarsFirstWeekday() {
        XCTAssertEqual(CalendarLayout.weekDays(containing: date("2026-11-18T12:00:00Z"), calendar: calendar).first,
                       date("2026-11-16T00:00:00Z"))
        var sunday = calendar
        sunday.firstWeekday = 1
        XCTAssertEqual(CalendarLayout.weekDays(containing: date("2026-11-18T12:00:00Z"), calendar: sunday).first,
                       date("2026-11-15T00:00:00Z"))
    }

    func testMonthGridIncludesLeadingAndTrailingDays() {
        let weeks = CalendarLayout.monthGrid(for: date("2026-11-10T00:00:00Z"), calendar: calendar)
        XCTAssertEqual(weeks.count, 6)
        XCTAssertEqual(weeks.first?.first, date("2026-10-26T00:00:00Z"))
        XCTAssertEqual(weeks.last?.last, date("2026-12-06T00:00:00Z"))
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })

        var sunday = calendar
        sunday.firstWeekday = 1
        let sundayWeeks = CalendarLayout.monthGrid(for: date("2026-11-10T00:00:00Z"), calendar: sunday)
        XCTAssertEqual(sundayWeeks.count, 5)
        XCTAssertEqual(sundayWeeks.first?.first, date("2026-11-01T00:00:00Z"))
        XCTAssertEqual(sundayWeeks.last?.last, date("2026-12-05T00:00:00Z"))
    }

    func testHourRangeExpandsToLateEventsAndKeepsAnEarlyStart() {
        let morning = event("早会", start: "2026-11-16T06:30:00Z", end: "2026-11-16T07:00:00Z")
        let late = event("夜谈", start: "2026-11-16T23:00:00Z", end: "2026-11-16T23:45:00Z")
        let range = CalendarLayout.hourRange(for: [morning, late], on: [date("2026-11-16T00:00:00Z")], calendar: calendar)
        XCTAssertEqual(range.lowerBound, 6)
        XCTAssertEqual(range.upperBound, 24)
        XCTAssertEqual(CalendarLayout.hourRange(for: [], on: [date("2026-11-16T00:00:00Z")], calendar: calendar), 7..<22)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func event(_ title: String, start: String, end: String, allDay: Bool = false) -> CalendarEvent {
        let startDate = date(start), endDate = date(end)
        return CalendarEvent(id: UUID(), title: title, notes: "", location: "", project: "",
                             kind: .other, start: startDate, end: endDate, isAllDay: allDay,
                             origin: .user, edited: false)
    }
}
