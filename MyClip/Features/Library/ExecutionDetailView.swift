import SwiftUI
import AppKit
import MyClipCore

/// What one batch did: which tools the Agent called, how long it took and what it cost.
/// Deliberately leaves out prompt text, tool arguments and replies.
struct ExecutionDetailView: View {
    @ObservedObject var model: MyClipModel
    let job: ClipJob
    @Environment(\.dismiss) private var dismiss
    @State private var records: [ExecutionRecord] = []
    @State private var loadError: String?
    @State private var loaded = false

    private var currentJob: ClipJob { model.library.jobs.first { $0.id == job.id } ?? job }
    private var usage: TokenUsageSummary { model.tokenUsage.jobs[job.id] ?? TokenUsageSummary() }
    private var tools: [ACPToolCall] { records.flatMap(\.tools) }
    private var isLive: Bool { currentJob.state == .running || currentJob.state == .queued }

    private var duration: TimeInterval? {
        guard let start = records.first?.startedAt else { return nil }
        let end = records.last?.finishedAt ?? (currentJob.state == .running ? Date() : records.last?.startedAt)
        return end.map { max(0, $0.timeIntervalSince(start)) }
    }

    private var writtenPaths: [String] {
        var seen: Set<String> = []
        return tools.filter { $0.kind == "edit" }.flatMap { $0.locations.map(\.path) + $0.content.compactMap(\.path) }
            .map { $0.components(separatedBy: "/Memory/").last ?? $0 }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AgentBrandIcon(agent: job.agent, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(job.sourceIDs.count) 条素材 · \(jobLabel(currentJob.state))").font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        Text(job.agent.name)
                        Text("·")
                        Text(job.createdAt, format: .dateTime.month().day().hour().minute())
                        if currentJob.attempts > 1 { Text("·"); Text("第 \(currentJob.attempts) 次尝试") }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = currentJob.error {
                        Label {
                            Text(error + (currentJob.state == .failed ? "\n重试会用同一个 Agent 重新建立连接并处理这批素材。" : ""))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: { Image(systemName: "exclamationmark.circle") }
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    summaryTiles
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    } else if !loaded {
                        ProgressView("正在读取执行记录…")
                    } else {
                        toolsSection
                        sequenceSection
                        if !writtenPaths.isEmpty { writtenSection }
                    }
                    tokenSection
                    actions
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 440, idealHeight: 640)
        .task(id: currentJob.state.rawValue) {
            while !Task.isCancelled {
                do {
                    records = try await model.store.executionRecords(jobID: job.id)
                    loadError = nil
                } catch { loadError = error.localizedDescription }
                loaded = true
                if !isLive { return }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    // MARK: - Sections

    private var summaryTiles: some View {
        HStack(spacing: 10) {
            tile("用时", value: duration.map(clock) ?? "–")
            tile("工具调用", value: loaded ? "\(tools.count) 次" : "–")
            tile("Token", value: usage.totalTokens.map(compact) ?? (isLive ? "等待回传" : "未记录"))
        }
    }

    private func tile(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private struct ToolGroup: Identifiable {
        let name: String
        let kind: ToolKind
        let count: Int
        var id: String { name }
    }

    private var toolGroups: [ToolGroup] {
        var counts: [String: (ToolKind, Int)] = [:]
        var order: [String] = []
        for tool in tools {
            let kind = ToolKind(tool.kind)
            let name = tool.name.flatMap { $0.isEmpty ? nil : $0 } ?? kind.label
            if counts[name] == nil { order.append(name) }
            counts[name] = (kind, (counts[name]?.1 ?? 0) + 1)
        }
        return order.map { ToolGroup(name: $0, kind: counts[$0]!.0, count: counts[$0]!.1) }
            .sorted { $0.count > $1.count }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("调用过的工具")
            if toolGroups.isEmpty {
                Text(isLive ? "等待 Agent 开始调用工具…" : "这批没有回传工具调用。").font(.caption).foregroundStyle(.secondary)
            } else {
                let most = toolGroups.first?.count ?? 1
                ForEach(toolGroups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(group.kind.color).frame(width: 10, height: 10)
                            Text(group.name).font(.callout)
                            Text(group.kind.label).font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Text("\(group.count) 次").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2).fill(group.kind.color)
                                        .frame(width: geometry.size.width * CGFloat(group.count) / CGFloat(most))
                                }
                        }.frame(height: 4).padding(.leading, 18)
                    }
                }
            }
        }
    }

