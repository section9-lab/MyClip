import SwiftUI
import AppKit
import MyClipCore

struct ExecutionDetailView: View {
    @ObservedObject var model: MyClipModel
    let job: ClipJob
    @Environment(\.dismiss) private var dismiss
    @State private var records: [ExecutionRecord] = []
    @State private var inputs: [OrganizationInput] = []
    @State private var loadError: String?
    @State private var loaded = false

    private var currentJob: ClipJob { model.library.jobs.first { $0.id == job.id } ?? job }
    private var usage: TokenUsageSummary { model.tokenUsage.jobs[job.id] ?? TokenUsageSummary() }
    private var requestCount: Int { max(usage.calls, records.count) }
    private var costs: [ExecutionCost] { records.compactMap(\.cost) }
    private var costTotal: String {
        guard !costs.isEmpty else { return "未回传" }
        return Dictionary(grouping: costs, by: \.currency).sorted { $0.key < $1.key }.map { currency, values in
            "\(currency) \(values.reduce(Decimal.zero) { $0 + $1.amount }.formatted(.number.precision(.fractionLength(2...6))))"
        }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AgentBrandIcon(agent: job.agent, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("执行记录").font(.title2.bold())
                    Text("\(job.agent.name) · \(job.sourceIDs.count) 条记录 · \(job.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summary
                    if !inputs.isEmpty {
                        Text("本批输入：\(inputs.filter(\.usesImage).count) 张图片 · \(inputs.compactMap(\.text).count) 条 OCR 文本 · \(inputs.compactMap(\.text).reduce(0) { $0 + $1.count }) 字符")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = currentJob.error {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    } else if !loaded {
                        ProgressView("正在读取执行记录…")
                    } else if records.isEmpty {
                        Text(currentJob.state == .running || currentJob.state == .queued
                             ? "请求开始后，工具调用会显示在这里。"
                             : "此任务没有保存工具调用明细。启用此功能后的新请求会自动记录。")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        request(record, index: index)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 440, idealHeight: 620)
        .task(id: currentJob.state.rawValue) {
            while !Task.isCancelled {
                do {
                    records = try await model.store.executionRecords(jobID: job.id)
                    if inputs.isEmpty { inputs = try await model.store.organizationInputs(jobID: job.id) }
                    loadError = nil
                } catch { loadError = error.localizedDescription }
                loaded = true
                if currentJob.state != .running && currentJob.state != .queued { return }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("本次任务").font(.headline)
                Spacer()
                Text("含重试，共 \(requestCount) 次请求").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Token \(count(usage.totalTokens))").font(.title2.monospacedDigit().bold())
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("已记录费用").font(.caption).foregroundStyle(.secondary)
                    Text(costTotal).font(.title3.monospacedDigit().weight(.semibold))
                }
            }
            tokenGrid(input: usage.inputTokens, output: usage.outputTokens,
                read: usage.cachedReadTokens, write: usage.cachedWriteTokens)
            Text("用量已回传 \(usage.reportedCalls)/\(requestCount) 次 · 费用已记录 \(costs.count)/\(requestCount) 次")
                .font(.caption).foregroundStyle(.secondary)
            Text("费用按 Agent 回传的会话累计值计算本次差额；未回传或缺少会话基准时不估算。缓存读取和写入按回传值单独展示，不额外叠加到总 Token。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.textSelection(.enabled)
    }

    private func request(_ record: ExecutionRecord, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Text("请求 \(index + 1)").font(.headline)
                Text(record.startedAt, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                Spacer()
                Text(requestStatus(record)).foregroundStyle(record.error == nil ? Color.secondary : .orange)
            }.font(.subheadline)
            if let error = record.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text("Token \(count(record.usage?.totalTokens))")
                Spacer()
                Text(record.cost.map { "\($0.currency) \($0.amount.formatted(.number.precision(.fractionLength(2...6))))" } ?? "费用：未回传或无法计算")
            }.font(.callout.monospacedDigit()).textSelection(.enabled)
            tokenGrid(input: record.usage?.inputTokens, output: record.usage?.outputTokens,
                read: record.usage?.cachedReadTokens, write: record.usage?.cachedWriteTokens)
            if let thought = record.usage?.thoughtTokens {
                Text("推理 Token \(thought.formatted())（已包含在回传用量中）").font(.caption).foregroundStyle(.secondary)
            }
            Text("工具调用 · \(record.tools.count)").font(.subheadline.weight(.medium)).padding(.top, 4)
            if record.tools.isEmpty {
                Text(record.finishedAt == nil && currentJob.state == .running ? "等待 Agent 回传工具调用…" : "此请求未回传工具调用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(record.tools) { tool in
                ExecutionToolView(tool: tool, finished: record.finishedAt != nil || currentJob.state != .running)
            }
            if let response = record.response, !response.isEmpty {
                DisclosureGroup("Agent 回复") { ExecutionTextBlock(text: response) }
            }
            Text("会话 \(record.sessionID)").font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
    }

    private func requestStatus(_ record: ExecutionRecord) -> String {
        if record.error != nil { return "失败" }
        if record.stopReason == "cancelled" { return "已取消" }
        if record.stopReason == "end_turn" { return "已完成" }
        if let reason = record.stopReason { return "已停止 · \(reason)" }
        return currentJob.state == .running ? "执行中" : "未记录结束状态"
    }

    private func count(_ value: Int?) -> String { value?.formatted() ?? "未回传" }

    private func tokenGrid(input: Int?, output: Int?, read: Int?, write: Int?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("输入 Token").foregroundStyle(.secondary)
                Text(count(input)).monospacedDigit()
                Text("输出 Token").foregroundStyle(.secondary)
                Text(count(output)).monospacedDigit()
            }
            GridRow {
                Text("缓存读取").foregroundStyle(.secondary)
                Text(count(read)).monospacedDigit()
                Text("缓存写入").foregroundStyle(.secondary)
                Text(count(write)).monospacedDigit()
            }
        }.font(.callout).textSelection(.enabled)
    }
}

private struct ExecutionToolView: View {
    let tool: ACPToolCall
    let finished: Bool
    @State private var expanded = false

    private var status: String {
        switch tool.status {
        case "completed": "已完成"
        case "failed": "失败"
        case "pending": finished ? "未回传结束状态" : "等待执行"
        case "in_progress": finished ? "未回传结束状态" : "执行中"
        default: tool.status
        }
    }

    private var kind: (label: String, symbol: String) {
        switch tool.kind {
        case "execute": ("命令", "terminal")
        case "read": ("读取文件", "doc.text")
        case "edit": ("编辑文件", "pencil")
        case "delete": ("删除", "trash")
        case "move": ("移动", "folder")
        case "search": ("搜索", "magnifyingglass")
        case "fetch": ("获取数据", "arrow.down.doc")
        default: ("工具", "wrench.and.screwdriver")
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(tool.name ?? tool.kind) · \(tool.id)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    ForEach(Array(tool.locations.enumerated()), id: \.offset) { _, location in
                        Text(location.path + (location.line.map { ":\($0)" } ?? ""))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let input = tool.rawInput { ExecutionTextBlock(title: "调用参数 / 命令", text: input) }
                    ForEach(Array(tool.content.enumerated()), id: \.offset) { _, content in
                        if content.type == "diff" {
                            Text(content.path ?? "文件变更").font(.caption.monospaced()).textSelection(.enabled)
                            ExecutionTextBlock(title: content.oldText == nil ? "新增文件" : "修改前", text: content.oldText ?? "（文件原先不存在）")
                            ExecutionTextBlock(title: "修改后", text: content.newText ?? "未回传")
                        } else if let text = content.text { ExecutionTextBlock(title: "执行结果", text: text) }
                    }
                    if let output = tool.rawOutput {
                        DisclosureGroup("原始返回值") { ExecutionTextBlock(text: output) }
                    }
                }.padding(.vertical, 10)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind.symbol).frame(width: 18).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title).lineLimit(2)
                    Text("\(kind.label) · \(tool.startedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(status).font(.caption).foregroundStyle(tool.status == "failed" ? .orange : .secondary)
            }
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ExecutionTextBlock: View {
    var title = ""
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !title.isEmpty { Text(title).foregroundStyle(.secondary) }
                Spacer()
                Button("复制", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }.buttonStyle(.borderless)
            }.font(.caption)
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(240, CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count) * 16 + 16))
                .padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
