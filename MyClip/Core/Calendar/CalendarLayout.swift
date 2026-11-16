import Foundation

/// Pure date math for the calendar UI. Everything takes an explicit `Calendar` so tests can cover
/// first-weekday and daylight-saving differences without depending on the machine locale.
public enum CalendarLayout {
    public struct EventSlot: Identifiable, Sendable, Equatable {
        public let event: CalendarEvent
        public let lane: Int
        public let laneCount: Int
        public var id: UUID { event.id }
    }

    public struct DayGroup: Identifiable, Sendable, Equatable {
        public let date: Date
        public let events: [CalendarEvent]
        public var id: Date { date }
    }

    public static func dayStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    public static func dayEnd(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
    }

    /// An all-day event, or a timed event that crosses midnight, belongs to the pinned band instead of the hour grid.
    public static func isBand(_ event: CalendarEvent, calendar: Calendar) -> Bool {
        if event.isAllDay { return true }
        return !calendar.isDate(event.start, inSameDayAs: event.end.addingTimeInterval(-1))
    }

    /// Local days an event occupies. `end` is exclusive, matching Memory's day-precision range.
    public static func daysCovered(by event: CalendarEvent, calendar: Calendar, limit: Int = 366) -> [Date] {
        guard event.end > event.start else { return [] }
        let first = calendar.startOfDay(for: event.start)
        let last = calendar.startOfDay(for: event.end.addingTimeInterval(-1))
        var days: [Date] = []
        var cursor = first
        while cursor <= last && days.count < limit {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    public static func intersects(_ event: CalendarEvent, day: Date, calendar: Calendar) -> Bool {
        event.start < dayEnd(day, calendar: calendar) && event.end > dayStart(day, calendar: calendar)
    }

    public static func events(on day: Date, in events: [CalendarEvent], calendar: Calendar) -> [CalendarEvent] {
        events.filter { intersects($0, day: day, calendar: calendar) }.sorted(by: sort)
    }

    public static func groups(for month: Date, events: [CalendarEvent], calendar: Calendar) -> [DayGroup] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        var grouped: [Date: [CalendarEvent]] = [:]
        for event in events {
            for day in daysCovered(by: event, calendar: calendar)
            where day >= interval.start && day < interval.end {
                grouped[day, default: []].append(event)
            }
        }
        return grouped.keys.sorted().map { DayGroup(date: $0, events: grouped[$0]!.sorted(by: sort)) }
    }

    /// Greedy lane assignment within each cluster of overlapping events. Non-overlapping events keep full width.
    public static func slots(on day: Date, in events: [CalendarEvent], calendar: Calendar) -> [EventSlot] {
        let timed = events.filter { !isBand($0, calendar: calendar) }.sorted(by: sort)
        var result: [EventSlot] = []
        var cluster: [(event: CalendarEvent, lane: Int)] = []
        var laneEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let count = max(1, laneEnds.count)
            for item in cluster {
                result.append(EventSlot(event: item.event, lane: item.lane, laneCount: count))
            }
            cluster.removeAll(keepingCapacity: true)
            laneEnds.removeAll(keepingCapacity: true)
            clusterEnd = .distantPast
        }

        for event in timed {
            if !cluster.isEmpty && event.start >= clusterEnd { flush() }
            let lane: Int
            if let free = laneEnds.firstIndex(where: { $0 <= event.start }) {
                lane = free
                laneEnds[free] = event.end
            } else {
                lane = laneEnds.count
                laneEnds.append(event.end)
            }
            cluster.append((event, lane))
            clusterEnd = max(clusterEnd, event.end)
        }
        flush()
        return result
    }

    public static func bandEvents(on day: Date, in events: [CalendarEvent], calendar: Calendar) -> [CalendarEvent] {
        events.filter { intersects($0, day: day, calendar: calendar) && isBand($0, calendar: calendar) }.sorted(by: sort)
    }

    /// Visible hour range for a day or week. Defaults to 07:00–22:00 and expands to include every timed event,
    /// so a late meeting is never silently clipped. `end` is exclusive.
    public static func hourRange(for events: [CalendarEvent], on days: [Date], calendar: Calendar) -> Range<Int> {
        var start = 7, end = 22
        for day in days {
            for event in Self.events(on: day, in: events, calendar: calendar) where !isBand(event, calendar: calendar) {
                let first = calendar.component(.hour, from: event.start)
                let lastDate = max(event.start, event.end.addingTimeInterval(-1))
                let last = calendar.component(.hour, from: lastDate) + 1
                start = min(start, first)
                end = max(end, last)
            }
        }
        let lower = max(0, min(23, start))
        let upper = max(lower + 1, min(24, end))
        return lower..<upper
    }

    /// Seven local days starting on the calendar's first weekday.
    public static func weekDays(containing day: Date, calendar: Calendar) -> [Date] {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Complete weeks covering the month, including the leading and trailing days of adjacent months.
    public static func monthGrid(for month: Date, calendar: Calendar) -> [[Date]] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start else { return [] }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.start ?? lastDay
        var weeks: [[Date]] = []
        var cursor = firstWeek
        while cursor <= lastWeek && weeks.count < 6 {
            weeks.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: cursor) })
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return weeks
    }

    public static func sort(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
