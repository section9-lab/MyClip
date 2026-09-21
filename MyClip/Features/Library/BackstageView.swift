import Charts
import SwiftUI
import MyClipCore

/// Who organizes captures, how the queue is doing, and what it costs.
struct BackstageView: View {
    @ObservedObject var model: MyClipModel
    @State private var selectedJob: ClipJob?
    @State private var jobFilter = JobFilter.all
    @State private var usageRange = UsageRange.month
    @State private var usageAsTable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Backstage").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                    Text("谁在整理你的截图、进展如何、花了多少").foregroundStyle(.secondary)
                }
                ForEach(model.permissions) { permission in PermissionRequestView(model: model, permission: permission) }
                agentsSection
                jobsSection
                usageSection
            }.padding(32).frame(maxWidth: 920).frame(maxWidth: .infinity)
        }
        .onAppear { model.refreshAgentAvailability() }
        .sheet(item: $selectedJob) { ExecutionDetailView(model: model, job: $0) }
    }

    // MARK: - Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("整理 Agent", hint: "只会有一个在工作，切换后对等待中的截图生效")
            BackstageCard {
                ForEach(Array(ClipAgent.allCases.enumerated()), id: \.element) { index, agent in
                    if index > 0 { Divider().padding(.leading, 18) }
                    agentRow(agent)
                }
                cardFooter("Agent 以 Full 权限运行，读写文件、运行工具和访问网络都不需要逐次确认；使用各自已有的登录。", symbol: "checkmark.shield")
            }
        }
    }

    private func agentRow(_ agent: ClipAgent) -> some View {
        let state = model.state(agent)
        let enabled = model.preferences.enabledAgent == agent
        let availability = model.localAgents[agent] ?? .missing
        let installing = model.agents.values.contains { $0.phase == .installing }
        let selecting = model.selectingDefaultAgent != nil
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: enabled ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 17)).foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.5))
                .accessibilityHidden(true)
            AgentBrandIcon(agent: agent, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(agent.name).font(.headline)
                    if enabled { StatusChip("当前使用", tone: .accent) }
                    phaseChip(state, enabled: enabled, availability: availability)
                }
                Text(agentDescription(agent, state: state, enabled: enabled, availability: availability))
                    .font(.caption).foregroundStyle(state.phase == .failed ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !state.available, !state.authMethods.isEmpty {
                    HStack(spacing: 8) {
                        Text("登录方式").font(.caption).foregroundStyle(.secondary)
                        ForEach(state.authMethods) { method in
                            Button(method.name) { model.authenticate(agent, method: method) }.disabled(state.busy)
                        }
                    }.controlSize(.small)
                }
            }
            Spacer(minLength: 12)
            if enabled {
                Menu {
                    if state.phase == .failed { Button("重试连接") { model.connect(agent) } }
                    else { Button("重新连接") { model.connect(agent) }.disabled(state.busy) }
                    if model.hasLoginCommand(agent) { Button("复制登录命令") { model.copyLoginCommand(for: agent) } }
                    Divider()
                    Button("停用", role: .destructive) { model.disableAgent() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                    .disabled(model.preview).help("重新连接、复制登录命令或停用")
            } else if state.busy || model.selectingDefaultAgent == agent {
                ProgressView().controlSize(.small)
            } else {
                Button(useLabel(state, availability: availability)) { Task { await model.selectDefaultAgent(agent) } }
                    .controlSize(.small)
                    .disabled(model.preview || !availability.canSelect || installing || selecting)
                    .help(availability.canSelect ? "把后续截图交给 \(agent.name) 整理" : "先安装 \(agent.name) 命令行")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(agent.name)
        .accessibilityValue(state.detail)
    }

    private func useLabel(_ state: ClipAgentState, availability: LocalAgentAvailability) -> String {
        if state.available { return "使用" }
        return availability == .connector ? "连接并使用" : "安装并使用"
    }

    @ViewBuilder private func phaseChip(_ state: ClipAgentState, enabled: Bool, availability: LocalAgentAvailability) -> some View {
        switch state.phase {
        case .working: StatusChip("整理中", tone: .accent, pulsing: true)
        case .connecting: StatusChip("连接中", tone: .neutral)
        case .installing: StatusChip("安装组件", tone: .neutral)
        case .permission: StatusChip("等待确认", tone: .warning)
        case .failed: StatusChip("出错", tone: .warning)
        case .ready: StatusChip("已连接", tone: .good)
        case .disconnected:
            if !availability.canSelect { StatusChip("未检测到", tone: .neutral) }
            else if enabled { StatusChip("待连接", tone: .neutral) }
        }
    }

    private func agentDescription(_ agent: ClipAgent, state: ClipAgentState, enabled: Bool, availability: LocalAgentAvailability) -> String {
        if state.phase == .failed {
            if let job = model.latestFailedJob, job.agent == agent, let error = job.error { return error }
            return state.detail.hasSuffix("。") ? state.detail : state.detail + "。"
        }
        if state.phase == .disconnected, enabled, let retrying = model.jobAwaitingRetry, retrying.agent == agent, let error = retrying.error {
            return "\(error) 第 \(retrying.attempts + 1) 次尝试排队中。"
        }
        switch (availability, agent) {
        case (.missing, .codex): return "没有找到 Codex 命令行。安装 Codex 桌面端或命令行后再来连接。"
        case (.missing, _): return "没有找到 \(agent.cliName) 命令行。安装后再来连接。"
        case (.desktopOnly, _): return "只检测到桌面端。整理需要 \(agent.name) 命令行。"
        case (.commandLine, .codex): return "会安装 ACP 连接组件，使用 Codex / ChatGPT 的现有登录。"
        case (.commandLine, _): return "会安装 ACP 连接组件，使用 \(agent.name) 的现有登录和网络设置。"
        case (.connector, .codex): return "使用 Codex / ChatGPT 的现有登录。"
        case (.connector, .claude): return "使用 Claude Code 命令行的现有登录和网络设置。首次使用需先在终端完成登录。"
        case (.connector, .opencode): return "通过 opencode acp 连接，使用 OpenCode 已登录的模型和服务商。首次使用需先运行 opencode auth login。"
        case (.connector, .cursor): return "通过 cursor-agent acp 连接，使用 Cursor 的现有登录。首次使用需先运行 cursor-agent login。"
        }
    }

    // MARK: - Jobs

    private enum JobFilter: String, CaseIterable, Identifiable {
        case all, open, done
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "全部"
            case .open: "未完成"
            case .done: "已完成"
            }
        }
        func matches(_ job: ClipJob) -> Bool {
            switch self {
            case .all: true
            case .open: job.state != .completed && job.state != .cancelled
            case .done: job.state == .completed
            }
        }
    }

    private var visibleJobs: [ClipJob] { model.library.jobs.filter(jobFilter.matches) }
    private var openJobCount: Int { model.library.jobs.filter(JobFilter.open.matches).count }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("整理记录").font(.title3.weight(.semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(model.organizationStatus(at: context.date)).font(.callout)
                        .foregroundStyle(model.library.queue.pauseReason != nil ? Color.orange : .secondary)
                }
                Spacer()
                queueActions
                Picker("筛选", selection: $jobFilter) {
                    ForEach(JobFilter.allCases) { filter in
                        Text(filter == .open && openJobCount > 0 ? "\(filter.title) \(openJobCount)" : filter.title).tag(filter)
                    }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 190)
            }
            BackstageCard {
                if let reason = model.library.queue.pauseReason {
                    Label(reason, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08))
                }
                if visibleJobs.isEmpty {
                    Text(model.library.jobs.isEmpty
                         ? (model.library.queue.pendingCount > 0 ? "截图已保存，开始整理后会在这里看到进度。" : "还没有整理记录。截图开始后会出现在这里。")
                         : "没有符合筛选条件的记录。")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleJobs.prefix(50)) { job in
                                jobRow(job)
                                Divider().padding(.leading, 60)
                            }
                        }
                    }.frame(maxHeight: 400)
                }
                HStack {
                    Text(visibleJobs.isEmpty ? "" : "\(visibleJobs.count) 条\(visibleJobs.count > 50 ? " · 显示最近 50 条" : "")")
                    Spacer()
                    Text("点击一条查看调用过的工具")
                }.font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.vertical, 8)
                Divider()
                DisclosureGroup {
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow { Text("顺序").foregroundStyle(.tertiary); Text("按截图时间先后整理，自动整理之间至少间隔 3 分钟。") }
                        GridRow { Text("每批上限").foregroundStyle(.tertiary); Text("最多 8 张图片、32 条 OCR 文本，文本合计不超过 12,000 字符。") }
                        GridRow { Text("用图还是用文字").foregroundStyle(.tertiary); Text("回车和手动截图直接用图片；鼠标事件优先用 OCR 文本，文字不可用或过长时改用原图。") }
                        GridRow { Text("超时与重试").foregroundStyle(.tertiary); Text("连续 5 分钟没有新进度就停止等待，单批最长 15 分钟。超时、断线等临时故障会自动重试，最多 \(RetryPolicy.maxAttempts) 次；之后停下等你处理。") }
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
                } label: {
                    Label("整理是怎么分批的", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder private var queueActions: some View {
        let queue = model.library.queue
        if queue.pauseReason != nil {
            Button("重试并继续", systemImage: "arrow.clockwise") { model.resumeAfterFailure() }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
                .disabled(model.preview || model.preferences.enabledAgent == nil)
                .help("用同一个 Agent 重新整理失败的那批，然后继续队列")
        } else if model.processingPaused {
            Button("继续整理", systemImage: "play.fill") { model.processingPaused = false }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(model.preview)
        } else {
            Button("立即整理", action: model.organizeNow).controlSize(.small).disabled(!model.canOrganizeNow)
                .help("不等间隔，马上整理下一批")
            Button("暂停", systemImage: "pause.fill") { model.processingPaused = true }
                .buttonStyle(.borderless).controlSize(.small).disabled(model.preview || model.preferences.enabledAgent == nil)
                .help("停止分配新批次，当前批次会先完成")
        }
    }

    private func jobRow(_ job: ClipJob) -> some View {
        let usage = model.tokenUsage.jobs[job.id]
        return HStack(alignment: .center, spacing: 12) {
            Button { selectedJob = job } label: {
                HStack(alignment: .center, spacing: 12) {
                    AgentBrandIcon(agent: job.agent, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("\(job.sourceIDs.count) 条素材").font(.subheadline.weight(.medium))
                            StatusChip(jobChipTitle(job), tone: jobTone(job), pulsing: job.state == .running)
                        }
                        jobDetail(job, usage: usage).font(.caption).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(job.createdAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("查看 \(job.sourceIDs.count) 条素材的整理详情，\(jobLabel(job.state))")
            if job.state == .failed {
                Button("重试", systemImage: "arrow.clockwise") { model.retry(job) }.controlSize(.small).disabled(!model.canRetry(job))
                    .help(model.canRetry(job) ? "重新整理这批素材" : "请先选择并连接 \(job.agent.name)，重试会继续使用原 Agent")
            } else if job.state == .running || job.state == .queued {
                Button("取消") { model.cancel(job) }.buttonStyle(.borderless).controlSize(.small)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func jobChipTitle(_ job: ClipJob) -> String {
        if job.isAwaitingRetry { return "等待第 \(job.attempts + 1) 次尝试" }
        return jobLabel(job.state)
    }

    private func jobTone(_ job: ClipJob) -> StatusChip.Tone {
        switch job.state {
        case .running: .accent
        case .completed: .good
        case .failed: .warning
        case .queued: job.isAwaitingRetry ? .warning : .neutral
        case .cancelled: .neutral
        }
    }

    @ViewBuilder private func jobDetail(_ job: ClipJob, usage: TokenUsageSummary?) -> some View {
        switch job.state {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.organizationActivity(at: context.date)).foregroundStyle(.secondary)
            }
        case .failed:
            Text(job.error ?? "未完成").foregroundStyle(.orange)
        case .queued:
            if let error = job.error { Text(error).foregroundStyle(.orange) }
            else { Text("排队中").foregroundStyle(.secondary) }
        case .cancelled:
            Text("素材已回到队列").foregroundStyle(.secondary)
        case .completed:
            HStack(spacing: 10) {
                if job.attempts > 1 { Text("第 \(job.attempts) 次尝试成功") }
                Text(usage?.totalTokens.map { "Token \($0.formatted())" } ?? "Token 未记录").monospacedDigit()
            }.foregroundStyle(.secondary)
        }
    }

    // MARK: - Usage

    private enum UsageRange: String, CaseIterable, Identifiable {
        case week, month, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .week: "7 天"
            case .month: "30 天"
            case .all: "全部"
            }
        }
        var days: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .all: nil
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Token 用量").font(.title3.weight(.semibold))
                Text("只统计 Agent 回传的部分").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("范围", selection: $usageRange) {
                    ForEach(UsageRange.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 170)
                Toggle(usageAsTable ? "图表" : "表格", isOn: $usageAsTable).toggleStyle(.button).controlSize(.small)
            }
            BackstageCard { UsageDashboard(statistics: model.tokenUsage, days: usageRange.days, asTable: usageAsTable) }
        }
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String, hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            Text(hint).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func cardFooter<Trailing: View>(_ text: String, symbol: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.25))
    }
}

/// White-on-grey grouped surface with a hairline; sections stack their rows inside.
struct BackstageCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct StatusChip: View {
    enum Tone { case neutral, accent, good, warning }
    let text: String
    let tone: Tone
    var pulsing = false
    @State private var dim = false

    init(_ text: String, tone: Tone, pulsing: Bool = false) {
        self.text = text
        self.tone = tone
        self.pulsing = pulsing
    }

    private var color: Color {
        switch tone {
        case .neutral: .secondary
        case .accent: .accentColor
        case .good: .green
        case .warning: .orange
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6).opacity(pulsing && dim ? 0.25 : 1)
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium)).foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true }
        }
    }
}