    private var sequenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("调用顺序")
            if tools.isEmpty {
                Text("–").font(.caption).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 3) {
                    ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                        let stopped = currentJob.state == .failed || currentJob.state == .cancelled
                        RoundedRectangle(cornerRadius: 2).fill(ToolKind(tool.kind).color).frame(width: 9, height: 9)
                            .overlay { if tool.status == "failed" { RoundedRectangle(cornerRadius: 2).strokeBorder(.orange, lineWidth: 1.5).padding(-1.5) } }
                            .overlay { if stopped, index == tools.count - 1 { RoundedRectangle(cornerRadius: 2).strokeBorder(.orange, lineWidth: 1.5).padding(-1.5) } }
                            .help("\(index + 1). \(tool.title)")
                    }
                    if currentJob.state == .running { ProgressView().controlSize(.mini).frame(width: 9, height: 9) }
                }
                Text(sequenceNote).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var sequenceNote: String {
        switch currentJob.state {
        case .failed: "最后一次调用之后没有新进度，停止等待。"
        case .cancelled: "在第 \(tools.count) 次调用后被取消，素材已回到队列。"
        case .running: "正在进行第 \(tools.count + 1) 次调用…"
        case .queued: "等待下一次尝试。"
        case .completed: "共 \(tools.count) 次调用，\(records.count) 次请求。"
        }
    }

    private var writtenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("写入")
            FlowLayout(spacing: 6) {
                ForEach(writtenPaths, id: \.self) { path in
                    Text(path).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6)).textSelection(.enabled)
                }
            }
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Token 明细")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow { Text("输入").foregroundStyle(.secondary); Text(count(usage.inputTokens)) }
                GridRow { Text("输出").foregroundStyle(.secondary); Text(count(usage.outputTokens)) }
                GridRow { Text("缓存读取").foregroundStyle(.secondary); Text(count(usage.cachedReadTokens)) }
                GridRow { Text("缓存写入").foregroundStyle(.secondary); Text(count(usage.cachedWriteTokens)) }
            }.font(.callout).monospacedDigit().textSelection(.enabled)
            Text("已回传 \(usage.reportedCalls) / \(max(usage.calls, records.count)) 次请求的用量。缓存读取和写入不额外叠加到总数。")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if currentJob.state == .failed {
                Button("重试这批", systemImage: "arrow.clockwise") { model.retry(currentJob); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(!model.canRetry(currentJob))
            }
            if currentJob.state == .running || currentJob.state == .queued {
                Button("取消本批") { model.cancel(currentJob); dismiss() }
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.4)
    }

    private func count(_ value: Int?) -> String { value?.formatted() ?? "未回传" }

    private func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1e6)
        case 1_000...: return "\(value / 1_000)K"
        default: return "\(value)"
        }
    }

    private func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}

/// Tool families the ACP adapters report; each keeps one color across the whole app.
private enum ToolKind {
    case read, edit, execute, search, fetch, think, other

    init(_ raw: String) {
        switch raw {
        case "read": self = .read
        case "edit", "delete", "move": self = .edit
        case "execute": self = .execute
        case "search": self = .search
        case "fetch": self = .fetch
        case "think": self = .think
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .read: "读取"
        case .edit: "写入"
        case .execute: "命令"
        case .search: "搜索"
        case .fetch: "获取"
        case .think: "思考"
        case .other: "其他"
        }
    }

    var color: Color {
        switch self {
        case .read: Color(hex: 0x2A78D6)
        case .edit: Color(hex: 0x1BAF7A)
        case .execute: Color(hex: 0xEDA100)
        case .search: Color(hex: 0xEB6834)
        case .fetch: Color(hex: 0xE87BA4)
        case .think: Color(hex: 0x4A3AA7)
        case .other: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/// Wraps fixed-size children onto as many rows as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
