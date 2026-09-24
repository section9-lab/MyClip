import SwiftUI
import MyClipCore

extension WorkTaskStatus {
    var tint: Color {
        switch self {
        case .candidate: .orange
        case .todo, .ignored: .secondary
        case .doing: .orange
        case .done: .blue
        }
    }
}

private struct TaskEditRequest: Identifiable {
    let id = UUID()
    let task: WorkTask?
}

struct TaskDashboardView: View {
    @ObservedObject var model: MyClipModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: UUID?
    @State private var editing: TaskEditRequest?
    @State private var savedTaskID: UUID?
    @State private var showingCandidates = true
    @State private var candidatePage = 0
    @State private var expandedCandidateID: UUID?
    @State private var candidateStatuses: [UUID: WorkTaskStatus] = [:]
    @State private var showingDiscoveryDetails = false
    private let columns: [WorkTaskStatus] = [.todo, .doing, .done]
    private let taskCardHeight: CGFloat = 110
    private let taskCardSpacing: CGFloat = 8

    private var candidateTasks: [WorkTask] { tasks.filter { $0.status == .candidate } }
    private var lastCandidatePage: Int { max(0, (candidateTasks.count - 1) / 3) }
    private var visibleCandidatePage: Int { min(candidatePage, lastCandidatePage) }
    private var visibleTaskRows: Int { min(5, max(1, columns.map { status in tasks.filter { $0.status == status }.count }.max() ?? 0)) }

    private var tasks: [WorkTask] {
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.workTasks.filter { query.isEmpty || ($0.title + " " + $0.project + " " + $0.evidence.map(\.body).joined(separator: " ")).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 28) {
                    viewTab("Kanban", reports: false)
                    viewTab("Reports", reports: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24).frame(maxWidth: 1200).frame(maxWidth: .infinity)
                .background(alignment: .bottom) { Divider() }
                if model.showingTaskReports {
                    TaskReportsView(model: model) { selectedID = $0 }
                } else {
                    ScrollView {
                        board(width: geometry.size.width)
                            .padding(24).frame(maxWidth: 1200).frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: model.search) { _ in candidatePage = 0; expandedCandidateID = nil }
        .onChange(of: candidateTasks.map(\.id)) { ids in
            candidatePage = visibleCandidatePage
            if let expandedCandidateID, !ids.contains(expandedCandidateID) { self.expandedCandidateID = nil }
            candidateStatuses = candidateStatuses.filter { ids.contains($0.key) }
        }
        .onChange(of: model.taskDiscoveryMessage) { _ in showingDiscoveryDetails = false }
        .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
            if let selectedID { TaskDetailView(model: model, taskID: selectedID) }
        }
        .sheet(item: $editing, onDismiss: {
            if let savedTaskID { selectedID = savedTaskID; self.savedTaskID = nil }
        }) { request in
            TaskEditorView(model: model, task: request.task) { savedTaskID = $0 }
        }
    }

    private func board(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack { taskCount; Spacer(minLength: 20); actions }
                VStack(alignment: .leading, spacing: 12) { taskCount; actions }
            }
            if let message = model.taskDiscoveryMessage {
                discoveryNotice(message)
            }
            if tasks.filter({ $0.status != .ignored }).isEmpty {
                LibraryUnavailableView(model.search.isEmpty ? String(localized: "从一项待办开始") : String(localized: "没有匹配的任务"), systemImage: "checklist",
                    description: Text(model.search.isEmpty ? String(localized: "新建待办，或让 AI 从 Memory 发现工作。之后 AI 会根据截图与记忆更新进展。") : String(localized: "尝试搜索任务名称、项目或来源依据。")))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            if !candidateTasks.isEmpty {
                candidates
            }
            if let review = model.lastTaskReview {
                HStack(spacing: 8) {
                    Label(review.status == .ignored ? String(localized: "已忽略建议") : String(localized: "已加入「\(review.status.title)」"), systemImage: "checkmark")
                    Text(review.title).lineLimit(1).foregroundStyle(.secondary).help(review.title)
                    Spacer(minLength: 8)
                    Button("撤销") { model.undoTaskReview() }
                        .disabled(model.updatingTaskIDs.contains(review.taskID))
                    Button(String(localized: "关闭确认提示"), systemImage: "xmark") { model.lastTaskReview = nil }.labelStyle(.iconOnly)
                }
                .font(.caption).buttonStyle(.borderless)
                .padding(10).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
            if width >= 680 {
                HStack(alignment: .top, spacing: 12) { ForEach(columns, id: \.self) { column($0) } }
            } else {
                VStack(spacing: 12) { ForEach(columns, id: \.self) { column($0) } }
            }
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
        }
    }

    private func viewTab(_ title: String, reports: Bool) -> some View {
        let selected = model.showingTaskReports == reports
        return Button { model.showingTaskReports = reports } label: {
            Text(title).font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(height: 40).contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Color.accentColor : .clear).frame(height: 2)
                }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var taskCount: some View {
        Text("当前任务 · \(tasks.filter { $0.status.isConfirmed }.count) 项")
            .font(.callout).foregroundStyle(.secondary)
            .help("AI 跟进进展，可拖动卡片调整状态")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if model.discoveringTasks {
                ProgressView().controlSize(.small)
                Button("取消识别") { model.cancelTaskDiscovery() }
            } else {
                Button(String(localized: "AI 更新进展"), systemImage: "sparkles") { model.discoverTasks() }
                    .disabled(!model.canStartOrganization)
                    .help("从最近 200 篇 Memory 发现待办并更新已有任务；新截图整理时也会自动更新。")
            }
            Button(String(localized: "新建待办"), systemImage: "plus") { editing = TaskEditRequest(task: nil) }
                .buttonStyle(.borderedProminent).keyboardShortcut("n", modifiers: .command)
        }.controlSize(.small).fixedSize(horizontal: true, vertical: false)
    }

