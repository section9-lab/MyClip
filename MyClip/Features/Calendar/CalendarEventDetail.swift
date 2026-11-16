import SwiftUI
import MyClipCore

struct CalendarEventDetail: View {
    @ObservedObject var model: MyClipModel
    let eventID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @State private var editing = false
    @State private var confirmingRemoval = false

    private var event: CalendarEvent? { model.calendarEvents.first { $0.id == eventID } }

    var body: some View {
        Group {
            if let event {
                content(event)
            } else {
                VStack(spacing: 14) {
                    Text(String(localized: "这条日程已被移除")).font(.title3.weight(.medium))
                    Text(String(localized: "它不会再出现在日历中。")).font(.callout).foregroundStyle(.secondary)
                    Button(String(localized: "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .frame(width: 420, height: 220)
            }
        }
    }

    private func content(_ event: CalendarEvent) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: event.kind.symbol).foregroundStyle(event.kind.tint)
                        Text(event.title).font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Text(timeText(event)).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(String(localized: "关闭详情"), systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.bordered).keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailRows(event)
                    if !event.notes.isEmpty {
                        section(String(localized: "备注")) {
                            Text(event.notes).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !event.evidence.isEmpty { evidenceSection(event) }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                if event.memoryID != nil {
                    Button(String(localized: "在 Memory 中显示"), systemImage: "doc.text") { openMemory(event) }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(String(localized: "移除日程"), role: .destructive) {
                    confirmingRemoval = true
                }
                .buttonStyle(.bordered)
                Button(String(localized: "编辑")) { editing = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 660, height: 540)
        .confirmationDialog(String(localized: "移除这条日程？"), isPresented: $confirmingRemoval) {
            Button(String(localized: "移除"), role: .destructive) {
                model.dismissCalendarEvent(event.id)
                dismiss()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "移除后不会再出现在日历中；AI 也不会自动加回来。"))
        }
        .sheet(isPresented: $editing) {
            CalendarEventEditor(model: model, event: event, day: event.start) { _ in }
        }
    }

    private func detailRows(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(timeText(event), systemImage: "clock")
            if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse") }
            Label(event.projectTitle, systemImage: "folder")
            Label(event.kind.title, systemImage: event.kind.symbol)
            if event.origin == .memory {
                Label {
                    Text(event.edited
                         ? String(localized: "来自 AI 整理的 Memory · 已手动调整")
                         : String(localized: "来自 AI 整理的 Memory"))
                } icon: { Image(systemName: "sparkles") }
            } else {
                Label(String(localized: "手动创建"), systemImage: "person")
            }
        }
        .font(.callout)
    }

    private func evidenceSection(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "原文依据")).font(.headline)
            Text(event.evidence)
                .font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
            if let path = event.memoryPath {
                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func openMemory(_ event: CalendarEvent) {
        guard let id = event.memoryID else { return }
        model.search = ""
        model.selectedEntry = id
        model.page = .memory
        dismiss()
    }

    private func timeText(_ event: CalendarEvent) -> String {
        if event.isAllDay {
            let endInclusive = event.end.addingTimeInterval(-1)
            if calendar.isDate(event.start, inSameDayAs: endInclusive) {
                return String(localized: "\(event.start.formatted(date: .long, time: .omitted)) · 全天")
            }
            return "\(event.start.formatted(date: .long, time: .omitted)) – \(endInclusive.formatted(date: .long, time: .omitted)) · \(String(localized: "全天"))"
        }
        if calendar.isDate(event.start, inSameDayAs: event.end) {
            return "\(event.start.formatted(date: .long, time: .omitted)) \(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(event.start.formatted(date: .long, time: .shortened)) – \(event.end.formatted(date: .long, time: .shortened))"
    }
}

struct CalendarEventEditor: View {
    @ObservedObject var model: MyClipModel
    let event: CalendarEvent?
    let day: Date
    let onSave: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @State private var title: String
    @State private var allDay: Bool
    @State private var start: Date
    /// All-day: the inclusive last day. Timed: the actual end.
    @State private var end: Date
    @State private var kind: CalendarEventKind
    @State private var project: String
    @State private var location: String
    @State private var notes: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(model: MyClipModel, event: CalendarEvent?, day: Date, onSave: @escaping (UUID) -> Void) {
        self.model = model
        self.event = event
        self.day = day
        self.onSave = onSave
        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        let initialStart = event?.start ?? defaultStart
        let initialEnd = event?.end ?? initialStart.addingTimeInterval(3_600)
        _title = State(initialValue: event?.title ?? "")
        _allDay = State(initialValue: event?.isAllDay ?? false)
        _start = State(initialValue: event?.isAllDay == true ? calendar.startOfDay(for: initialStart) : initialStart)
        _end = State(initialValue: event?.isAllDay == true
                     ? calendar.startOfDay(for: initialEnd.addingTimeInterval(-1))
                     : initialEnd)
        _kind = State(initialValue: event?.kind ?? .other)
        _project = State(initialValue: event?.project ?? "")
        _location = State(initialValue: event?.location ?? "")
        _notes = State(initialValue: event?.notes ?? "")
    }

    private var components: DatePickerComponents { allDay ? .date : [.date, .hourAndMinute] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(event == nil ? String(localized: "新建日程") : String(localized: "编辑日程"))
                .font(.title2.bold())
            if event?.origin == .memory {
                Text(String(localized: "修改后仍保留 Memory 来源，但后续整理不会再覆盖这条日程。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(String(localized: "日程名称"), text: $title)
                .textFieldStyle(.roundedBorder).focused($titleFocused).disabled(saving)

            Toggle(String(localized: "全天"), isOn: $allDay).toggleStyle(.switch).controlSize(.small)

            HStack(spacing: 12) {
                Text(String(localized: "开始")).frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                DatePicker("", selection: $start, displayedComponents: components)
                    .labelsHidden().datePickerStyle(.field)
                Text(allDay ? String(localized: "结束（含）") : String(localized: "结束"))
                    .frame(width: 58, alignment: .trailing).foregroundStyle(.secondary)
                DatePicker("", selection: $end, displayedComponents: components)
                    .labelsHidden().datePickerStyle(.field)
            }
            HStack(spacing: 12) {
                Text(String(localized: "类型")).frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                Picker("", selection: $kind) {
                    ForEach(CalendarEventKind.allCases, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }.labelsHidden().pickerStyle(.menu).frame(width: 130)
                Spacer()
            }
            HStack(spacing: 12) {
                Text(String(localized: "项目")).frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                TextField(String(localized: "项目（可选）"), text: $project)
                    .textFieldStyle(.roundedBorder).disabled(saving)
            }
            HStack(spacing: 12) {
                Text(String(localized: "地点")).frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                TextField(String(localized: "地点（可选）"), text: $location)
                    .textFieldStyle(.roundedBorder).disabled(saving)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "备注")).font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(height: 64)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
                    .disabled(saving)
                    .accessibilityLabel(String(localized: "备注"))
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(String(localized: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? String(localized: "正在保存…") : event == nil ? String(localized: "创建日程") : String(localized: "保存修改")) {
                    save()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(saving)
        .onAppear { titleFocused = true }
        .onChange(of: allDay) { value in normalizeAllDay(value) }
        .onChange(of: start) { value in
            if end < value { end = value.addingTimeInterval(allDay ? 86_400 : 3_600) }
        }
    }

    private func normalizeAllDay(_ value: Bool) {
        if value {
            start = calendar.startOfDay(for: start)
            end = max(calendar.startOfDay(for: end), start)
        } else {
            start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start
            end = start.addingTimeInterval(3_600)
        }
    }

    private func save() {
        error = nil
        let endDate: Date
        if allDay {
            let inclusive = calendar.startOfDay(for: end)
            guard inclusive >= calendar.startOfDay(for: start) else {
                error = String(localized: "结束日期不能早于开始日期。")
                return
            }
            endDate = calendar.date(byAdding: .day, value: 1, to: inclusive) ?? inclusive.addingTimeInterval(86_400)
        } else {
            guard end > start else {
                error = String(localized: "结束时间必须晚于开始时间。")
                return
            }
            endDate = end
        }
        let draft = CalendarEventDraft(title: title, notes: notes, location: location, project: project,
                                       kind: kind, start: start, end: endDate, isAllDay: allDay)
        saving = true
        Task {
            do {
                let id = try await model.saveCalendarEvent(id: event?.id, draft: draft)
                onSave(id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
