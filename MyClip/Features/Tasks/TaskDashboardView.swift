import SwiftUI
import MyClipCore

extension WorkTaskStatus {
    var tint: Color {
        switch self {
        case .candidate: .secondary
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
    @State private var showingDiscoveryDetails = false
    private let columns: [WorkTaskStatus] = [.todo, .doing, .done]
    private let taskCardHeight: CGFloat = 110
    private let taskCardSpacing: CGFloat = 8

    private var visibleTaskRows: Int { min(5, max(1, columns.map { status in tasks.filter { $0.status == status }.count }.max() ?? 0)) }

    private var tasks: [WorkTask] {
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.workTasks.filter { query.isEmpty || ($0.title + " " + $0.project + " " + $0.evidence.map(\.body).joined(separator: " ")).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Picker("Kanban", selection: $model.showingTaskReports) {
                        Text(verbatim: "Kanban").tag(false)
                        Text(verbatim: "Reports").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24).padding(.vertical, 10).frame(maxWidth: 1200).frame(maxWidth: .infinity)
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
                            Button("恢复到待办") { model.setTaskStatus(task.id, .todo) }.buttonStyle(.bordered)
                        }.padding(.vertical, 6)
                    }
                }.font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var taskCount: some View {
        Text("当前任务 · \(tasks.filter { $0.status.isOnBoard }.count) 项")
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
                    Button(showingDiscoveryDetails ? String(localized: "收起原因") : String(localized: "查看原因")) { showingDiscoveryDetails.toggle() }.buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                if !model.discoveringTasks {
                    Button(String(localized: "关闭提示"), systemImage: "xmark") { model.taskDiscoveryMessage = nil }
                        .labelStyle(.iconOnly).buttonStyle(.bordered).foregroundStyle(.secondary)
                }
            }
            if showingDiscoveryDetails {
                Text(message).textSelection(.enabled).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }.font(.caption)
    }

    private func statusLabel(_ status: WorkTaskStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status == .done ? "checkmark.circle.fill" : status == .doing ? "circle.lefthalf.filled" : "circle")
                .font(.system(size: 10)).foregroundStyle(status.tint)
            Text(status.title)
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
                        Button { selectedID = task.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    .lineLimit(waiting && aiUpdated ? 2 : 3)
                                if waiting {
                                    Label(String(localized: "等待：\(task.waitingReason)"), systemImage: "clock").font(.caption).foregroundStyle(.orange)
                                        .lineLimit(1).help("等待：\(task.waitingReason)")
                                }
                                if aiUpdated {
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
            let ids = values.compactMap(UUID.init(uuidString:)).filter { id in model.workTasks.contains { $0.id == id && $0.status.isOnBoard } }
            for id in ids { model.setTaskStatus(id, status) }
            return !ids.isEmpty
        }
    }
}