    private func discoveryNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: model.taskDiscoveryFailed ? "exclamationmark.circle" : "sparkles")
                    .foregroundStyle(model.taskDiscoveryFailed ? Color.orange : Color.secondary)
                Text(model.taskDiscoveryFailed ? (model.taskDiscoveryMemorySaved ? String(localized: "任务识别未完成，Memory 已保存") : String(localized: "任务识别未完成")) : message)
                    .foregroundStyle(.secondary)
                if model.taskDiscoveryFailed {
                    Button(showingDiscoveryDetails ? String(localized: "收起原因") : String(localized: "查看原因")) { showingDiscoveryDetails.toggle() }.buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
                if !model.discoveringTasks {
                    Button(String(localized: "关闭提示"), systemImage: "xmark") { model.taskDiscoveryMessage = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            if showingDiscoveryDetails {
                Text(message).textSelection(.enabled).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }.font(.caption)
    }

    private var candidates: some View {
        let start = visibleCandidatePage * 3
        let visible = Array(candidateTasks.dropFirst(start).prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { showingCandidates.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tray").foregroundStyle(.orange)
                        Text("待确认").font(.headline)
                        Text(candidateTasks.count.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                    }
                }.buttonStyle(.plain).accessibilityLabel(showingCandidates ? String(localized: "收起待确认任务") : String(localized: "展开待确认任务"))
                Text("AI 从近期活动中发现").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { showingCandidates.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(showingCandidates ? String(localized: "收起") : String(localized: "展开"))
                        Image(systemName: showingCandidates ? "chevron.up" : "chevron.down")
                    }.font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 16).padding(.vertical, 13)
            if showingCandidates {
                Divider()
                VStack(spacing: 0) {
                    ForEach(visible) { task in
                        candidateRow(task)
                        if task.id != visible.last?.id { Divider() }
                    }
                }.padding(.horizontal, 16)
                Divider()
                HStack(spacing: 8) {
                    Label(String(localized: "确认后，加入建议的看板列"), systemImage: "sparkles").lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(start + 1)–\(start + visible.count) / \(candidateTasks.count)").monospacedDigit()
                    if candidateTasks.count > 3 {
                        Button(String(localized: "上一页待确认任务"), systemImage: "chevron.left") {
                            candidatePage = visibleCandidatePage - 1; expandedCandidateID = nil
                        }.labelStyle(.iconOnly).disabled(visibleCandidatePage == 0)
                        Button(String(localized: "下一页待确认任务"), systemImage: "chevron.right") {
                            candidatePage = visibleCandidatePage + 1; expandedCandidateID = nil
                        }.labelStyle(.iconOnly).disabled(visibleCandidatePage == lastCandidatePage)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).buttonStyle(.borderless).controlSize(.small)
                .padding(.horizontal, 16).padding(.vertical, 9).background(.quaternary.opacity(0.15))
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45)))
    }

    private func candidateRow(_ task: WorkTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    candidateTitle(task).frame(minWidth: 220)
                    candidateControls(task)
                }
                VStack(alignment: .leading, spacing: 8) {
                    candidateTitle(task)
                    HStack { Spacer(); candidateControls(task) }
                }
            }.padding(.vertical, 11)
            if expandedCandidateID == task.id {
                VStack(alignment: .leading, spacing: 9) {
                    Text(task.title).font(.callout.weight(.medium)).textSelection(.enabled)
                    if let evidence = task.evidence.first {
                        Label(String(localized: "来源依据 · \(evidence.date.formatted(date: .abbreviated, time: .shortened))"), systemImage: "doc.text")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(evidence.body).font(.callout).textSelection(.enabled)
                    } else {
                        Text("暂无来源依据，可在详情中核对任务。").font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { candidateDetailButton(task); Spacer(minLength: 12); candidateStatusPicker(task) }
                        VStack(alignment: .leading, spacing: 8) {
                            candidateDetailButton(task)
                            candidateStatusPicker(task)
                        }
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                .padding(.bottom, 12)
            }
        }.disabled(model.updatingTaskIDs.contains(task.id))
    }

    private func candidateTitle(_ task: WorkTask) -> some View {
        Button { expandedCandidateID = expandedCandidateID == task.id ? nil : task.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 5) {
                    Text("\(task.projectTitle) · \(task.evidence.count) 条依据").lineLimit(1)
                    Image(systemName: expandedCandidateID == task.id ? "chevron.up" : "chevron.right").font(.system(size: 9))
                }.font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help(task.title).accessibilityHint("展开或收起来源依据")
    }

    private func candidateControls(_ task: WorkTask) -> some View {
        let status = candidateStatuses[task.id] ?? task.suggestedStatus.flatMap { $0.isConfirmed ? $0 : nil } ?? .todo
        return HStack(spacing: 10) {
            statusLabel(status, prefix: candidateStatuses[task.id] == nil ? String(localized: "建议") : String(localized: "设为"))
                .font(.caption).foregroundStyle(status.tint).frame(width: 80, alignment: .leading)
            Button(String(localized: "确认"), systemImage: "checkmark") { model.reviewTask(task.id, status) }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("确认\(task.title)，加入\(status.title)")
            Button(String(localized: "忽略\(task.title)"), systemImage: "xmark") { model.reviewTask(task.id, .ignored) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary).help("忽略这条建议")
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func candidateDetailButton(_ task: WorkTask) -> some View {
        Button("查看来源与详情") { selectedID = task.id }.buttonStyle(.borderless).font(.caption)
    }

    private func candidateStatusPicker(_ task: WorkTask) -> some View {
        Picker("确认后设为", selection: Binding(get: { candidateStatuses[task.id] ?? task.suggestedStatus ?? .todo }, set: { candidateStatuses[task.id] = $0 })) {
            ForEach(columns, id: \.self) { Text($0.title).tag($0) }
        }.font(.caption).controlSize(.small).fixedSize()
    }

    private func statusLabel(_ status: WorkTaskStatus, prefix: String = "") -> some View {
        HStack(spacing: 6) {
            Image(systemName: status == .done ? "checkmark.circle.fill" : status == .doing ? "circle.lefthalf.filled" : "circle")
                .font(.system(size: 10)).foregroundStyle(status.tint)
            Text(prefix + status.title)
        }
    }

    private func column(_ status: WorkTaskStatus) -> some View {
        let items = tasks.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                statusLabel(status).font(.headline)
                Text(items.count.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 12).frame(height: 44)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: taskCardSpacing) {
                    if items.isEmpty {
                        Text("暂无\(status.title)任务").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: taskCardHeight, alignment: .center)
                    }
                    ForEach(items) { task in
                        let waiting = !task.waitingReason.isEmpty && task.status != .done
                        let aiUpdated = model.workTaskEvents.last(where: { $0.taskID == task.id })?.actor == .ai
                        let hasUpdate = (task.suggestedStatus.map { $0 != task.status } ?? false) || aiUpdated
                        Button { selectedID = task.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    .lineLimit(waiting && hasUpdate ? 2 : 3)
                                if waiting {
                                    Label(String(localized: "等待：\(task.waitingReason)"), systemImage: "clock").font(.caption).foregroundStyle(.orange)
                                        .lineLimit(1).help("等待：\(task.waitingReason)")
                                }
                                if let suggestion = task.suggestedStatus, suggestion != task.status {
                                    Label(String(localized: "待确认：调整为\(suggestion.title)"), systemImage: "sparkle").font(.caption).foregroundStyle(.orange).lineLimit(1)
                                } else if aiUpdated {
                                    Label(String(localized: "AI 已更新进展"), systemImage: "sparkles").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                HStack(alignment: .firstTextBaseline) {
                                    Text(task.projectTitle).lineLimit(1)
                                    Spacer(minLength: 6)
                                    if let date = task.completedAt { Text(date, format: .dateTime.month(.defaultDigits).day()).fixedSize() }
                                    else { Text(task.evidence.isEmpty ? String(localized: "手动创建") : String(localized: "\(task.evidence.count) 条依据")).fixedSize() }
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: taskCardHeight)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selectedID == task.id ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.35)))
                        }
                        .buttonStyle(.plain).disabled(model.updatingTaskIDs.contains(task.id)).help(task.title)
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
            }
            .frame(height: CGFloat(visibleTaskRows) * taskCardHeight + CGFloat(visibleTaskRows - 1) * taskCardSpacing)
            .padding(.horizontal, 10).padding(.bottom, 10)
            .accessibilityLabel("\(status.title)任务，可上下滚动")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(status == .todo ? Color.primary.opacity(0.035) : status.tint.opacity(colorScheme == .dark ? 0.12 : 0.07))
                }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            let ids = values.compactMap(UUID.init(uuidString:)).filter { id in model.workTasks.contains { $0.id == id && $0.status.isConfirmed } }
            for id in ids { model.setTaskStatus(id, status) }
            return !ids.isEmpty
        }
    }
}

