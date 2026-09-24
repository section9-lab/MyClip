import SwiftUI
import MyClipCore

struct TaskDetailView: View {
    @ObservedObject var model: MyClipModel
    let taskID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var events: [WorkTaskEvent] = []
    @State private var sources: [ClipCapture] = []
    @State private var source: ClipCapture?

    var body: some View {
        if let task = model.workTasks.first(where: { $0.id == taskID }) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text("\(task.projectTitle) · \(task.status.title)").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("编辑") { editing = true }.buttonStyle(.borderless)
                    Button(String(localized: "关闭详情"), systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                }.padding(24)
                Divider()
                ScrollView { details(task).padding(24).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .frame(width: 680, height: 520)
            .sheet(isPresented: $editing) {
                TaskEditorView(model: model, task: task) { _ in }
            }
        }
    }

    private func details(_ task: WorkTask) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("任务状态", selection: Binding(get: { task.status }, set: { model.setTaskStatus(task.id, $0) })) {
                    ForEach(WorkTaskStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 210).disabled(model.updatingTaskIDs.contains(task.id))
                Spacer()
            }
            if !task.waitingReason.isEmpty && task.status != .done {
                Label(String(localized: "等待：\(task.waitingReason)"), systemImage: "clock").font(.callout).foregroundStyle(.orange)
            }
            if let suggestion = task.suggestedStatus, suggestion != task.status {
                HStack {
                    Label(String(localized: "AI 建议调整为\(suggestion.title)"), systemImage: "sparkle").foregroundStyle(.orange)
                    Button("确认\(suggestion.title)") { model.setTaskStatus(task.id, suggestion) }
                    Button("保留当前状态") { model.setTaskStatus(task.id, task.status) }.buttonStyle(.borderless)
                }.font(.callout)
            }
            if let first = task.evidence.first {
                Text("来源依据").font(.headline)
                evidence(first)
                if task.evidence.count > 1 {
                    DisclosureGroup("更多依据 · \(task.evidence.count - 1)") {
                        ForEach(task.evidence.dropFirst()) { evidence($0).padding(.vertical, 8) }
                    }
                }
            } else { Text("手动创建的任务").font(.callout).foregroundStyle(.secondary) }
            DisclosureGroup("状态历史 · \(events.count)") {
                ForEach(events.reversed()) { event in
                    HStack {
                        Text("\(event.actor.title) · " + (event.from.map { "\($0.title) → \(event.to.title)" } ?? String(localized: "创建 · \(event.to.title)")))
                        Spacer()
                        Text(event.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                    }.font(.callout).padding(.vertical, 4)
                }
            }
        }
        .task(id: "\(task.updatedAt.timeIntervalSince1970)-\(task.evidence.count)") {
            do {
                events = try await model.store.workTaskEvents(task.id)
                sources = try await model.store.availableCaptures(ids: Array(Set(task.evidence.flatMap(\.sourceIDs))))
            } catch { model.notice = error.localizedDescription }
        }
        .sheet(item: $source) { CaptureDetailView(model: model, capture: $0) }
    }

    private func evidence(_ item: WorkTaskEvidence) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(item.body).textSelection(.enabled)
            ForEach(item.memoryIDs, id: \.self) { id in
                if let memory = model.library.entries.first(where: { $0.id == id }) {
                    Button(memory.title, systemImage: "doc.text") {
                        dismiss()
                        model.search = ""; model.selectedEntry = id; model.page = .memory
                    }.buttonStyle(.borderless)
                } else { Text("来源 Memory 已移除，保留原依据。").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(item.sourceIDs, id: \.self) { id in
                if let capture = sources.first(where: { $0.id == id }) {
                    Button { source = capture } label: {
                        Label("\(capture.appName) · \(capture.date.formatted(date: .abbreviated, time: .shortened))", systemImage: "photo")
                    }.buttonStyle(.borderless)
                } else { Text("来源截图记录不可用，保留原依据。").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct TaskEditorView: View {
    @ObservedObject var model: MyClipModel
    let task: WorkTask?
    let onSave: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var project: String
    @State private var waitingReason: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(model: MyClipModel, task: WorkTask?, onSave: @escaping (UUID) -> Void) {
        self.model = model; self.task = task; self.onSave = onSave
        _title = State(initialValue: task?.title ?? "")
        _project = State(initialValue: task?.project ?? "")
        _waitingReason = State(initialValue: task?.waitingReason ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(task == nil ? String(localized: "新建待办") : String(localized: "编辑任务")).font(.title2.bold())
            if task == nil { Text("先记下要做的事，AI 会根据后续工作记录更新进展。").font(.callout).foregroundStyle(.secondary) }
            TextField("待办名称", text: $title).textFieldStyle(.roundedBorder).focused($titleFocused).disabled(saving)
            TextField("项目（可选）", text: $project).textFieldStyle(.roundedBorder).disabled(saving)
            TextField("等待事项，例如客户反馈（可选）", text: $waitingReason).textFieldStyle(.roundedBorder).disabled(saving)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? String(localized: "正在保存…") : task == nil ? String(localized: "创建待办") : String(localized: "保存修改")) {
                    saving = true
                    Task {
                        do { let id = try await model.saveTask(id: task?.id, title: title, project: project, waitingReason: waitingReason); onSave(id); dismiss() }
                        catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(saving)
            .onAppear { titleFocused = true }
    }
}
