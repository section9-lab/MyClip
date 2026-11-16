import SwiftUI
import MyClipCore

struct CalendarWeekView: View {
    let weekOf: Date
    let events: [CalendarEvent]
    @Binding var selectedDay: Date
    let onSelect: (CalendarEvent) -> Void
    let onCreate: (Date) -> Void

    @Environment(\.calendar) private var calendar
    @Environment(\.colorScheme) private var colorScheme
    private let hourHeight: CGFloat = 52
    private let labelWidth: CGFloat = 58
    private let headerHeight: CGFloat = 56

    private var days: [Date] { CalendarLayout.weekDays(containing: weekOf, calendar: calendar) }
    private var hourRange: Range<Int> { CalendarLayout.hourRange(for: events, on: days, calendar: calendar) }
    private var contentHeight: CGFloat { CGFloat(hourRange.count) * hourHeight }
    private var bandRows: Int {
        days.map { CalendarLayout.bandEvents(on: $0, in: events, calendar: calendar).count }.max() ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            if bandRows > 0 { bandSection }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    timeGrid
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
                .task(id: "\(weekOf.timeIntervalSince1970)-\(hourRange.lowerBound)-\(hourRange.upperBound)") {
                    try? await Task.sleep(for: .milliseconds(160))
                    scrollToNow(proxy)
                }
            }
        }
    }

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth)
            ForEach(days, id: \.self) { day in
                let selected = calendar.isDate(day, inSameDayAs: selectedDay)
                let today = calendar.isDateInToday(day)
                Button { selectedDay = calendar.startOfDay(for: day) } label: {
                    VStack(spacing: 1) {
                        Text(weekdaySymbol(day))
                            .font(.caption)
                            .foregroundStyle(today ? Color.accentColor : Color.secondary)
                        Text(verbatim: "\(calendar.component(.day, from: day))")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(today ? Color.white : Color.primary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(today ? Color.accentColor : Color.clear))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                .contextMenu { Button(String(localized: "新建日程")) { onCreate(day) } }
            }
        }
        .frame(height: headerHeight)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var bandSection: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(String(localized: "全天"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .padding(.trailing, 8).padding(.top, 4)
            ForEach(days, id: \.self) { day in
                let items = CalendarLayout.bandEvents(on: day, in: events, calendar: calendar)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items.prefix(3)) { event in
                        Button { onSelect(event) } label: {
                            HStack(spacing: 3) {
                                Text(event.title).font(.caption2).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(event.kind.tint.opacity(colorScheme == .dark ? 0.22 : 0.12),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(event.title)
                    }
                    if items.count > 3 {
                        Text(String(localized: "还有 \(items.count - 3) 项"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 3)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var timeGrid: some View {
        GeometryReader { geometry in
            let columnWidth = max(1, (geometry.size.width - labelWidth) / CGFloat(days.count))
            ZStack(alignment: .topLeading) {
                hourLines(width: geometry.size.width, columnWidth: columnWidth)
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    dayColumn(day, width: columnWidth)
                        .frame(width: columnWidth, height: contentHeight, alignment: .topLeading)
                        .offset(x: labelWidth + CGFloat(index) * columnWidth)
                }
                ForEach(hourRange, id: \.self) { hour in
                    Color.clear.frame(width: 1, height: 1)
                        .offset(y: CGFloat(hour - hourRange.lowerBound) * hourHeight)
                        .id(hour)
                }
                currentTimeLine(width: geometry.size.width, columnWidth: columnWidth)
            }
            .frame(height: contentHeight)
        }
        .frame(height: contentHeight)
    }

    private func hourLines(width: CGFloat, columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(hourRange, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: labelWidth - 10, alignment: .trailing)
                    .offset(y: CGFloat(hour - hourRange.lowerBound) * hourHeight - 7)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    .frame(width: width - labelWidth, height: 1)
                    .offset(x: labelWidth, y: CGFloat(hour - hourRange.lowerBound) * hourHeight)
            }
            ForEach(1..<max(2, days.count), id: \.self) { index in
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.28))
                    .frame(width: 1, height: contentHeight)
                    .offset(x: labelWidth + CGFloat(index) * columnWidth)
            }
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.35))
                .frame(width: width - labelWidth, height: 1)
                .offset(x: labelWidth, y: contentHeight)
        }
        .accessibilityHidden(true)
    }

    private func dayColumn(_ day: Date, width: CGFloat) -> some View {
        let dayEvents = CalendarLayout.events(on: day, in: events, calendar: calendar)
        let slots = CalendarLayout.slots(on: day, in: dayEvents, calendar: calendar)
        return ZStack(alignment: .topLeading) {
            ForEach(slots) { slot in
                let start = slot.event.start
                let end = slot.event.end
                let y = start.timeIntervalSince(calendar.startOfDay(for: day)) / 3600 * hourHeight
                        - CGFloat(hourRange.lowerBound) * hourHeight
                let height = max(24, end.timeIntervalSince(start) / 3600 * hourHeight - 2)
                // In a narrow week column, stacking with a small offset keeps titles readable while still
                // showing which event starts first. Equal half-width lanes leave no room for any text.
                let gap: CGFloat = 12
                let laneWidth = max(24, width - 4 - gap * CGFloat(slot.laneCount - 1))
                Button { onSelect(slot.event) } label: {
                    weekCard(slot.event)
                        .frame(width: laneWidth, height: height, alignment: .topLeading)
                }
                .buttonStyle(.plain)
                .offset(x: 2 + CGFloat(slot.lane) * gap, y: y)
                .help(slot.event.title)
            }
        }
    }

    @ViewBuilder private func currentTimeLine(width: CGFloat, columnWidth: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: context.date) }) {
                let y = context.date.timeIntervalSince(calendar.startOfDay(for: context.date)) / 3600 * hourHeight
                        - CGFloat(hourRange.lowerBound) * hourHeight
                if y >= 0, y <= contentHeight {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.red)
                            .frame(width: width - labelWidth, height: 1)
                            .offset(x: labelWidth, y: y)
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                            .offset(x: labelWidth + CGFloat(index) * columnWidth + columnWidth / 2 - 3, y: y - 3)
                    }
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private func weekCard(_ event: CalendarEvent) -> some View {
        Text(event.title)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.leading, 6).padding(.trailing, 3).padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(event.kind.tint.opacity(colorScheme == .dark ? 0.24 : 0.14), in: RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(event.kind.tint)
                    .frame(width: 2).padding(.vertical, 3).padding(.leading, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(event.title)
            .accessibilityHint(String(localized: "打开日程详情"))
    }

    private func weekdaySymbol(_ day: Date) -> String {
        let index = calendar.component(.weekday, from: day) - 1
        let symbols = calendar.shortWeekdaySymbols
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: weekOf) ?? weekOf
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        if days.contains(where: { calendar.isDateInToday($0) }) {
            let now = min(max(calendar.component(.hour, from: Date()), hourRange.lowerBound), hourRange.upperBound - 1)
            proxy.scrollTo(now, anchor: .center)
        } else {
            proxy.scrollTo(hourRange.lowerBound, anchor: .top)
        }
    }
}