private struct TaskReportsView: View {
    @ObservedObject var model: MyClipModel
    let openTask: (UUID) -> Void
    @State private var period = WorkTaskReportPeriod.day
    @State private var date = Date()
    @State private var copied = false
    @State private var sharing = false
    @State private var savedDocument: WorkTaskReportDocument?
    @State private var editingDocument: WorkTaskReportDocument?
    @State private var loading = true
    @State private var loadError: String?
    @State private var showingSources = false
    @State private var selectedSource: UUID?

    private var report: WorkTaskReport {
        WorkTaskReport(period: period, containing: date, tasks: model.workTasks, events: model.workTaskEvents)
    }
    private var document: WorkTaskReportDocument {
        savedDocument?.id == report.document.id ? savedDocument! : report.document
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { periodPicker; dateControls; Spacer(minLength: 0); actions }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { periodPicker; Spacer(minLength: 20); actions }
                        dateControls
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: 1200)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label(savedDocument?.id == document.id ? String(localized: "已保存草稿") : String(localized: "草稿"), systemImage: "doc.badge.ellipsis")
                            Spacer()
                            Button(String(localized: "参考任务"), systemImage: "sidebar.right") { showingSources = true }
                                .buttonStyle(.plain).disabled(document.taskIDs.isEmpty || loading)
                        }.font(.callout).foregroundStyle(.secondary)
                        if loading {
                            ProgressView("正在读取报告…").frame(maxWidth: .infinity).padding(60)
                        } else if let loadError {
                            VStack(spacing: 12) {
                                Text("无法读取已保存的报告").font(.headline)
                                Text(loadError).font(.callout).foregroundStyle(.secondary)
                                Button("重试") { Task { await loadDocument() } }
                            }.frame(maxWidth: .infinity).padding(40)
                        } else {
                            ReportPaper(document: .constant(document), compact: geometry.size.width < 700)
                        }
                    }
                    .padding(geometry.size.width < 700 ? 20 : 32).frame(maxWidth: 1060).frame(maxWidth: .infinity)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
        .task(id: report.document.id) { await loadDocument() }
        .onChange(of: document.markdown) { _ in copied = false }
        .sheet(item: $editingDocument) { document in
            ReportEditor(store: model.store, document: document) { savedDocument = $0 }
        }
        .sheet(isPresented: $showingSources, onDismiss: {
            if let selectedSource { openTask(selectedSource); self.selectedSource = nil }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("参考任务").font(.title2.weight(.semibold))
                    Spacer()
                    Button("关闭") { showingSources = false }.keyboardShortcut(.cancelAction)
                }
                Text("查看任务详情、来源依据与状态记录。任务详情显示当前进度。")
                    .font(.callout).foregroundStyle(.secondary)
                List(model.workTasks.filter { document.taskIDs.contains($0.id) }) { task in
                    Button {
                        selectedSource = task.id
                        showingSources = false
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            ReportStatusIcon(status: task.status)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.title).foregroundStyle(.primary)
                                Text("\(task.projectTitle) · \(task.status.title)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.inset)
            }.padding(24).frame(width: 620, height: 470)
        }
    }

    private var periodPicker: some View {
        Picker("报告周期", selection: $period) {
            ForEach(WorkTaskReportPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(String(localized: "编辑"), systemImage: "square.and.pencil") { editingDocument = document }
                .disabled(loading || loadError != nil || document.taskIDs.isEmpty)
            Button(String(localized: "分享"), systemImage: "square.and.arrow.up") { sharing = true }
                .disabled(loading || loadError != nil || document.taskIDs.isEmpty)
                .popover(isPresented: $sharing, arrowEdge: .bottom) {
                    ReportSharePanel(document: document) { sharing = false }
                }
            Button(copied ? String(localized: "已复制") : String(localized: "复制报告"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(document.markdown, forType: .string)
            }.buttonStyle(.borderedProminent).disabled(loading || loadError != nil || document.taskIDs.isEmpty)
        }.controlSize(.small).fixedSize(horizontal: true, vertical: false)
    }

    private var dateControls: some View {
        HStack(spacing: 10) {
            Button(String(localized: "上一期"), systemImage: "chevron.left") { movePeriod(-1) }.labelStyle(.iconOnly)
            Label(report.dateTitle, systemImage: "calendar").font(.callout).foregroundStyle(.secondary)
            Button(String(localized: "下一期"), systemImage: "chevron.right") { movePeriod(1) }
                .labelStyle(.iconOnly).disabled(report.interval.end > Date())
            if !report.isCurrent { Button("本期") { date = Date() } }
        }.buttonStyle(.borderless).fixedSize()
    }

    @MainActor private func loadDocument() async {
        loading = true
        loadError = nil
        do {
            let saved = try await model.store.savedWorkTaskReport(for: report)
            guard !Task.isCancelled else { return }
            savedDocument = saved
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func movePeriod(_ offset: Int) {
        if let next = Calendar.current.date(byAdding: period.component, value: offset, to: report.interval.start) { date = next }
    }

}

struct ReportStatusIcon: View {
    let status: WorkTaskStatus
    var body: some View {
        Image(systemName: status == .done ? "checkmark.circle.fill" : status == .doing ? "circle.lefthalf.filled" : "circle")
            .font(.system(size: 15)).foregroundStyle(status.tint)
            .frame(width: 18, height: 22).accessibilityLabel(status.title)
    }
}

private struct ReportPaper: View {
    @Binding var document: WorkTaskReportDocument
    var editing = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(spacing: 12) {
                Text(document.title).font(.system(size: 28, weight: .semibold))
                Text(document.dateTitle).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.top, 4).padding(.bottom, 6)
            Divider()
            ForEach($document.sections) { $section in
                VStack(alignment: .leading, spacing: 20) {
                    if editing {
                        TextField("大纲标题", text: $section.title).font(.system(size: 18, weight: .semibold))
                    } else {
                        Text(section.title).font(.system(size: 18, weight: .semibold))
                    }
                    if section.projects.isEmpty { Text("暂无记录。").foregroundStyle(.secondary) }
                    ForEach($section.projects) { $project in
                        VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                HStack { Text(project.name).fontWeight(.semibold); Spacer(); progress(project) }
                                VStack(alignment: .leading, spacing: 5) { Text(project.name).fontWeight(.semibold); progress(project) }
                            }
                            ForEach($project.items) { $item in
                                HStack(alignment: .top, spacing: 10) {
                                    ReportStatusIcon(status: item.status)
                                    if editing {
                                        VStack(alignment: .leading, spacing: 6) {
                                            TextField("事项标题", text: $item.title, axis: .vertical).fontWeight(.semibold)
                                            TextField("补充成果、进展或下一步安排", text: $item.body, axis: .vertical)
                                                .foregroundStyle(.secondary)
                                        }.textFieldStyle(.roundedBorder)
                                    } else {
                                        (Text(item.title).fontWeight(.semibold)
                                         + Text(item.body.isEmpty ? "" : " · " + item.body).foregroundColor(.secondary))
                                            .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                    }
                                }
                            }
                        }.padding(.bottom, 6)
                    }
                }
            }
        }
        .font(.system(size: 15)).padding(compact ? 24 : 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.09)))
    }

    private func progress(_ project: WorkTaskReportDocument.Project) -> some View {
        Text(project.progress).font(.caption).foregroundStyle(.secondary)
    }
}

private struct ReportEditor: View {
    let store: LibraryStore
    @State var document: WorkTaskReportDocument
    let saved: (WorkTaskReportDocument) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑\(document.title)").font(.headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? String(localized: "正在保存…") : String(localized: "保存")) {
                    saving = true
                    Task {
                        do { try await store.saveWorkTaskReport(document); saved(document); dismiss() }
                        catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving)
            }.padding(20)
            Divider()
            if let error { Text("保存失败：\(error)").foregroundStyle(.red).padding(12) }
            ScrollView { ReportPaper(document: $document, editing: true).padding(24) }
                .background(Color(nsColor: .underPageBackgroundColor)).disabled(saving)
        }.frame(width: 820, height: 680).interactiveDismissDisabled(saving)
    }
}

private struct TaskDetailView: View {
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

private struct TaskEditorView: View {
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