func jobLabel(_ state: ClipJobState) -> String {
    switch state {
    case .queued: "等待整理"
    case .running: "整理中"
    case .completed: "已完成"
    case .failed: "未完成"
    case .cancelled: "已取消"
    }
}

// MARK: - Usage dashboard

private struct UsageDashboard: View {
    let statistics: TokenUsageStatistics
    let days: Int?
    let asTable: Bool

    private var calendar: Calendar { .current }
    private var summary: TokenUsageSummary { statistics.summary(days: days) }
    private var buckets: [TokenUsageDay] {
        guard let days else { return statistics.history }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date())) ?? .distantPast
        return statistics.history.filter { $0.day >= start }
    }
    private var weekly: Bool { days == nil }
    private var deltaText: String? {
        guard let days else { return nil }
        let previous = statistics.previousSummary(days: days)
        guard let now = summary.totalTokens, let before = previous.totalTokens, before > 0 else { return nil }
        let change = Int((Double(now - before) / Double(before) * 100).rounded())
        return "较前 \(days) 天 \(change >= 0 ? "+" : "")\(change)%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tiles
            Divider()
            if summary.calls == 0 {
                Text(days == nil ? "还没有回传过用量。任务结束后会在这里汇总。" : "这段时间没有整理任务。")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 36)
            } else if asTable {
                table
            } else {
                chart.padding(.horizontal, 18).padding(.vertical, 14)
                Divider()
                composition.padding(.horizontal, 18).padding(.vertical, 14)
            }
            Divider()
            Text("含截图整理、任务识别和重试。旧任务和没有回传用量的请求不计入；缓存明细为已回传部分。")
                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tiles: some View {
        HStack(spacing: 0) {
            tile(days.map { "近 \($0) 天 Token" } ?? "累计 Token", value: compact(summary.totalTokens),
                 detail: deltaText ?? (days == nil ? "\(summary.calls) 次请求" : "全部 \(statistics.total.totalTokens?.formatted() ?? "未记录")"))
            Divider()
            tile("平均每次请求", value: summary.reportedCalls > 0 ? compact((summary.totalTokens ?? 0) / summary.reportedCalls) : "–",
                 detail: "\(summary.calls) 次请求")
            Divider()
            tile("缓存命中率", value: summary.cacheHitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–",
                 detail: "读取缓存比重新输入便宜")
            Divider()
            tile("回传完整度", value: summary.calls > 0 ? "\(Int((Double(summary.reportedCalls) / Double(summary.calls) * 100).rounded()))%" : "–",
                 detail: "\(summary.reportedCalls) / \(summary.calls) 次有用量")
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func tile(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().tracking(-0.3)
            Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }.padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Bar: Identifiable {
        let day: Date
        let agent: ClipAgent
        let tokens: Int
        var id: String { "\(day.timeIntervalSince1970)-\(agent.rawValue)" }
    }

    private var bars: [Bar] {
        buckets.flatMap { day in
            ClipAgent.allCases.compactMap { agent in
                day.agents[agent]?.totalTokens.map { Bar(day: day.day, agent: agent, tokens: $0) }
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text(weekly ? "每周用量，按 Agent" : "每天用量，按 Agent").font(.caption).foregroundStyle(.secondary)
                ForEach(ClipAgent.allCases) { agent in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(UsageDashboard.color(for: agent)).frame(width: 10, height: 10)
                        Text(agent.name)
                        Text(compact(agentTotal(agent))).monospacedDigit().foregroundStyle(.primary)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart(bars) { bar in
                BarMark(x: .value("日期", bar.day, unit: weekly ? .weekOfYear : .day),
                        y: .value("Token", bar.tokens))
                    .foregroundStyle(by: .value("Agent", bar.agent.name))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale([ClipAgent.claude.name: UsageDashboard.color(for: .claude), ClipAgent.codex.name: UsageDashboard.color(for: .codex),
                                        ClipAgent.opencode.name: UsageDashboard.color(for: .opencode), ClipAgent.cursor.name: UsageDashboard.color(for: .cursor)])
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let tokens = value.as(Int.self) { Text(compact(tokens)).font(.caption2) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: weekly ? 6 : 7)) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true).font(.caption2)
                }
            }
            .frame(height: 170)
            .accessibilityLabel("按\(weekly ? "周" : "天")的 Token 用量柱状图")
        }
    }

    private func agentTotal(_ agent: ClipAgent) -> Int? {
        let values = buckets.compactMap { $0.agents[agent]?.totalTokens }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var composition: some View {
        let parts: [(String, Int?, Color)] = [
            ("输入", summary.inputTokens, Color(hex: 0x2A78D6)),
            ("输出", summary.outputTokens, Color(hex: 0x104281)),
            ("缓存读取", summary.cachedReadTokens, Color(hex: 0x86B6EF)),
            ("缓存写入", summary.cachedWriteTokens, Color(hex: 0x5598E7))
        ]
        let total = max(1, parts.compactMap(\.1).reduce(0, +))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("构成").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(total.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        let share = Double(part.1 ?? 0) / Double(total)
                        if share > 0 {
                            RoundedRectangle(cornerRadius: 2).fill(part.2)
                                .frame(width: max(2, (geometry.size.width - 6) * share))
                                .overlay { if share >= 0.09 { Text("\(Int((share * 100).rounded()))%").font(.system(size: 10, weight: .medium)).foregroundStyle(.white) } }
                        }
                    }
                }
            }.frame(height: 14)
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(part.2).frame(width: 10, height: 10)
                            Text(part.0).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(part.1?.formatted() ?? "未记录").font(.caption).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var table: some View {
        ScrollView {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("日期").gridColumnAlignment(.leading)
                    ForEach(ClipAgent.allCases) { Text($0.name) }
                    Text("合计"); Text("回传")
                }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Divider()
                ForEach(buckets.reversed()) { day in
                    GridRow {
                        Text(day.day, format: .dateTime.month(.defaultDigits).day()).gridColumnAlignment(.leading)
                        ForEach(ClipAgent.allCases) { Text(day.agents[$0]?.totalTokens?.formatted() ?? "–") }
                        Text(day.total.totalTokens?.formatted() ?? "–")
                        Text("\(day.total.reportedCalls)/\(day.total.calls)")
                    }.font(.caption).monospacedDigit()
                }
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }.frame(maxHeight: 320)
    }

    static func color(for agent: ClipAgent) -> Color {
        switch agent {
        case .claude: Color(hex: 0xEB6834)
        case .codex: Color(hex: 0x2A78D6)
        case .opencode: Color(hex: 0x1BAF7A)
        case .cursor: Color(hex: 0x4A3AA7)
        }
    }

    private func compact(_ value: Int?) -> String {
        guard let value else { return "未记录" }
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", Double(value) / 1e9)
        case 10_000_000...: return "\(value / 1_000_000)M"
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1e6)
        case 1_000...: return "\(value / 1_000)K"
        default: return "\(value)"
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
