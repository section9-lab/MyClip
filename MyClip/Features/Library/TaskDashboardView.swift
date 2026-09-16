import SwiftUI
import Charts
import MyClipCore

private extension WorkTaskStatus {
    var tint: Color {
        switch self {
        case .candidate: .orange
        case .todo, .ignored: .secondary
        case .doing: .blue
        case .done: .green
        }
    }
}

private struct TaskEditRequest: Identifiable {
    let id = UUID()
    let task: WorkTask?
}

struct TaskDashboardView: View {
    @Bindable var model: MyClipModel
    @State private var selectedID: UUID?
    @State private var editing: TaskEditRequest?
    private let columns: [WorkTaskStatus] = [.todo, .doing, .done]

    private var tasks: [WorkTask] {
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.workTasks.filter { query.isEmpty || ($0.title + " " + $0.project + " " + $0.evidence.map(\.body).joined(separator: " ")).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ViewThatFits(in: .horizontal) {
                        HStack { heading; Spacer(minLength: 24); actions }
                        VStack(alignment: .leading, spacing: 12) { heading; actions }
                    }
                    if let message = model.taskDiscoveryMessage {
                        HStack(alignment: .top) {
                            Text(message).font(.callout).foregroundStyle(model.taskDiscoveryFailed ? Color.orange : Color.secondary).textSelection(.enabled)
                            Spacer()
                            if !model.discoveringTasks {
                                Button("关闭提示", systemImage: "xmark") { model.taskDiscoveryMessage = nil }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                    }
                    if tasks.filter({ $0.status != .ignored }).isEmpty {
                        ContentUnavailableView(model.search.isEmpty ? "从工作记录中发现任务" : "没有匹配的任务", systemImage: "checklist",
                            description: Text(model.search.isEmpty ? "点击“从 Memory 发现”，或新建一项任务。之后整理截图时，也会自动补充任务线索。" : "尝试搜索任务名称、项目或来源依据。"))
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    } else {
                        candidates
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("当前任务").font(.headline)
                                Spacer()
                                Text("\(tasks.filter { $0.status.isConfirmed }.count) 项已确认").font(.caption).foregroundStyle(.secondary)
                            }
                            if geometry.size.width >= 680 {
                                HStack(alignment: .top, spacing: 12) { ForEach(columns, id: \.self) { column($0) } }
                            } else {
                                VStack(spacing: 12) { ForEach(columns, id: \.self) { column($0) } }
                            }
                        }
                    }
                    if let task = model.workTasks.first(where: { $0.id == selectedID }) {
                        TaskInspectorView(model: model, task: task, onEdit: { editing = TaskEditRequest(task: task) }, onClose: { selectedID = nil }).id(task.id)
                    }
                    TaskAnalysisView(model: model, stacked: geometry.size.width < 740)
                    let ignored = tasks.filter { $0.status == .ignored }
                    if !ignored.isEmpty {
                        DisclosureGroup("已忽略 · \(ignored.count)") {
                            ForEach(ignored) { task in
                                HStack {
                                    Button(task.title) { selectedID = task.id }.buttonStyle(.plain)
                                    Spacer()
                                    Button("恢复到待确认") { model.setTaskStatus(task.id, .candidate) }.buttonStyle(.borderless)
                                }.padding(.vertical, 6)
                            }
                        }.font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(28).frame(maxWidth: 1200).frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .sheet(item: $editing) { request in
            TaskEditorView(model: model, task: request.task) { selectedID = $0 }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("任务看板").font(.largeTitle.bold())
            Text(model.preview ? "界面预览 · 示例任务" : Date.now.formatted(.dateTime.month().day().weekday(.wide)))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if model.discoveringTasks {
                ProgressView().controlSize(.small)
                Button("取消识别") { model.cancelTaskDiscovery() }
            } else {
                Button("从 Memory 发现", systemImage: "sparkle.magnifyingglass") { model.discoverTasks() }
                    .disabled(model.preview || model.currentJob != nil || model.state(model.preferences.agent).busy)
                    .help("使用所选 Agent 分析最近 200 篇 Memory；新截图整理时也会补充任务线索。")
            }
            Button("新建任务", systemImage: "plus") { editing = TaskEditRequest(task: nil) }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var candidates: some View {
        let candidates = tasks.filter { $0.status == .candidate }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("待确认").font(.headline)
                Text(candidates.count.formatted()).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("来自截图与 Memory 的线索").font(.caption).foregroundStyle(.secondary)
            }
            if candidates.isEmpty { Text("没有待确认的任务").font(.callout).foregroundStyle(.secondary) }
            ForEach(candidates) { task in
                HStack(spacing: 16) {
                    Button { selectedID = task.id } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text("\(task.projectTitle) · \(task.evidence.count) 条依据" + (task.suggestedStatus == .done ? " · 可能已完成" : task.suggestedStatus == .doing ? " · 可能正在进行" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button("加入待办") { model.setTaskStatus(task.id, .todo) }.tint(.blue)
                    Button("忽略") { model.setTaskStatus(task.id, .ignored) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }.padding(.vertical, 8).disabled(model.updatingTaskIDs.contains(task.id))
                Divider()
            }
        }
    }

    private func column(_ status: WorkTaskStatus) -> some View {
        let items = tasks.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(status.tint).frame(width: 7, height: 7)
                Text(status.title).font(.headline)
                Spacer()
                Text(items.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }.padding(.horizontal, 2)
            if items.isEmpty {
                Text("暂无\(status.title)任务").font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
            }
            ForEach(items) { task in
                Button { selectedID = task.id } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        if !task.waitingReason.isEmpty && task.status != .done {
                            Label("等待：\(task.waitingReason)", systemImage: "clock").font(.caption).foregroundStyle(.orange)
                        }
                        if let suggestion = task.suggestedStatus, suggestion != task.status {
                            Label("新线索：可能\(suggestion.title)", systemImage: "sparkle").font(.caption).foregroundStyle(.orange)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(task.projectTitle).lineLimit(2)
                            Spacer(minLength: 6)
                            if let date = task.completedAt { Text(date, format: .dateTime.month(.defaultDigits).day()) }
                            else { Text(task.evidence.isEmpty ? "手动创建" : "\(task.evidence.count) 条依据") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selectedID == task.id ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.35)))
                }
                .buttonStyle(.plain).disabled(model.updatingTaskIDs.contains(task.id))
                .accessibilityLabel("\(task.title)，\(status.title)，\(task.projectTitle)")
                .draggable(task.id.uuidString)
                .contextMenu {
                    Button("编辑任务") { editing = TaskEditRequest(task: task) }
                    ForEach(columns.filter { $0 != status }, id: \.self) { next in
                        Button("设为\(next.title)") { model.setTaskStatus(task.id, next) }
                    }
                    Divider()
                    Button("移出看板") { model.setTaskStatus(task.id, .ignored) }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { values, _ in
            let ids = values.compactMap(UUID.init(uuidString:)).filter { id in model.workTasks.contains { $0.id == id && $0.status.isConfirmed } }
            for id in ids { model.setTaskStatus(id, status) }
            return !ids.isEmpty
        }
    }
}

private struct TaskAnalysisView: View {
    @Bindable var model: MyClipModel
    let stacked: Bool
    private var confirmed: [WorkTask] { model.workTasks.filter { $0.status.isConfirmed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            HStack {
                Text("任务分析").font(.headline)
                Spacer()
                Picker("图表范围", selection: $model.analyticsDays) {
                    Text("近 7 天").tag(7); Text("近 30 天").tag(30); Text("近 90 天").tag(90); Text("全部").tag(0)
                }.frame(width: 175)
            }
            if confirmed.isEmpty && model.taskStatistics.added == 0 {
                Text("确认或创建任务后，这里会显示进展趋势和项目完成情况。").foregroundStyle(.secondary).padding(.vertical, 12)
            } else if stacked {
                VStack(alignment: .leading, spacing: 24) { trend; projects }
            } else {
                HStack(alignment: .top, spacing: 32) { trend.frame(maxWidth: .infinity); projects.frame(maxWidth: .infinity) }
            }
            Text("统计全部确认过的任务；待确认线索不计入。任务数量不代表工时或工作难度。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("新增与完成").font(.subheadline.weight(.semibold))
                Spacer()
                Text("新增 \(model.taskStatistics.added) · 完成 \(model.taskStatistics.completed)").font(.caption).foregroundStyle(.secondary)
            }
            Chart(model.taskStatistics.days) { day in
                BarMark(x: .value("日期", day.date, unit: .day), y: .value("任务", day.added))
                    .foregroundStyle(by: .value("类型", "新增")).position(by: .value("类型", "新增"))
                    .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted))，新增 \(day.added) 项")
                BarMark(x: .value("日期", day.date, unit: .day), y: .value("任务", day.completed))
                    .foregroundStyle(by: .value("类型", "完成")).position(by: .value("类型", "完成"))
                    .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted))，完成 \(day.completed) 项")
            }
            .chartForegroundStyleScale(["新增": Color.blue, "完成": Color.green])
            .chartYAxisLabel("项").chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
            .frame(height: 190)
            let change = model.taskStatistics.backlogChange
            Text("当前未完成 \(model.taskStatistics.unfinished) 项 · 所选期间" + (change == 0 ? "无净变化" : "净\(change > 0 ? "增加" : "减少") \(abs(change)) 项"))
                .font(.caption).foregroundStyle(.secondary)
            Text("完成按每日任务去重；重新打开保留完成历史。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var projects: some View {
        let groups = Dictionary(grouping: confirmed, by: \.projectTitle)
        return VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("项目进度").font(.subheadline.weight(.semibold))
                Spacer()
                Text("当前已完成 / 全部").font(.caption).foregroundStyle(.secondary)
            }
            if groups.isEmpty { Text("暂无进行中的项目记录").foregroundStyle(.secondary) }
            ForEach(groups.keys.sorted(), id: \.self) { project in
                let items = groups[project] ?? []
                let segments = [WorkTaskStatus.done, .doing, .todo].filter { status in items.contains { $0.status == status } }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(project)
                        Spacer()
                        Text("\(items.filter { $0.status == .done }.count) / \(items.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            ForEach(segments, id: \.self) { status in
                                Rectangle().fill(status.tint).frame(width: max(0, geometry.size.width - CGFloat(max(0, segments.count - 1)) * 2) * CGFloat(items.filter { $0.status == status }.count) / CGFloat(max(1, items.count)))
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 3))
                    }.frame(height: 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(segments.map { status in "\(status.title) \(items.filter { $0.status == status }.count) 项" }.joined(separator: "，"))
                }
            }
            HStack(spacing: 12) {
                ForEach([WorkTaskStatus.done, .doing, .todo], id: \.self) { status in
                    Label { Text(status.title) } icon: { Circle().fill(status.tint).frame(width: 6, height: 6) }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TaskInspectorView: View {
    let model: MyClipModel
    let task: WorkTask
    let onEdit: () -> Void
    let onClose: () -> Void
    @State private var events: [WorkTaskEvent] = []
    @State private var sources: [ClipCapture] = []
    @State private var source: ClipCapture?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text("\(task.projectTitle) · \(task.status.title)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("编辑", action: onEdit).buttonStyle(.borderless)
                Button("收起", action: onClose).buttonStyle(.borderless)
            }
            HStack {
                Picker("任务状态", selection: Binding(get: { task.status }, set: { model.setTaskStatus(task.id, $0) })) {
                    ForEach(WorkTaskStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 210).disabled(model.updatingTaskIDs.contains(task.id))
                Spacer()
            }
            if !task.waitingReason.isEmpty && task.status != .done {
                Label("等待：\(task.waitingReason)", systemImage: "clock").font(.callout).foregroundStyle(.orange)
            }
            if let suggestion = task.suggestedStatus, suggestion != task.status {
                HStack {
                    Label("AI 建议：\(suggestion.title)", systemImage: "sparkle").foregroundStyle(.orange)
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
                        Text(event.from.map { "\($0.title) → \(event.to.title)" } ?? "创建 · \(event.to.title)")
                        Spacer()
                        Text(event.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                    }.font(.callout).padding(.vertical, 4)
                }
            }
        }
        .task(id: task.updatedAt) {
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

private struct TaskEditorView: View {
    let model: MyClipModel
    let task: WorkTask?
    let onSave: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var project: String
    @State private var waitingReason: String
    @State private var saving = false
    @State private var error: String?

    init(model: MyClipModel, task: WorkTask?, onSave: @escaping (UUID) -> Void) {
        self.model = model; self.task = task; self.onSave = onSave
        _title = State(initialValue: task?.title ?? "")
        _project = State(initialValue: task?.project ?? "")
        _waitingReason = State(initialValue: task?.waitingReason ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(task == nil ? "新建任务" : "编辑任务").font(.title2.bold())
            TextField("任务名称", text: $title).textFieldStyle(.roundedBorder)
            TextField("项目（可选）", text: $project).textFieldStyle(.roundedBorder)
            TextField("等待事项，例如客户反馈（可选）", text: $waitingReason).textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
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
    }
}
