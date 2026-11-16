import SwiftUI
import MyClipCore

struct CalendarMonthView: View {
    let monthOf: Date
    let events: [CalendarEvent]
    @Binding var selectedDay: Date
    let onSelect: (CalendarEvent) -> Void
    let onCreate: (Date) -> Void

    @Environment(\.calendar) private var calendar
    @Environment(\.colorScheme) private var colorScheme

    private var weeks: [[Date]] { CalendarLayout.monthGrid(for: monthOf, calendar: calendar) }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        GeometryReader { geometry in
            let dividers = CGFloat(max(0, weeks.count - 1))
            let rowHeight = max(64, (geometry.size.height - 30 - dividers) / CGFloat(max(1, weeks.count)))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(weekdaySymbols, id: \.self) { symbol in
                        Text(symbol).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 30)
                .overlay(alignment: .bottom) { Divider() }
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { column, day in
                            monthCell(day)
                            if column < week.count - 1 {
                                Rectangle()
                                    .fill(Color(nsColor: .separatorColor).opacity(0.28))
                                    .frame(width: 1)
                            }
                        }
                    }
                    .frame(height: rowHeight)
                    if index < weeks.count - 1 { Divider() }
                }
            }
        }
    }

    private func monthCell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: monthOf, toGranularity: .month)
        let today = calendar.isDateInToday(day)
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let dayEvents = CalendarLayout.events(on: day, in: events, calendar: calendar)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Button { selectedDay = calendar.startOfDay(for: day) } label: {
                    Text(verbatim: "\(calendar.component(.day, from: day))")
                        .font(.body.weight(today || selected ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(today ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.5))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(today ? Color.accentColor : Color.clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(date: .long, time: .omitted))
                Spacer(minLength: 0)
            }
            ForEach(dayEvents.prefix(3)) { event in
                Button { onSelect(event) } label: {
                    HStack(spacing: 4) {
                        Circle().fill(event.kind.tint).frame(width: 5, height: 5)
                        Text(event.title).font(.caption).lineLimit(1)
                            .foregroundStyle(inMonth ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(event.isAllDay ? event.kind.tint.opacity(colorScheme == .dark ? 0.2 : 0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(event.title)
            }
            if dayEvents.count > 3 {
                Text(String(localized: "还有 \(dayEvents.count - 3) 项"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cellBackground(inMonth: inMonth, selected: selected))
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = calendar.startOfDay(for: day) }
        .contextMenu {
            Button(String(localized: "新建日程")) { onCreate(day) }
            if !calendar.isDate(day, inSameDayAs: selectedDay) {
                Button(String(localized: "选择这一天")) { selectedDay = calendar.startOfDay(for: day) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(day, count: dayEvents.count, today: today))
    }

    private func cellBackground(inMonth: Bool, selected: Bool) -> Color {
        if selected { return Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.06) }
        if inMonth { return Color(nsColor: .windowBackgroundColor) }
        return Color(nsColor: .underPageBackgroundColor).opacity(0.22)
    }

    private func accessibilityLabel(_ day: Date, count: Int, today: Bool) -> String {
        let prefix = day.formatted(date: .long, time: .omitted)
        let suffix = count == 0 ? String(localized: "没有日程") : String(localized: "\(count) 项日程")
        return today ? String(localized: "\(prefix)，今天，\(suffix)") : "\(prefix)，\(suffix)"
    }
}
