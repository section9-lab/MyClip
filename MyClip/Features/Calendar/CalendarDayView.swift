import SwiftUI
import MyClipCore

struct CalendarDayView: View {
    let day: Date
    let events: [CalendarEvent]
    let onSelect: (CalendarEvent) -> Void
    let onCreate: (Date) -> Void

    @Environment(\.calendar) private var calendar
    @Environment(\.colorScheme) private var colorScheme
    private let hourHeight: CGFloat = 52
    private let labelWidth: CGFloat = 54

    private var dayEvents: [CalendarEvent] {
        CalendarLayout.events(on: day, in: events, calendar: calendar)
    }

    private var band: [CalendarEvent] {
        CalendarLayout.bandEvents(on: day, in: events, calendar: calendar)
    }

    private var timed: [CalendarEvent] {
        dayEvents.filter { !CalendarLayout.isBand($0, calendar: calendar) }
    }

    private var slots: [CalendarLayout.EventSlot] {
        CalendarLayout.slots(on: day, in: timed, calendar: calendar)
    }

    private var hourRange: Range<Int> {
        CalendarLayout.hourRange(for: events, on: [day], calendar: calendar)
    }

    private var contentHeight: CGFloat {
        CGFloat(hourRange.count) * hourHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            if !band.isEmpty { bandSection }
            if timed.isEmpty {
                if band.isEmpty {
                    emptyState
                } else {
                    Text(String(localized: "今天没有定时日程"))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        timeline
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .padding(.bottom, 24)
                    }
                    .task(id: "\(day.timeIntervalSince1970)-\(slots.count)") {
                        // Scroll after the hour rows exist; onAppear alone runs before the first layout.
                        try? await Task.sleep(for: .milliseconds(160))
                        scrollToRelevantHour(proxy)
                    }
                }
            }
        }
    }

    private var bandSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(localized: "全天")).font(.caption).foregroundStyle(.secondary)
            ForEach(band) { event in
                Button { onSelect(event) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: event.kind.symbol)
                            .font(.callout).foregroundStyle(event.kind.tint).frame(width: 16)
                        Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        if event.origin == .memory {
                            Image(systemName: "sparkles").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(bandRange(event)).font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(event.kind.tint.opacity(colorScheme == .dark ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(event.title)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(event))
                .accessibilityHint(String(localized: "打开日程详情"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var timeline: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - labelWidth)
            ZStack(alignment: .topLeading) {
                hourGrid
                ForEach(slots) { slot in
                    eventBlock(slot, width: width)
                }
                currentTimeLine(width: width)
            }
            .frame(height: contentHeight, alignment: .topLeading)
        }
        .frame(height: contentHeight)
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(hourRange, id: \.self) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text(hourLabel(hour))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: labelWidth - 8, alignment: .trailing)
                        .offset(y: 4)
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.35))
                        .frame(height: 1)
                        .offset(y: 8)
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hour)
                .accessibilityHidden(true)
            }
        }
    }

    private func eventBlock(_ slot: CalendarLayout.EventSlot, width: CGFloat) -> some View {
        let start = max(slot.event.start, dayStart)
        let end = min(slot.event.end, dayEnd)
        let y = start.timeIntervalSince(dayStart) / 3600 * hourHeight - CGFloat(hourRange.lowerBound) * hourHeight
        let height = max(24, end.timeIntervalSince(start) / 3600 * hourHeight - 2)
        let gap: CGFloat = 6
        let laneWidth = max(0, (width - gap * CGFloat(slot.laneCount - 1)) / CGFloat(slot.laneCount))
        return Button { onSelect(slot.event) } label: {
            CalendarEventCard(event: slot.event, compact: height < 40)
                .frame(width: laneWidth, height: height, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .offset(x: labelWidth + CGFloat(slot.lane) * (laneWidth + gap), y: y)
        .help(slot.event.title)
    }

    @ViewBuilder private func currentTimeLine(width: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if calendar.isDate(day, inSameDayAs: context.date) {
                let y = context.date.timeIntervalSince(dayStart) / 3600 * hourHeight
                        - CGFloat(hourRange.lowerBound) * hourHeight
                if y >= 0, y <= contentHeight {
                    HStack(spacing: 0) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                            .offset(x: labelWidth - 9)
                        Rectangle().fill(Color.red).frame(width: max(0, width - labelWidth + 6), height: 1)
                    }
                    .offset(y: y)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(calendar.isDateInToday(day) ? String(localized: "今天没有日程") : String(localized: "这一天没有日程"))
                .font(.title3.weight(.medium))
            Text(String(localized: "AI 整理 Memory 时会自动加入会议和出行；也可以手动新建。"))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(String(localized: "新建日程"), systemImage: "plus") { onCreate(day) }
                .buttonStyle(.bordered).controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var dayStart: Date { calendar.startOfDay(for: day) }
    private var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart }

    private func hourLabel(_ hour: Int) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private func bandRange(_ event: CalendarEvent) -> String {
        if calendar.isDate(event.start, inSameDayAs: event.end.addingTimeInterval(-1)) { return String(localized: "全天") }
        return "\(event.start.formatted(.dateTime.month(.defaultDigits).day()))–\(event.end.addingTimeInterval(-1).formatted(.dateTime.month(.defaultDigits).day()))"
    }

    private func accessibilityLabel(_ event: CalendarEvent) -> String {
        let time = event.isAllDay ? String(localized: "全天") : bandRange(event)
        let source = event.origin == .memory ? String(localized: "，来自 AI 整理的 Memory") : ""
        return String(localized: "\(event.title)，\(event.kind.title)，\(time)\(source)")
    }

    private func scrollToRelevantHour(_ proxy: ScrollViewProxy) {
        if calendar.isDateInToday(day) {
            let hour = min(max(calendar.component(.hour, from: Date()), hourRange.lowerBound), hourRange.upperBound - 1)
            proxy.scrollTo(hour, anchor: .center)
        } else {
            proxy.scrollTo(hourRange.lowerBound, anchor: .top)
        }
    }
}

struct CalendarEventCard: View {
    let event: CalendarEvent
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(compact ? 1 : 2)
                if !compact {
                    Text(timeText).font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, compact ? 3 : 5)
            Spacer(minLength: 0)
            if event.origin == .memory && !compact {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(.secondary).padding(.trailing, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .fill(event.kind.tint.opacity(colorScheme == .dark ? 0.14 : 0.07))
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.kind.tint)
                .frame(width: 3).padding(.vertical, 5).padding(.leading, 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(String(localized: "打开日程详情"))
    }

    private var timeText: String {
        "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))"
    }

    private var accessibilityLabel: String {
        let source = event.origin == .memory ? String(localized: "，来自 AI 整理的 Memory") : ""
        return String(localized: "\(event.title)，\(event.kind.title)，\(timeText)\(source)")
    }
}
