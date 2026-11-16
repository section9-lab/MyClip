import SwiftUI
import MyClipCore

private struct CalendarEventRequest: Identifiable {
    let id = UUID()
    let event: CalendarEvent?
    let day: Date
}

private struct CalendarSelection: Identifiable {
    let id: UUID
}

enum CalendarViewMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: String(localized: "日")
        case .week: String(localized: "周")
        case .month: String(localized: "月")
        }
    }
}

struct CalendarPageView: View {
    @ObservedObject var model: MyClipModel
    @Environment(\.calendar) private var calendar
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var mode: CalendarViewMode = .week
    @State private var editing: CalendarEventRequest?
    @State private var selection: CalendarSelection?

    var body: some View {
        GeometryReader { geometry in
            let showsRail = geometry.size.width >= 820 && mode != .month
            VStack(spacing: 0) {
                header(compact: geometry.size.width < 760)
                Divider()
                HStack(spacing: 0) {
                    if showsRail {
                        CalendarMonthRail(selectedDay: $selectedDay, events: model.calendarEvents,
                                          onSelectEvent: { selection = CalendarSelection(id: $0.id) })
                            .frame(width: 300)
                        Divider()
                    }
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refreshCalendar(force: true) }
        .onChange(of: selectedDay) { day in
            let start = calendar.startOfDay(for: day)
            if start != day { selectedDay = start }
        }
        .sheet(item: $editing) { request in
            CalendarEventEditor(model: model, event: request.event, day: request.day) { saved in
                if let event = model.calendarEvents.first(where: { $0.id == saved }) {
                    selectedDay = calendar.startOfDay(for: event.start)
                }
            }
        }
        .sheet(item: $selection) { item in
            CalendarEventDetail(model: model, eventID: item.id)
        }
    }

    @ViewBuilder private var content: some View {
        if let error = model.calendarLoadError {
            VStack(spacing: 0) { errorBanner(error); Spacer(minLength: 0) }
        } else if !model.calendarLoaded {
            ProgressView(String(localized: "正在读取日程…"))
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch mode {
            case .day:
                CalendarDayView(day: selectedDay, events: model.calendarEvents,
                                onSelect: { selection = CalendarSelection(id: $0.id) },
                                onCreate: { editing = CalendarEventRequest(event: nil, day: $0) })
            case .week:
                CalendarWeekView(weekOf: selectedDay, events: model.calendarEvents, selectedDay: $selectedDay,
                                 onSelect: { selection = CalendarSelection(id: $0.id) },
                                 onCreate: { editing = CalendarEventRequest(event: nil, day: $0) })
            case .month:
                CalendarMonthView(monthOf: selectedDay, events: model.calendarEvents, selectedDay: $selectedDay,
                                  onSelect: { selection = CalendarSelection(id: $0.id) },
                                  onCreate: { editing = CalendarEventRequest(event: nil, day: $0) })
            }
        }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(previousLabel)
                    .help(previousLabel)
                Text(periodTitle)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
                    .frame(minWidth: 150, alignment: .leading)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(nextLabel)
                    .help(nextLabel)
            }
            Spacer(minLength: 8)
            if compact {
                Menu {
                    ForEach(CalendarViewMode.allCases) { item in
                        Button { mode = item } label: {
                            if item == mode {
                                Label(item.title, systemImage: "checkmark")
                            } else {
                                Text(item.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(mode.title)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 74)
                .accessibilityLabel(String(localized: "视图"))
            } else {
                Picker("", selection: $mode) {
                    ForEach(CalendarViewMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 156)
                .accessibilityLabel(String(localized: "视图"))
            }
            Button(String(localized: "今天")) { selectedDay = calendar.startOfDay(for: Date()) }
                .controlSize(.small)
                .help(String(localized: "回到今天"))
            Button { editing = CalendarEventRequest(event: nil, day: selectedDay) } label: {
                if compact {
                    Image(systemName: "plus")
                        .accessibilityLabel(String(localized: "新建日程"))
                } else {
                    Label(String(localized: "新建日程"), systemImage: "plus")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help(String(localized: "新建日程"))
        }
        .padding(.horizontal, 24).padding(.vertical, 13)
    }

    private var periodTitle: String {
        switch mode {
        case .day:
            return "\(selectedDay.formatted(.dateTime.month(.wide).day())) \(selectedDay.formatted(.dateTime.weekday(.wide)))"
        case .week:
            let days = CalendarLayout.weekDays(containing: selectedDay, calendar: calendar)
            guard let first = days.first, let last = days.last else { return "" }
            if calendar.isDate(first, equalTo: last, toGranularity: .month) {
                return "\(first.formatted(.dateTime.month(.wide).day())) – \(last.formatted(.dateTime.day()))"
            }
            return "\(first.formatted(.dateTime.month(.wide).day())) – \(last.formatted(.dateTime.month(.wide).day()))"
        case .month:
            return selectedDay.formatted(.dateTime.year().month(.wide))
        }
    }

    private var previousLabel: String {
        switch mode {
        case .day: String(localized: "上一天")
        case .week: String(localized: "上一周")
        case .month: String(localized: "上个月")
        }
    }

    private var nextLabel: String {
        switch mode {
        case .day: String(localized: "下一天")
        case .week: String(localized: "下一周")
        case .month: String(localized: "下个月")
        }
    }

    private func step(_ value: Int) {
        let component: Calendar.Component
        switch mode {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        guard let next = calendar.date(byAdding: component, value: value, to: selectedDay) else { return }
        selectedDay = calendar.startOfDay(for: next)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(String(localized: "重试")) { Task { await model.refreshCalendar(force: true) } }
                .controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct CalendarMonthRail: View {
    @Binding var selectedDay: Date
    let events: [CalendarEvent]
    let onSelectEvent: (CalendarEvent) -> Void
    @Environment(\.calendar) private var calendar

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    private var weeks: [[Date]] {
        CalendarLayout.monthGrid(for: selectedDay, calendar: calendar)
    }

    private var dayEvents: [CalendarEvent] {
        CalendarLayout.events(on: selectedDay, in: events, calendar: calendar)
    }

    private var kindsByDay: [Date: [CalendarEventKind]] {
        var result: [Date: [CalendarEventKind]] = [:]
        for event in events {
            for day in CalendarLayout.daysCovered(by: event, calendar: calendar) {
                result[day, default: []].append(event.kind)
            }
        }
        return result
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            monthHeader
            HStack(spacing: 2) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(weeks.joined()), id: \.self) { day in
                    dayCell(day)
                }
            }
            Divider()
            selectedDayHeader
            if dayEvents.isEmpty {
                Text(String(localized: "没有日程"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(dayEvents) { event in
                            eventRow(event)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(18)
    }

    private var monthHeader: some View {
        HStack(spacing: 4) {
            Text(selectedDay, format: .dateTime.year().month(.wide))
                .font(.title3.weight(.semibold))
            Spacer()
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).accessibilityLabel(String(localized: "上个月"))
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).accessibilityLabel(String(localized: "下个月"))
        }
    }

    private var selectedDayHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(selectedDay, format: .dateTime.month(.wide).day().weekday(.abbreviated))
                .font(.callout.weight(.semibold))
            Spacer()
            Text(String(localized: "\(dayEvents.count) 项"))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: selectedDay, toGranularity: .month)
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let today = calendar.isDateInToday(day)
        let kinds = Array((kindsByDay[day] ?? []).prefix(3))
        return Button { selectedDay = calendar.startOfDay(for: day) } label: {
            VStack(spacing: 1) {
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.callout.weight(selected || today ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white : today ? Color.accentColor : inMonth ? Color.primary : Color.secondary.opacity(0.45))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(selected ? Color.accentColor : Color.clear))
                    .overlay(Circle().strokeBorder(today && !selected ? Color.accentColor : Color.clear, lineWidth: 1))
                HStack(spacing: 2) {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                        Circle().fill(kind.tint).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(day, count: kinds.count, today: today))
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        Button { onSelectEvent(event) } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(event.isAllDay ? String(localized: "全天") : event.start.formatted(date: .omitted, time: .shortened))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if !event.isAllDay {
                        Text(event.end.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 48, alignment: .trailing)
                Capsule().fill(event.kind.tint).frame(width: 3, height: 28)
                Text(event.title).font(.callout).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if event.origin == .memory {
                    Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(event.title)
        .accessibilityLabel(String(localized: "\(event.title)，\(event.kind.title)"))
    }

    private func shiftMonth(_ value: Int) {
        guard let next = calendar.date(byAdding: .month, value: value, to: selectedDay) else { return }
        selectedDay = calendar.startOfDay(for: next)
    }

    private func accessibilityLabel(_ day: Date, count: Int, today: Bool) -> String {
        let prefix = day.formatted(date: .long, time: .omitted)
        let suffix = count == 0 ? String(localized: "没有日程") : String(localized: "\(count) 项日程")
        return today ? String(localized: "\(prefix)，今天，\(suffix)") : "\(prefix)，\(suffix)"
    }
}
