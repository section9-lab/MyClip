import Accessibility
import Charts
import SwiftUI
import Combine
import MyClipCore

/// One utility entry with three independently mounted destinations: live status, history and usage.
struct BackstageView: View {
    @ObservedObject var model: MyClipModel
    @State private var selectedJob: ClipJob?
    @State private var selectedModelAgent: ClipAgent?
    @State private var usageRange = UsageRange.month
    @State private var usageAsTable = false
    @State private var showingAgentConfiguration = false
    @State private var showingRules = false
    @State private var configurationModelAgent: ClipAgent?
    @StateObject private var history = OrganizationHistoryState()
    @State private var windowVisible = false
    @State private var liveRecords: [ExecutionRecord] = []
    @State private var liveToolFilter: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            // Do not keep hidden charts, history lists or their tasks alive in a TabView/ZStack.
            switch model.organizationSection {
            case .status:
                VStack(spacing: 0) {
                    ScrollView {
                        runtimeSection.padding(20).frame(maxWidth: 920).frame(maxWidth: .infinity, alignment: .top)
                    }
                    .onChange(of: toolNames) { names in
                        if let filter = liveToolFilter, !names.contains(filter) { liveToolFilter = nil }
                    }
                    Divider()
                    runtimeFooter
                }
                .accessibilityIdentifier("organization.status")
                .task(id: "\(model.currentJob?.id.uuidString ?? "-")|\(windowVisible)") { await watchLiveTools() }
            case .history:
                OrganizationHistoryView(model: model, state: history, visible: windowVisible) { selectedJob = $0 }
            case .usage:
                ScrollView {
                    usageSection.padding(20).frame(maxWidth: 920).frame(maxWidth: .infinity, alignment: .top)
                }
                .accessibilityIdentifier("organization.usage")
                .task(id: windowVisible) { if windowVisible { await model.refreshTokenUsageIfNeeded() } }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(BackstageWindowActivity(active: $windowVisible, requiresActive: false).frame(width: 0, height: 0))
        .onAppear { model.organizationUIVisible = windowVisible }
        .onChange(of: windowVisible) { model.organizationUIVisible = $0 }
        .onDisappear { model.organizationUIVisible = false }
        .sheet(item: $selectedJob) { ExecutionDetailView(model: model, job: $0) }
        .sheet(item: $selectedModelAgent) { AgentModelPickerView(model: model, agent: $0) }
        .sheet(isPresented: $showingAgentConfiguration) {
            VStack(spacing: 0) {
                HStack {
                    Text("Agent 与账号").font(.title3.weight(.semibold))
                    Spacer()
                    Button("完成") { showingAgentConfiguration = false }.keyboardShortcut(.cancelAction)
                }.padding(20)
                Divider()
                ScrollView { agentsSection.padding(20) }
            }
            .frame(minWidth: 560, idealWidth: 680, minHeight: 400, idealHeight: 600)
            .onAppear { model.refreshAgentAvailability() }
            .sheet(item: $configurationModelAgent) { AgentModelPickerView(model: model, agent: $0) }
        }
    }

    // MARK: - Header

    private var sectionSubtitle: String {
        switch model.organizationSection {
        case .status: String(localized: "查看任务队列与 Agent 的最新进展")
        case .history: String(localized: "每次整理的执行记录与结果")
        case .usage: String(localized: "只统计 Agent 回传的 Token 用量")
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    headerTitle
                    Spacer(minLength: 16)
                    headerControls
                }
                VStack(alignment: .leading, spacing: 12) {
                    headerTitle
                    headerControls
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 16)
            Divider()
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "Backstage").font(.system(size: 24, weight: .semibold))
            Text(sectionSubtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var headerControls: some View {
        HStack(spacing: 10) {
            Picker("Backstage", selection: $model.organizationSection) {
                ForEach(OrganizationSection.allCases) { section in
                    Text(section == .status && !model.permissions.isEmpty ? "\(section.title) · \(model.permissions.count)" : section.title).tag(section)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
            .accessibilityIdentifier("organization.navigation")
            if model.organizationSection == .status {
                Button { showingRules.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain).font(.title3).foregroundStyle(.secondary)
                .accessibilityLabel(Text("整理规则"))
                .help("查看整理规则")
                .popover(isPresented: $showingRules, arrowEdge: .bottom) {
                    rulesPopover
                }
            }
        }
    }

    // MARK: - Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("整理 Agent").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 144), spacing: 8)], spacing: 8) {
                ForEach(ClipAgent.allCases) { agent in agentCard(agent) }
            }
        }
    }

    private func agentCard(_ agent: ClipAgent) -> some View {
        let state = model.state(agent)
        let enabled = model.preferences.enabledAgent == agent
        let availability = model.localAgents[agent] ?? .missing
        let installing = model.agents.values.contains { $0.phase == .installing }
        let selecting = model.selectingDefaultAgent != nil
        return VStack(spacing: 6) {
            AgentBrandIcon(agent: agent, size: 28).frame(height: 28)
            Text(agent.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
            phaseChip(state, enabled: enabled, availability: availability).frame(height: 20)
            if model.runtime.usesAccountBridge(agent, customPath: model.preferences.path(for: agent)) {
                Text("运行组件由 MyClip 管理").font(.caption2).foregroundStyle(.secondary)
                if let account = state.account {
                    Text(account.account).font(.caption).textSelection(.enabled)
                    Text(account.plan).font(.caption2).foregroundStyle(.secondary)
                    if let used = account.creditsUsed, let total = account.creditsTotal {
                        Text(String(localized: "额度：\(used.formatted()) / \(total.formatted())"))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if let remaining = account.creditsRemaining {
                        Text(String(localized: "剩余额度：\(remaining.formatted())"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let description = agentDescription(agent, state: state, enabled: enabled, availability: availability) {
                Text(description)
                    .font(.caption).foregroundStyle(state.phase == .failed ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !state.available, !state.authMethods.isEmpty {
                VStack(spacing: 6) {
                    Text("登录方式").font(.caption).foregroundStyle(.secondary)
                    ForEach(state.authMethods) { method in
                        Button(method.name) { model.authenticate(agent, method: method) }.disabled(state.busy)
                    }
                }.controlSize(.small)
            }
            if model.authorizingAccounts.contains(agent) {
                Button("取消授权") { model.cancelAccountAuthorization(agent) }.controlSize(.small)
            }
            Button { configurationModelAgent = agent } label: {
                VStack(spacing: 2) {
                    Text("模型").foregroundStyle(.secondary)
                    Text(state.modelSelection.current?.name ?? model.preferences.selectedModel(for: agent) ?? String(localized: "选择模型…"))
                        .lineLimit(1).truncationMode(.middle)
                }.font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!availability.hasConnector || !model.canConfigureAgentModel(agent) || installing || selecting)
            .accessibilityLabel(String(localized: "选择 \(agent.name) 的模型"))
            .help(!availability.hasConnector ? String(localized: "请先连接 \(agent.name)，再选择模型")
                  : state.busy ? String(localized: "请等待当前整理结束后再切换模型。") : String(localized: "从 Agent 获取可用模型，应用到后续整理会话"))
            Spacer(minLength: 2)
            Group {
                if enabled {
                    Menu {
                        if state.phase == .failed { Button("重试连接") { model.connect(agent) } }
                        else { Button("重新连接") { model.connect(agent) }.disabled(state.busy) }
                        if model.hasLoginCommand(agent) { Button("复制登录命令") { model.copyLoginCommand(for: agent) } }
                        if model.runtime.usesAccountBridge(agent, customPath: model.preferences.path(for: agent)) {
                            Button("重新授权账号") { model.reauthorizeAccount(agent) }.disabled(state.busy)
                            Button("刷新账号额度") { model.refreshAgentAccount(agent) }.disabled(state.busy)
                        }
                        Divider()
                        Button("停用", role: .destructive) { model.disableAgent() }
                    } label: { Text("当前使用").foregroundStyle(Color.accentColor) }
                        .menuStyle(.borderedButton).fixedSize()
                        .disabled(model.preview).help("重新连接、复制登录命令或停用")
                } else if state.busy || model.selectingDefaultAgent == agent {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.selectDefaultAgent(agent) } } label: {
                        Text(useLabel(state, availability: availability)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .disabled(model.preview || !availability.canSelect || installing || selecting)
                    .help(availability.canSelect ? String(localized: "把后续截图交给 \(agent.name) 整理") : availability.detail)
                }
            }.controlSize(.small).frame(height: 24)
        }
        .multilineTextAlignment(.center)
        .padding(10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 132, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
            if enabled { RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.04)) }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(enabled ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1)))
        .overlay(alignment: .topTrailing) {
            if enabled {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    .padding(7).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(agent.name)
        .accessibilityValue(state.detail)
        .accessibilityAddTraits(enabled ? .isSelected : [])
    }

    private func useLabel(_ state: ClipAgentState, availability: LocalAgentAvailability) -> String {
        if state.available { return String(localized: "使用") }
        return availability.hasConnector || availability == .desktopEngine || availability == .accountSetup ? String(localized: "连接并使用") : String(localized: "安装并使用")
    }

    @ViewBuilder private func phaseChip(_ state: ClipAgentState, enabled: Bool, availability: LocalAgentAvailability) -> some View {
        switch state.phase {
        case .working: StatusChip(String(localized: "整理中"), tone: .accent)
        case .connecting: StatusChip(String(localized: "连接中"), tone: .neutral)
        case .installing: StatusChip(String(localized: "安装组件"), tone: .neutral)
        case .permission: StatusChip(String(localized: "等待确认"), tone: .warning)
        case .failed: StatusChip(String(localized: "出错"), tone: .warning)
        case .ready: StatusChip(String(localized: "已连接"), tone: .good)
        case .disconnected:
            if availability == .accountSetup { StatusChip(String(localized: "待连接"), tone: .neutral) }
            else if availability == .desktopOnly { StatusChip(String(localized: "已检测到桌面端"), tone: .neutral) }
            else if !availability.canSelect { StatusChip(String(localized: "未检测到"), tone: .neutral) }
            else if enabled { StatusChip(String(localized: "待连接"), tone: .neutral) }
            else if availability == .desktopConnector || availability == .desktopEngine { StatusChip(String(localized: "已检测到桌面引擎"), tone: .neutral) }
        }
    }

    private func agentDescription(_ agent: ClipAgent, state: ClipAgentState, enabled: Bool, availability: LocalAgentAvailability) -> String? {
        if state.phase == .failed {
            if model.agentRetryAt[agent] == nil, let job = model.latestFailedJob, job.agent == agent, let error = job.error { return error }
            return state.detail.hasSuffix("。") ? state.detail : state.detail + "。"
        }
        if model.runtime.usesAccountBridge(agent, customPath: model.preferences.path(for: agent)) {
            guard state.account == nil else { return nil }
            return availability == .accountSetup
                ? String(localized: "首次连接将自动准备运行组件，无需预装其他软件。")
                : String(localized: "登录你的产品账号，读取该账号的模型和额度。")
        }
        if state.phase == .disconnected, enabled, !model.processingPaused,
           let retrying = model.jobAwaitingRetry, retrying.agent == agent, let error = retrying.error {
            return String(localized: "\(error) 第 \(retrying.attempts + 1) 次尝试排队中。")
        }
        switch (availability, agent) {
        case (.missing, .codex): return String(localized: "没有找到 Codex 命令行。安装 Codex 桌面端或命令行后再来连接。")
        case (.missing, _): return String(localized: "没有找到 \(agent.cliName) 命令行。安装后再来连接。")
        case (.desktopOnly, _): return String(localized: "已安装桌面端，MyClip 尚未接入其自动整理接口。")
        case (.desktopEngine, _): return String(localized: "使用桌面应用内置引擎，首次连接会自动准备连接组件。")
        case (.accountSetup, _): return String(localized: "首次连接将自动准备运行组件，无需预装其他软件。")
        case (.desktopConnector, _): return String(localized: "使用桌面应用内置引擎。")
        case (.commandLine, _), (.connector, _): return nil
        }
    }

    // MARK: - Runtime status

    private var runtimeTitle: String {
        if let job = model.currentJob {
            return job.kind == .dream ? String(localized: "正在整理已有记忆") : String(localized: "正在整理 \(job.sourceIDs.count) 张截图")
        }
        if model.discoveringTasks { return String(localized: "正在识别任务") }
        guard let agent = model.preferences.enabledAgent else { return String(localized: "尚未选择 Agent") }
        if !model.permissions.isEmpty { return String(localized: "等待你的确认") }
        if model.library.queue.pauseReason != nil || model.state(agent).phase == .failed { return String(localized: "整理需要处理") }
        if model.processingPaused { return String(localized: "自动整理已暂停") }
        if model.state(agent).phase == .connecting || model.state(agent).phase == .installing { return String(localized: "正在准备 Agent") }
        return model.library.queue.pendingCount > 0 ? String(localized: "等待下一批整理") : String(localized: "空闲，等待新截图")
    }

    private var runtimeWarning: Bool {
        model.library.queue.pauseReason != nil || !model.permissions.isEmpty
            || model.preferences.enabledAgent.map { model.state($0).phase == .failed } == true
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(model.permissions) { permission in PermissionRequestView(model: model, permission: permission) }
            OrganizationFlowView(model: model) { showingAgentConfiguration = true }
            runtimeCard
            if model.taskIngestionSummary.failedCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Label("部分任务线索仍待补处理。", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    Button("重试任务识别") { model.retryTaskIngestionFailures() }.disabled(!model.canStartOrganization)
                }
            }
        }
    }

    private var runtimeCard: some View {
        BackstageCard {
            VStack(alignment: .leading, spacing: 16) {
                runtimeSummary
                if let job = model.currentJob {
                    runtimeProgress(job)
                } else {
                    runtimeIdleDetail
                }
                executionWindow
                if model.currentJob != nil || runtimeFailure {
                    Divider()
                    runtimeActions()
                }
            }.padding(18)
        }
        .onAppear { model.refreshAgentAvailability() }
    }

    private var runtimeFailure: Bool {
        model.preferences.enabledAgent.map { model.state($0).phase == .failed } == true
    }

    private var runtimeSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                runtimeGlyph
                runtimeIdentity
                Spacer(minLength: 12)
                runtimeControls
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    runtimeGlyph
                    runtimeIdentity
                }
                runtimeControls
            }
        }
    }

    @ViewBuilder private var runtimeGlyph: some View {
        if model.currentJob != nil, windowVisible {
            ProgressView().controlSize(.small).frame(width: 22, height: 22).padding(.top, 2)
                .accessibilityLabel(Text("正在整理"))
        } else {
            Image(systemName: model.currentJob != nil ? "circle.dotted" : runtimeWarning ? "exclamationmark.circle" : "clock")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(runtimeWarning ? Color.orange : Color.secondary)
                .frame(width: 22, height: 22).padding(.top, 3)
                .accessibilityHidden(true)
        }
    }

    private var runtimeIdentity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(runtimeTitle).font(.title3.weight(.semibold)).lineLimit(2)
            HStack(spacing: 6) {
                if let agent = model.preferences.enabledAgent {
                    Text(agent.name)
                    Text("·")
                    Text(agentModelName(agent))
                    if let apps = sourceApps {
                        Text("·")
                        Text(apps)
                    }
                } else {
                    Text("还没有选择整理 Agent")
                }
            }
            .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private func agentModelName(_ agent: ClipAgent) -> String {
        model.state(agent).modelSelection.current?.name ?? model.preferences.selectedModel(for: agent)
            ?? String(localized: "Agent 默认模型")
    }

    /// Apps whose screenshots this batch carries, from the real captures rather than the Agent's reply.
    private var sourceApps: String? {
        guard let job = model.currentJob, job.kind == .batch else { return nil }
        let ids = Set(job.sourceIDs)
        var seen = Set<String>()
        let names = model.library.captures.filter { ids.contains($0.id) }.map(\.appName).filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return nil }
        return names.prefix(2).joined(separator: "、")
    }

    private var runtimeControls: some View {
        HStack(spacing: 8) {
            Text("Agent").font(.caption).foregroundStyle(.secondary)
            agentMenu
            StatusChip(runtimeStatusText, tone: runtimeStatusTone)
        }
    }

    private var agentMenu: some View {
        Menu {
            Section("Agent") {
                ForEach(ClipAgent.allCases) { agent in
                    Button {
                        Task { await model.selectDefaultAgent(agent) }
                    } label: {
                        if agent == model.preferences.enabledAgent { Label(agent.name, systemImage: "checkmark") }
                        else { Text(agent.name) }
                    }
                    .disabled(agent == model.preferences.enabledAgent || model.preview || model.selectingDefaultAgent != nil
                              || !(model.localAgents[agent]?.canSelect ?? false))
                }
            }
            Divider()
            if let agent = model.preferences.enabledAgent {
                Button("选择模型…") { selectedModelAgent = agent }
                    .disabled(!model.canConfigureAgentModel(agent) || model.preview)
            }
            Button("Agent 与账号…") { showingAgentConfiguration = true }
                .accessibilityIdentifier("organization.agent-configuration")
        } label: {
            Text(model.preferences.enabledAgent?.name ?? String(localized: "选择 Agent")).lineLimit(1)
        }
        .menuStyle(.borderedButton)
        .controlSize(.small)
        .fixedSize()
        .disabled(model.preview)
        .accessibilityLabel(Text("整理 Agent"))
    }

    private var runtimeStatusText: String {
        if model.currentJob != nil { return String(localized: "进行中") }
        if model.discoveringTasks { return String(localized: "识别任务") }
        if !model.permissions.isEmpty { return String(localized: "待确认") }
        guard let agent = model.preferences.enabledAgent else { return String(localized: "未选择") }
        if model.library.queue.pauseReason != nil { return String(localized: "需处理") }
        if model.state(agent).phase == .failed { return String(localized: "出错") }
        if model.processingPaused { return String(localized: "已暂停") }
        if model.state(agent).phase == .connecting || model.state(agent).phase == .installing { return String(localized: "准备中") }
        return model.library.queue.pendingCount > 0 ? String(localized: "等待中") : String(localized: "空闲")
    }

    private var runtimeStatusTone: StatusChip.Tone {
        if model.currentJob != nil { return .good }
        if model.discoveringTasks { return .accent }
        if !model.permissions.isEmpty || model.library.queue.pauseReason != nil { return .warning }
        if let agent = model.preferences.enabledAgent, model.state(agent).phase == .failed { return .warning }
        return .neutral
    }

    private func runtimeProgress(_ job: ClipJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(spacing: 6) {
                    Text(job.kind == .dream ? String(localized: "整理已有记忆") : String(localized: "\(job.sourceIDs.count) 张截图"))
                    Text("·")
                    Text(model.activityText.isEmpty ? String(localized: "正在准备…") : model.activityText)
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                BackstageClock(running: true) { date in
                    guard let started = model.currentJobStartedAt ?? model.currentJob?.createdAt else { return "" }
                    return Self.elapsedText(date.timeIntervalSince(started))
                }
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
            FlowProgressBar(running: windowVisible)
            if model.processingPaused {
                Text("当前批次完成后暂停。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func elapsedText(_ interval: TimeInterval) -> String {
        let elapsed = max(0, Int(interval))
        if elapsed >= 3600 {
            return String(localized: "已用时 \(elapsed / 3600) 时 \(elapsed % 3600 / 60) 分")
        }
        return String(localized: "已用时 \(elapsed / 60) 分 \(elapsed % 60) 秒")
    }

    @ViewBuilder private var runtimeIdleDetail: some View {
        if model.discoveringTasks {
            Text(model.taskDiscoveryMessage ?? String(localized: "正在识别工作任务"))
                .font(.callout).foregroundStyle(.secondary)
        } else if let reason = model.library.queue.pauseReason {
            Text(reason).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let agent = model.preferences.enabledAgent, model.state(agent).phase == .failed {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.state(agent).detail).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                if model.agentRetryAt[agent] != nil {
                    Text("将按退避时间自动重试。").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if model.preferences.enabledAgent == nil {
            HStack(spacing: 10) {
                Label("选择一个 Agent 来整理截图与记忆。", systemImage: "person.crop.circle").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("选择 Agent…") { showingAgentConfiguration = true }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        } else if let agent = model.preferences.enabledAgent,
                  model.state(agent).phase == .connecting || model.state(agent).phase == .installing {
            Text(model.state(agent).detail).font(.callout).foregroundStyle(.secondary)
        } else if model.library.queue.pendingCount > 0 || model.processingPaused {
            BackstageClock(running: !model.processingPaused && model.library.queue.readyAt != nil) { model.organizationStatus(at: $0) }
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("没有待整理的截图。").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func runtimeActions() -> some View {
        HStack(spacing: 8) {
            if let job = model.currentJob {
                Button { selectedJob = job } label: { Label("查看本次详情", systemImage: "list.bullet") }
                    .buttonStyle(.bordered)
                Button { model.cancel(job) } label: { Text("停止本次").foregroundStyle(.red) }
                    .buttonStyle(.bordered)
                    .disabled(model.preview)
            } else if let agent = model.preferences.enabledAgent, model.state(agent).phase == .failed {
                Button("重试连接") { model.connect(agent) }.buttonStyle(.bordered).disabled(model.preview)
            }
            Spacer(minLength: 12)
            if model.currentJob != nil {
                HStack(spacing: 4) {
                    Text("最近更新")
                    Text(model.lastActivityAt, format: .dateTime.hour().minute().second()).monospacedDigit()
                }.font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var runtimeFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                queueSummary
                Spacer(minLength: 12)
                if model.preferences.enabledAgent != nil { HStack(spacing: 8) { queueActions } }
            }
            VStack(alignment: .leading, spacing: 10) {
                queueSummary
                if model.preferences.enabledAgent != nil {
                    HStack(spacing: 8) { Spacer(minLength: 0); queueActions }
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var queueSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("待整理 \(model.library.queue.pendingCount.formatted()) 张截图").font(.callout.weight(.semibold))
            Text(footerDetail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var footerDetail: String {
        var parts: [String] = []
        if let job = model.currentJob {
            parts.append(job.kind == .dream ? String(localized: "正在整理已有记忆") : String(localized: "其中 \(job.sourceIDs.count) 张正在整理"))
        }
        if let latest = model.library.captures.first {
            parts.append(String(localized: "最近保存于 \(latest.date.formatted(date: .omitted, time: .shortened))"))
        }
        return parts.isEmpty ? String(localized: "还没有截图") : parts.joined(separator: " · ")
    }

    private var executionWindow: some View {
        VStack(spacing: 0) {
            executionHeader
            Divider()
            if !visibleToolRows.isEmpty {
                executionTableHeader
                Divider()
                ForEach(Array(visibleToolRows.enumerated()), id: \.element.id) { index, row in
                    toolRow(row)
                    if index < visibleToolRows.count - 1 { Divider().padding(.leading, 14) }
                }
            } else if let completed = model.library.jobs.first(where: { $0.state == .completed }) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(organizationOutcome(completed)).font(.callout)
                        Text(completed.createdAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("查看结果") { selectedJob = completed }
                }.padding(14)
            } else {
                Text(model.currentJob == nil ? String(localized: "暂无执行动态") : String(localized: "等待 Agent 的最新动态…"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var executionHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                executionTitle
                Spacer(minLength: 12)
                executionFilters
                allRecordsButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { executionTitle; Spacer(minLength: 8); allRecordsButton }
                executionFilters
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.primary.opacity(0.035))
    }

    private var executionTitle: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").font(.caption).foregroundStyle(.secondary)
            Text("执行状态").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(toolRows.count) 条").font(.caption).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var executionFilters: some View {
        if !toolRows.isEmpty {
            HStack(spacing: 6) {
                toolFilterChip(String(localized: "全部"), value: nil)
                ForEach(toolNames.prefix(5), id: \.self) { name in
                    toolFilterChip(name, value: name)
                }
            }
        }
    }

    private func toolFilterChip(_ title: String, value: String?) -> some View {
        let active = liveToolFilter == value
        return Button { liveToolFilter = value } label: {
            Text(title).font(.caption.weight(active ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(active ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var allRecordsButton: some View {
        Button("全部执行记录") { model.organizationSection = .history }
            .buttonStyle(.link).font(.caption)
    }

    private var executionTableHeader: some View {
        HStack(spacing: 10) {
            Text("时间").frame(width: 54, alignment: .leading)
            Text("工具").frame(width: 66, alignment: .leading)
            Text("目标").frame(maxWidth: .infinity, alignment: .leading)
            Text("耗时").frame(width: 52, alignment: .trailing)
        }
        .font(.caption).foregroundStyle(.tertiary)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
        .accessibilityHidden(true)
    }

    private func toolRow(_ row: LiveToolRow) -> some View {
        HStack(spacing: 10) {
            Text(row.date, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(row.name)
                .font(.caption.weight(.medium)).foregroundStyle(toolTint(row.name))
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(toolTint(row.name).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                .frame(width: 66, alignment: .leading)
            Text(row.target.isEmpty ? String(localized: "—") : row.target)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle)
                .help(row.target)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(durationText(row.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else { return "—" }
        if duration < 1 { return "\(max(1, Int(duration * 1000)))ms" }
        if duration < 10 { return String(format: "%.1fs", duration) }
        return "\(Int(duration.rounded()))s"
    }

    private struct LiveToolRow: Identifiable {
        let id: String
        let date: Date
        let name: String
        let target: String
        let duration: TimeInterval?
    }

    /// Persisted tool calls are richer than the four in-memory activity rows, so they drive the table.
    private var toolRows: [LiveToolRow] {
        let records = liveRecords.flatMap(\.tools).sorted { $0.startedAt < $1.startedAt }
        if records.isEmpty {
            return model.liveActivities.map { activity in
                let pieces = activity.text.components(separatedBy: " · ")
                return LiveToolRow(
                    id: activity.id.uuidString, date: activity.date,
                    name: activity.isResponse ? String(localized: "回复") : (pieces.count > 1 ? pieces[0] : String(localized: "进度")),
                    target: activity.text.isEmpty ? String(localized: "正在生成回答…")
                        : (pieces.count > 1 ? pieces.dropFirst().joined(separator: " · ") : activity.text),
                    duration: nil)
            }
        }
        var seen = Set<String>()
        return records.compactMap { tool in
            let key = "\(tool.id)-\(tool.startedAt.timeIntervalSince1970)"
            guard seen.insert(key).inserted else { return nil }
            let elapsed = tool.updatedAt.timeIntervalSince(tool.startedAt)
            return LiveToolRow(id: key, date: tool.startedAt, name: toolName(tool), target: toolTarget(tool),
                               duration: elapsed >= 0.05 ? elapsed : nil)
        }
    }

    private var visibleToolRows: [LiveToolRow] {
        let rows = liveToolFilter.map { filter in toolRows.filter { $0.name == filter } } ?? toolRows
        return Array(rows.suffix(8))
    }

    private var toolNames: [String] {
        var names: [String] = []
        for row in toolRows where !names.contains(row.name) { names.append(row.name) }
        return names
    }

    private func toolName(_ tool: ACPToolCall) -> String {
        let name = (tool.name ?? tool.kind).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "工具") : name.lowercased()
    }

    private func toolTarget(_ tool: ACPToolCall) -> String {
        if let path = tool.locations.first?.path { return abbreviated(path) }
        if let path = tool.content.compactMap(\.path).first { return abbreviated(path) }
        let title = tool.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title.caseInsensitiveCompare(tool.name ?? "") != .orderedSame { return title }
        return "—"
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func toolTint(_ name: String) -> Color {
        switch name.lowercased() {
        case "think", "thinking", "thought": return .purple
        case "read", "view", "open": return .blue
        case "bash", "execute", "run", "shell", "command": return .orange
        case "search", "grep", "glob", "find": return .green
        case "write", "edit", "patch", "apply_patch": return .indigo
        case "回复", "进度": return .gray
        default: return .teal
        }
    }

    private func watchLiveTools() async {
        liveRecords = []
        liveToolFilter = nil
        guard windowVisible, let id = model.currentJob?.id else { return }
        while !Task.isCancelled, windowVisible, model.currentJob?.id == id {
            if let next = try? await model.store.executionRecords(jobID: id),
               next.flatMap(\.tools) != liveRecords.flatMap(\.tools) {
                liveRecords = next
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private var rulesPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("整理规则").font(.headline)
            Text("按截图时间先后整理，自动整理之间至少间隔 5 分钟。")
            Text("最多 8 张截图。")
            Text("回车、鼠标和手动截图都将原图交给 Agent；OCR 文字只用于本机搜索和原文查看。")
            Text(dreamHelp)
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(20).frame(width: 340, alignment: .leading)
    }

    /// What the dream button does, since “dream” alone does not say it.
    private var dreamHelp: String {
        if model.library.jobs.contains(where: { $0.kind == .dream && ($0.state == .queued || $0.state == .running) }) {
            return String(localized: "已经有一次做梦在队列里，完成后才能再整理。")
        }
        return String(localized: "让 Agent 现在做一次梦：不读新截图，回头整理已有的记忆。它会把放错的页面归位、合并重复内容、清理已经过期的当前状态、补充别名，并轮流巡检一段时间没看过的页面。平时每天凌晨 \(MemoryDream.dayStartHour) 点后，等队列空闲、你离开电脑 \(Int(MemoryDream.idleInterval / 60)) 分钟时会自动做一次；手动整理后当天不再自动进行。")
    }

    @ViewBuilder private var queueActions: some View {
        let queue = model.library.queue
        if queue.pauseReason != nil {
            Button(String(localized: "重试并继续"), systemImage: "arrow.clockwise") { model.resumeAfterFailure() }
                .buttonStyle(.borderedProminent).tint(.orange)
                .disabled(model.preview || model.preferences.enabledAgent == nil)
                .help("用同一个 Agent 重新整理失败的那批，然后继续队列")
        } else if model.processingPaused {
            Button(String(localized: "继续整理"), systemImage: "play.fill") { model.processingPaused = false }
                .buttonStyle(.borderedProminent).disabled(model.preview)
        } else {
            Button(String(localized: "整理记忆"), systemImage: "moon.stars", action: model.dreamNow).disabled(!model.canDreamNow)
                .help(dreamHelp)
            Button(String(localized: "暂停"), systemImage: "pause.fill") { model.processingPaused = true }
                .buttonStyle(.bordered).disabled(model.preview || model.preferences.enabledAgent == nil)
                .help("停止分配新批次，当前批次会先完成")
            Button(String(localized: "立即整理"), systemImage: "play.fill", action: model.organizeNow).disabled(!model.canOrganizeNow)
                .help("不等间隔，马上整理下一批")
        }
    }

    // MARK: - Usage

    private enum UsageRange: String, CaseIterable, Identifiable {
        case week, month, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .week: String(localized: "7 天")
            case .month: String(localized: "30 天")
            case .all: String(localized: "全部")
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
        VStack(alignment: .leading, spacing: 14) {
            if let error = model.tokenUsageLoadError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Button("重试") { Task { await model.refreshTokenUsageIfNeeded() } }
            } else if !model.tokenUsageLoaded {
                ProgressView("正在读取用量…").frame(maxWidth: .infinity).padding(32)
            } else {
                BackstageCard {
                    UsageDashboard(
                        statistics: model.tokenUsage, days: usageRange.days, asTable: $usageAsTable,
                        rangeSelection: Binding(
                            get: { usageRange.days },
                            set: { value in usageRange = UsageRange.allCases.first { $0.days == value } ?? .month }
                        )
                    )
                }
            }
        }
    }

}

/// The four stages a capture passes through. Every value comes from the library or the Agent.
private struct OrganizationFlowView: View {
    @ObservedObject var model: MyClipModel
    let selectAgent: () -> Void

    private var latestCapture: ClipCapture? { model.library.captures.first }

    /// The newest real movement: a fresh capture, or Agent activity while a batch runs.
    private var latestFlowDate: Date? {
        var dates: [Date] = []
        if let capture = latestCapture { dates.append(capture.date) }
        if model.currentJob != nil { dates.append(model.lastActivityAt) }
        return dates.max()
    }

    private var agentStatus: String {
        if !model.permissions.isEmpty { return String(localized: "等待确认") }
        if model.library.queue.pauseReason != nil { return String(localized: "需要处理") }
        if let agent = model.preferences.enabledAgent, model.state(agent).phase == .failed { return String(localized: "出错") }
        if model.currentJob != nil { return String(localized: "整理中") }
        if model.processingPaused { return String(localized: "已暂停") }
        return model.preferences.enabledAgent == nil ? String(localized: "未选择") : String(localized: "等待中")
    }

    private var statusColor: Color {
        if !model.permissions.isEmpty || model.library.queue.pauseReason != nil { return .orange }
        if let agent = model.preferences.enabledAgent, model.state(agent).phase == .failed { return .red }
        return model.currentJob == nil ? .secondary : .green
    }

    private var captureDetail: String {
        guard model.preferences.captureEnabled else { return String(localized: "采集已暂停") }
        guard let latestCapture else { return String(localized: "等待第一张截图") }
        return "\(model.library.captureCount.formatted()) 张 · \(latestCapture.date.formatted(date: .omitted, time: .standard))"
    }

    private var organizedCount: Int {
        max(0, model.library.captureCount - model.library.queue.pendingCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("整理流程").font(.headline)
                    Text("从最近截图到长期记忆，共四个环节").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if let latestFlowDate {
                    HStack(spacing: 4) {
                        Text("最近流转")
                        Text(latestFlowDate, format: .dateTime.hour().minute().second()).monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                    .accessibilityElement(children: .combine)
                }
            }
            BackstageCard {
                HStack(spacing: 0) {
                    step(String(localized: "最近截图"), detail: captureDetail, tint: .gray) {
                        if let capture = latestCapture {
                            CaptureThumbnail(capture: capture).clipShape(RoundedRectangle(cornerRadius: 7))
                        } else {
                            Image(systemName: "photo")
                        }
                    }
                    stepDivider
                    step(String(localized: "待整理队列"), detail: String(localized: "\(model.library.queue.pendingCount.formatted()) 张等待"),
                         tint: model.library.queue.pendingCount > 0 ? .accentColor : .gray) {
                        Image(systemName: "square.stack.3d.up")
                    }
                    stepDivider
                    Button(action: selectAgent) {
                        step(model.preferences.enabledAgent?.name ?? String(localized: "Agent"), detail: agentStatus,
                             detailColor: statusColor, tint: model.currentJob != nil ? .green : .gray, showsDot: true) {
                            if let agent = model.preferences.enabledAgent {
                                AgentBrandIcon(agent: agent, size: 20)
                            } else {
                                Image(systemName: "person.crop.circle.badge.questionmark")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Agent 与账号…")
                    .accessibilityLabel(Text("Agent 与账号"))
                    .accessibilityValue(Text("\(model.preferences.enabledAgent?.name ?? String(localized: "未选择")) · \(agentStatus)"))
                    stepDivider
                    step(String(localized: "Memory"), detail: String(localized: "已整理 \(organizedCount.formatted()) 张"), tint: .gray) {
                        Image(systemName: "doc.text")
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func step<Icon: View>(_ title: String, detail: String, detailColor: Color = .secondary,
                                  tint: Color, showsDot: Bool = false, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 10) {
            icon()
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 4) {
                    if showsDot { Circle().fill(detailColor).frame(width: 5, height: 5).accessibilityHidden(true) }
                    Text(detail).font(.caption).foregroundStyle(detailColor).lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepDivider: some View {
        Divider().frame(height: 40).accessibilityHidden(true)
    }
}

/// History owns its filters, pagination and cancellation separately from the live runtime surface.
@MainActor final class OrganizationHistoryState: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all, open, done, failed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "全部状态")
            case .open: String(localized: "未完成")
            case .done: String(localized: "已完成")
            case .failed: String(localized: "失败")
            }
        }
        var states: [ClipJobState] {
            switch self {
            case .all: []
            case .open: [.queued, .running, .failed]
            case .done: [.completed]
            case .failed: [.failed]
            }
        }
    }
    enum Period: String, CaseIterable, Identifiable {
        case all, today, week, month
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "全部时间")
            case .today: String(localized: "今天")
            case .week: String(localized: "7 天")
            case .month: String(localized: "30 天")
            }
        }
        func since(now: Date = Date(), calendar: Calendar = .current) -> Date? {
            if self == .all { return nil }
            return calendar.date(byAdding: .day, value: self == .today ? 0 : self == .week ? -6 : -29,
                                 to: calendar.startOfDay(for: now))
        }
    }
    struct Key: Equatable { let agent: ClipAgent?; let filter: Filter; let period: Period }
    struct Request: Equatable { let key: Key; let page: Int; let revision: Int; let recent: [ClipJob]; let version: String? }
    @Published var agent: ClipAgent?
    @Published var filter = Filter.all
    @Published var period = Period.all
    @Published private(set) var rows: [ClipJob] = []
    @Published private(set) var hasMore = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private var page = 0
    @Published private var revision = 0
    private var loaded: Request?
    private var loadingID: UUID?
    private let pageSize = 50

    func request(recent: [ClipJob], version: String? = nil) -> Request {
        Request(key: Key(agent: agent, filter: filter, period: period), page: page, revision: revision, recent: recent, version: version)
    }
    func nextPage() {
        guard !loading, hasMore, let loaded else { return }
        page = loaded.page + 1
    }
    func reload() { revision &+= 1 }
    func load(store: LibraryStore, recent: [ClipJob], version: String? = nil) async {
        let request = request(recent: recent, version: version)
        guard loaded != request || error != nil else { return }
        let keyChanged = loaded?.key != request.key
        let reset = keyChanged || loaded?.recent != recent || loaded?.revision != revision || loaded?.version != version
        // A live job update refreshes all already loaded pages, preserving older rows and scroll context.
        let targetPage = reset ? (keyChanged || loaded?.revision != revision ? 0 : loaded?.page ?? 0) : request.page
        let id = UUID()
        loadingID = id
        loading = true
        error = nil
        if keyChanged { rows = [] }
        defer { if loadingID == id { loading = false } }
        do {
            var refreshed: [ClipJob] = reset ? [] : rows
            var known = Set(refreshed.map(\.id))
            var more = false
            var finalPage = 0
            let since = request.key.period.since()
            for index in (reset ? 0 : targetPage)...targetPage {
                try Task.checkCancellation()
                let found = try await store.organizationHistory(limit: pageSize + 1, offset: index * pageSize,
                    agent: request.key.agent, states: request.key.filter.states, since: since)
                try Task.checkCancellation()
                guard loadingID == id, request.key == self.request(recent: recent, version: version).key else { return }
                refreshed.append(contentsOf: found.prefix(pageSize).filter { known.insert($0.id).inserted })
                more = found.count > pageSize
                finalPage = index
                if !more { break }
            }
            rows = refreshed
            hasMore = more
            loaded = Request(key: request.key, page: finalPage, revision: request.revision, recent: recent, version: version)
            if page != finalPage { page = finalPage }
        } catch is CancellationError { return }
        catch { if loadingID == id { self.error = error.localizedDescription } }
    }
}

struct OrganizationHistoryView: View {
    @ObservedObject var model: MyClipModel
    @ObservedObject var state: OrganizationHistoryState
    var visible = true
    let select: (ClipJob) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Agent", selection: $state.agent) {
                    Text("全部 Agent").tag(Optional<ClipAgent>.none)
                    ForEach(ClipAgent.allCases) { Text($0.name).tag(Optional($0)) }
                }
                Picker("状态", selection: $state.filter) {
                    ForEach(OrganizationHistoryState.Filter.allCases) { Text($0.title).tag($0) }
                }
                Picker("时间", selection: $state.period) {
                    ForEach(OrganizationHistoryState.Period.allCases) { Text($0.title).tag($0) }
                }
                Spacer(minLength: 0)
                Button { state.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新").accessibilityLabel("刷新执行记录").disabled(state.loading)
            }.pickerStyle(.menu).labelsHidden().padding(20)
            Divider()
            if let error = state.error {
                HStack {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).lineLimit(2)
                    Spacer()
                    Button("重试") { state.reload() }
                }.font(.callout).padding(16)
            }
            if state.rows.isEmpty {
                if state.loading { ProgressView("正在读取执行记录…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    LibraryUnavailableView(String(localized: "没有符合筛选条件的记录。"), systemImage: "clock",
                                           description: Text("调整筛选条件，或等待第一次整理完成。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // One native list, not a fixed-height scrolling list nested inside a scrolling page.
                List {
                    ForEach(state.rows) { job in row(job).id(job.id) }
                    if state.hasMore {
                        HStack {
                            Spacer()
                            Button("加载更多") { state.nextPage() }.disabled(state.loading)
                            Spacer()
                        }.padding(.vertical, 8)
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
            HStack {
                Text("\(state.rows.count) 条已加载").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if state.loading && !state.rows.isEmpty { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 20).padding(.vertical, 10)
        }
        .accessibilityIdentifier("organization.history")
        .task(id: visible ? state.request(recent: model.library.jobs, version: model.organizationHistoryVersion) : nil) {
            if visible { await state.load(store: model.store, recent: model.library.jobs, version: model.organizationHistoryVersion) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in state.reload() }
    }

    private func row(_ job: ClipJob) -> some View {
        HStack(spacing: 12) {
            Button { select(job) } label: {
                HStack(spacing: 12) {
                    JobIcon(job: job, size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(job.kind == .dream ? String(localized: "整理已有记忆") : String(localized: "整理 \(job.sourceIDs.count) 张截图"))
                                .font(.callout.weight(.medium))
                            StatusChip(jobLabel(job), tone: job.state == .failed ? .warning : job.state == .completed ? .good : .neutral)
                        }
                        Text(organizationOutcome(job)).font(.caption).foregroundStyle(job.state == .failed ? Color.orange : .secondary).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(job.agent.name)
                            Text("·")
                            Text(job.createdAt, format: .dateTime.month().day().hour().minute())
                        }.font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(organizationOutcome(job))
            if job.state == .failed {
                Button("重试") { model.retry(job) }.controlSize(.small).disabled(!model.canRetry(job))
                    .help(model.canRetry(job) ? String(localized: "重新整理这批素材") : String(localized: "请先选择并连接 \(job.agent.name)，重试会继续使用原 Agent"))
            } else if job.state == .running || job.state == .queued {
                Button("取消") { model.cancel(job) }.controlSize(.small).disabled(model.preview)
            }
        }.padding(.vertical, 8)
    }
}

func organizationOutcome(_ job: ClipJob) -> String {
    switch job.state {
    case .completed:
        guard let changes = job.memoryChanges else { return String(localized: "已完成；未记录实际文件变更。") }
        return changes.count == 0 ? String(localized: "已整理，Memory 无需更新") : String(localized: "已更新 \(changes.count) 个 Memory 文件")
    case .failed: return job.error ?? String(localized: "未完成")
    case .cancelled: return job.kind == .dream ? String(localized: "已停止，明天会再做") : String(localized: "素材已回到队列")
    case .running: return String(localized: "正在处理，可打开详情查看进度。")
    case .queued: return job.error ?? String(localized: "排队中")
    }
}

/// Every Agent uses its own live ACP catalog; no model IDs are bundled into the app.
struct AgentModelPickerView: View {
    @ObservedObject var model: MyClipModel
    let agent: ClipAgent
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var state: ClipAgentState { model.state(agent) }
    private var selectedID: String? { model.preferences.selectedModel(for: agent) }
    private var busy: Bool { !model.canConfigureAgentModel(agent) }
    private var options: [ACPModelOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.modelSelection.options.filter {
            query.isEmpty || [$0.id, $0.name, $0.group ?? "", $0.description ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "\(agent.name) 模型")).font(.title3.weight(.semibold))
                Spacer()
                if model.configuringAgentModels.contains(agent) { ProgressView().controlSize(.small) }
                Button("刷新列表") { Task { await model.loadAgentModels(agent, refresh: true) } }.disabled(busy)
            }
            Text("按 Agent 分别保存，应用到后续整理会话。列表由 Agent 实时提供。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let current = state.modelSelection.currentID {
                Text(String(localized: "当前会话：\(current)"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = state.modelError {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel(String(localized: "模型设置失败：\(error)"))
            }
            if !state.available, !state.authMethods.isEmpty {
                HStack {
                    ForEach(state.authMethods) { method in
                        Button(method.name) { model.authenticate(agent, method: method) }.disabled(busy)
                    }
                    if model.authorizingAccounts.contains(agent) {
                        Button("取消授权") { model.cancelAccountAuthorization(agent) }
                    }
                }.controlSize(.small)
            }
            if state.modelSelection.current?.supportsImages == false {
                Text("当前模型不支持图片，请选择支持图片的模型后整理截图。")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            TextField("搜索模型名称或 ID", text: $search).textFieldStyle(.roundedBorder)
            List {
                Button { choose(nil) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("跟随 Agent 默认").foregroundStyle(.primary)
                            Text("使用新会话的默认模型，不修改 Agent 全局设置").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedID == nil { Text("已选择").font(.caption).foregroundStyle(Color.accentColor) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.disabled(busy || !state.modelsLoaded)
                    .accessibilityAddTraits(selectedID == nil ? .isSelected : [])
                ForEach(options) { option in
                    Button { choose(option.id) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.name).foregroundStyle(.primary)
                                Text(option.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let group = option.group { Text(group).font(.caption).foregroundStyle(.secondary) }
                                if let description = option.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(capability(option)).font(.caption).foregroundStyle(option.supportsImages == false ? Color.orange : .secondary)
                                if selectedID == option.id { Text("已选择").font(.caption).foregroundStyle(Color.accentColor) }
                            }
                        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .disabled(busy || option.supportsImages == false)
                    .accessibilityAddTraits(selectedID == option.id ? .isSelected : [])
                    .help(option.supportsImages == false ? String(localized: "此模型不支持图片，无法整理截图。") : option.id)
                }
                if state.modelsLoaded && state.modelSelection.options.isEmpty {
                    Text("Agent 未提供可选模型，请先在 Agent 中设置或更新其连接组件。")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                } else if !state.modelsLoaded && !model.configuringAgentModels.contains(agent) && state.modelError == nil {
                    Text("等待连接 Agent 获取模型列表").foregroundStyle(.secondary)
                } else if !state.modelSelection.options.isEmpty && options.isEmpty {
                    Text("没有匹配的模型").foregroundStyle(.secondary)
                }
            }.buttonStyle(.borderless)
            Text(state.busy && !model.configuringAgentModels.contains(agent)
                 ? String(localized: "请等待当前整理结束后再切换模型。")
                 : String(localized: "图片能力未知的模型需以实际调用结果为准；不会自动切换到其他模型。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(minWidth: 520, idealWidth: 580, maxWidth: 680, minHeight: 480, idealHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.loadAgentModels(agent) }
    }

    private func choose(_ id: String?) {
        Task { await model.selectAgentModel(agent, modelID: id) }
    }

    private func capability(_ option: ACPModelOption) -> String {
        switch option.supportsImages {
        case true: String(localized: "支持图片")
        case false: String(localized: "不支持图片")
        case nil: String(localized: "图片能力未知")
        }
    }
}

/// Only the small status text owns a clock. This app uses AppKit NSHostingView rather than a SwiftUI
/// Scene, so scenePhase alone cannot describe whether its particular window is visible and active.
private struct BackstageClock: View {
    let running: Bool
    let text: (Date) -> String
    @State private var visible = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !running || !visible)) { context in
            Text(text(context.date)).lineLimit(1).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BackstageWindowActivity(active: $visible).frame(width: 0, height: 0))
    }
}

private struct BackstageWindowActivity: NSViewRepresentable {
    @Binding var active: Bool
    var requiresActive = true
    func makeNSView(context: Context) -> Probe { Probe(active: $active, requiresActive: requiresActive) }
    func updateNSView(_ view: Probe, context: Context) { view.active = $active; view.requiresActive = requiresActive }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.observation?.cancel() }

    final class Probe: NSView {
        var active: Binding<Bool>
        var requiresActive: Bool
        var observation: AnyCancellable?
        init(active: Binding<Bool>, requiresActive: Bool) {
            self.active = active; self.requiresActive = requiresActive; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSApplication.didHideNotification, NSApplication.didUnhideNotification]
            observation = Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
                .sink { [weak self] _ in Task { @MainActor in self?.publish() } }
            Task { @MainActor [weak self] in self?.publish() }
        }
        private func publish() {
            let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            let value = visible && (!requiresActive || NSApp.isActive) && !NSApp.isHidden
            if active.wrappedValue != value { active.wrappedValue = value }
        }
    }
}

/// A working indicator without a fake percentage: the accent segment keeps moving while the Agent works.
/// A timeline, not a repeating animation, so it stops as soon as the window is hidden.
private struct FlowProgressBar: View {
    var running = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let segment = max(56, width * 0.28)
            let travel = max(0, width - segment)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                if reduceMotion || !running {
                    Capsule().fill(Color.accentColor).frame(width: segment)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                        Capsule().fill(Color.accentColor)
                            .frame(width: segment)
                            .offset(x: travel * (0.5 - 0.5 * cos(phase * 2 * .pi)))
                    }
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("整理进行中"))
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
    init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
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
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium)).foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// The row title: how many screenshots a batch carries, or that a dream reorganizes all of memory.
func jobTitle(_ job: ClipJob) -> String {
    job.kind == .dream ? String(localized: "做梦 · 整理记忆") : String(localized: "\(job.sourceIDs.count) 条素材")
}

func jobLabel(_ job: ClipJob) -> String {
    guard job.kind == .dream else { return jobLabel(job.state) }
    switch job.state {
    case .queued: return String(localized: "等待做梦")
    case .running: return String(localized: "做梦中")
    default: return jobLabel(job.state)
    }
}

/// What a dream covers, e.g. “12 页 · 巡检 8 页 · 周报 2026-W38”.
func dreamScope(_ plan: ConsolidationPlan) -> String {
    var parts: [String] = []
    let pages = plan.misfiled.count + plan.changed.count + plan.neighbours.count
    if pages > 0 { parts.append(String(localized: "整理 \(pages) 页")) }
    if !plan.patrol.isEmpty { parts.append(String(localized: "巡检 \(plan.patrol.count) 页")) }
    if let weekly = plan.weekly { parts.append(String(localized: "周报 \(((weekly.path as NSString).lastPathComponent as NSString).deletingPathExtension)")) }
    return parts.joined(separator: " · ")
}

func jobLabel(_ state: ClipJobState) -> String {
    switch state {
    case .queued: String(localized: "等待整理")
    case .running: String(localized: "整理中")
    case .completed: String(localized: "已完成")
    case .failed: String(localized: "未完成")
    case .cancelled: String(localized: "已取消")
    }
}

// MARK: - Usage dashboard

struct UsageDashboard: View {
    let statistics: TokenUsageStatistics
    let days: Int?
    @Binding var asTable: Bool
    private let rangeSelection: Binding<Int?>?
    @State private var selectedTrendDate: Date?

    init(statistics: TokenUsageStatistics, days: Int?, asTable: Binding<Bool>, rangeSelection: Binding<Int?>? = nil) {
        self.statistics = statistics
        self.days = days
        _asTable = asTable
        self.rangeSelection = rangeSelection
    }

    struct TrendPoint: Identifiable, Equatable {
        let date: Date
        let tokens: Int
        let calls: Int
        let agentTokens: [ClipAgent: Int]
        var id: Date { date }
    }

    private struct AgentTotal: Identifiable {
        let agent: ClipAgent
        let tokens: Int
        var id: ClipAgent { agent }
    }

    private var calendar: Calendar { .current }
    private var summary: TokenUsageSummary { statistics.summary(days: days) }
    private var buckets: [TokenUsageDay] {
        guard let days else { return statistics.history }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date())) ?? .distantPast
        return statistics.history.filter { $0.day >= start }
    }
    private var weekly: Bool { days == nil }
    private var dailyBuckets: [TokenUsageDay] {
        let end = calendar.startOfDay(for: Date())
        let start: Date
        if let days {
            start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        } else {
            start = statistics.history.first.map { calendar.startOfDay(for: $0.day) } ?? end
        }
        let count = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
        let existing = Dictionary(uniqueKeysWithValues: statistics.history.map { (calendar.startOfDay(for: $0.day), $0) })
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return existing[date] ?? TokenUsageDay(day: date)
        }
    }
    private var trendPoints: [TrendPoint] {
        Self.makeTrendPoints(from: dailyBuckets, weekly: weekly, calendar: calendar)
    }

    static func makeTrendPoints(from buckets: [TokenUsageDay], weekly: Bool, calendar: Calendar) -> [TrendPoint] {
        let groups = Dictionary(grouping: buckets) { bucket in
            weekly ? (calendar.dateInterval(of: .weekOfYear, for: bucket.day)?.start ?? bucket.day) : bucket.day
        }
        return groups.map { date, days in
            var agentTokens: [ClipAgent: Int] = [:]
            for day in days {
                for (agent, usage) in day.agents {
                    if let tokens = usage.totalTokens { agentTokens[agent, default: 0] += tokens }
                }
            }
            return TrendPoint(date: date, tokens: days.compactMap { $0.total.totalTokens }.reduce(0, +),
                              calls: days.reduce(0) { $0 + $1.total.calls }, agentTokens: agentTokens)
        }.sorted { $0.date < $1.date }
    }
    private var selectedPoint: TrendPoint? {
        guard let selectedTrendDate else { return nil }
        return trendPoints.first { $0.date == selectedTrendDate }
    }
    private var axisDates: [Date] {
        let dates = trendPoints.map(\.date)
        let step = max(1, Int(ceil(Double(dates.count) / 4)))
        return dates.enumerated().compactMap { index, date in
            index % step == 0 || index == dates.count - 1 ? date : nil
        }
    }
    private var trendUpperBound: Double { max(1, Double(trendPoints.map(\.tokens).max() ?? 0) * 1.12) }
    private var deltaValue: Int? {
        guard let days else { return nil }
        let previous = statistics.previousSummary(days: days)
        guard let now = summary.totalTokens, let before = previous.totalTokens, before > 0 else { return nil }
        return Int((Double(now - before) / Double(before) * 100).rounded())
    }
    private var deltaText: String? {
        guard let days, let change = deltaValue else { return nil }
        return String(localized: "较前 \(days) 天 \(change >= 0 ? "+" : "")\(change)%")
    }
    private var dateRangeText: String {
        guard let first = dailyBuckets.first?.day, let last = dailyBuckets.last?.day else { return "–" }
        return "\(first.formatted(.dateTime.year().month().day())) – \(last.formatted(.dateTime.year().month().day()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rangeSelection {
                HStack {
                    Spacer(minLength: 0)
                    Picker("范围", selection: rangeSelection) {
                        Text("7 天").tag(Int?.some(7))
                        Text("30 天").tag(Int?.some(30))
                        Text("全部").tag(Int?.none)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(maxWidth: 320)
                    .accessibilityLabel("范围")
                    Spacer(minLength: 0)
                }.padding(.horizontal, 18).padding(.top, 14)
            }
            hero.padding(.horizontal, 18).padding(.top, rangeSelection == nil ? 18 : 12).padding(.bottom, 14)
            Divider()
            if summary.calls == 0 {
                Text(days == nil ? String(localized: "还没有回传过用量。任务结束后会在这里汇总。") : String(localized: "这段时间没有整理任务。"))
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32)
            } else if summary.reportedCalls == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("这段时间的请求没有回传 Token 用量。").font(.callout)
                    Text("请求仍保留在执行记录中，图表不会推测缺失数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            } else if asTable {
                VStack(alignment: .leading, spacing: 12) {
                    trendHeader
                    table
                }.padding(18)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    trendHeader
                    chart
                    agentBreakdown
                }.padding(18)
                Divider()
                metrics.padding(18)
                Divider()
                composition.padding(18)
            }
            Divider()
            Text("含截图整理、任务识别和重试。旧任务和没有回传用量的请求不计入；缓存明细为已回传部分。")
                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.vertical, 11)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(days.map { String(localized: "近 \($0) 天 Token") } ?? String(localized: "累计 Token"))
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(compact(summary.totalTokens)).font(.system(size: 32, weight: .semibold)).monospacedDigit()
                Text("Token").font(.callout).foregroundStyle(.secondary)
                if let deltaText, let deltaValue {
                    Label(deltaText, systemImage: deltaValue >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }
            Text(dateRangeText).font(.callout).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                metric(String(localized: "平均每次请求"), value: summary.reportedCalls > 0 ? compact((summary.totalTokens ?? 0) / summary.reportedCalls) : "–",
                       detail: String(localized: "\(summary.reportedCalls) 次请求"))
                Divider().frame(height: 54).padding(.horizontal, 16)
                metric(String(localized: "缓存命中率"), value: summary.cacheHitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–",
                       detail: String(localized: "读取缓存比重新输入便宜"))
                Divider().frame(height: 54).padding(.horizontal, 16)
                metric(String(localized: "回传完整度"), value: summary.calls > 0 ? "\(Int((Double(summary.reportedCalls) / Double(summary.calls) * 100).rounded()))%" : "–",
                       detail: String(localized: "\(summary.reportedCalls) / \(summary.calls) 次有用量"))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 20)], alignment: .leading, spacing: 14) {
                metric(String(localized: "平均每次请求"), value: summary.reportedCalls > 0 ? compact((summary.totalTokens ?? 0) / summary.reportedCalls) : "–",
                       detail: String(localized: "\(summary.reportedCalls) 次请求"))
                metric(String(localized: "缓存命中率"), value: summary.cacheHitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–",
                       detail: String(localized: "读取缓存比重新输入便宜"))
                metric(String(localized: "回传完整度"), value: summary.calls > 0 ? "\(Int((Double(summary.reportedCalls) / Double(summary.calls) * 100).rounded()))%" : "–",
                       detail: String(localized: "\(summary.reportedCalls) / \(summary.calls) 次有用量"))
            }
        }
    }

    private func metric(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
        .help(detail).accessibilityElement(children: .combine).accessibilityHint(detail)
    }

    private var trendHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(weekly ? String(localized: "每周 Token 用量") : String(localized: "每日 Token 用量"))
                    .font(.headline)
                if let selectedPoint {
                    Text("\(selectedPoint.date.formatted(.dateTime.year().month().day())) · \(compact(selectedPoint.tokens)) Token · \(String(localized: "\(selectedPoint.calls) 次请求"))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(ClipAgent.allCases.compactMap { agent in
                        guard let tokens = selectedPoint.agentTokens[agent], tokens > 0 else { return nil }
                        return "\(agent.name) \(compact(tokens))"
                    }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("移动指针查看明细").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("Token 用量", selection: $asTable) {
                Text("图表").tag(false)
                Text("表格").tag(true)
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 110)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(trendPoints) { point in
                ForEach(ClipAgent.allCases) { agent in
                    if let tokens = point.agentTokens[agent], tokens > 0 {
                        BarMark(x: .value(String(localized: "日期"), point.date, unit: weekly ? .weekOfYear : .day),
                                y: .value("Token", tokens))
                            .foregroundStyle(by: .value("Agent", agent.rawValue))
                            .accessibilityLabel("\(point.date.formatted(.dateTime.year().month().day())) · \(agent.name)")
                            .accessibilityValue("\(tokens.formatted()) Token")
                    }
                }
            }
            if let selectedPoint {
                RuleMark(x: .value(String(localized: "日期"), selectedPoint.date))
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(domain: ClipAgent.allCases.map(\.rawValue), range: ClipAgent.allCases.map { Self.color(for: $0) })
        .chartLegend(.hidden)
        .chartXScale(range: .plotDimension(padding: 14))
        .chartYScale(domain: 0...trendUpperBound)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.17))
                AxisValueLabel {
                    if let tokens = value.as(Double.self) { Text(compact(Int(tokens))).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.secondary.opacity(0.14))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.month(.defaultDigits).day()).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in plot.background(Color.clear) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): updateSelection(at: location, proxy: proxy, geometry: geometry)
                        case .ended: selectedTrendDate = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        updateSelection(at: value.location, proxy: proxy, geometry: geometry)
                    })
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 210)
        .accessibilityChartDescriptor(UsageTrendDescriptor(
            points: trendPoints, weekly: weekly,
            title: weekly ? String(localized: "每周 Token 用量") : String(localized: "每日 Token 用量"),
            summary: "\(summary.totalTokens?.formatted() ?? String(localized: "未记录")) Token · \(String(localized: "\(summary.calls) 次请求"))"
        ))
        .accessibilityIdentifier("backstage.usage.chart")
    }

    private func updateSelection(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let frame = geometry[proxy.plotAreaFrame]
        guard frame.contains(location) else { selectedTrendDate = nil; return }
        let x = location.x - frame.origin.x
        guard let date: Date = proxy.value(atX: x) else { return }
        selectedTrendDate = trendPoints.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }?.date
    }

    private var agentTotals: [AgentTotal] {
        var values: [ClipAgent: Int] = [:]
        for bucket in buckets {
            for (agent, usage) in bucket.agents {
                if let tokens = usage.totalTokens { values[agent, default: 0] += tokens }
            }
        }
        return values.map { AgentTotal(agent: $0.key, tokens: $0.value) }
            .filter { $0.tokens > 0 }
            .sorted { lhs, rhs in lhs.tokens == rhs.tokens ? lhs.agent.rawValue < rhs.agent.rawValue : lhs.tokens > rhs.tokens }
    }

    @ViewBuilder private var agentBreakdown: some View {
        if !agentTotals.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Agent 用量").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(agentTotals.reduce(0) { $0 + $1.tokens }.formatted())
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], alignment: .leading, spacing: 8) {
                    ForEach(agentTotals) { value in
                        HStack(spacing: 7) {
                            Circle().fill(UsageDashboard.color(for: value.agent)).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(value.agent.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(compact(value.tokens)).font(.caption.weight(.medium)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(value.agent.name)
                        .accessibilityValue("\(value.tokens.formatted()) Token")
                    }
                }
            }
        }
    }

    private struct UsageTrendDescriptor: AXChartDescriptorRepresentable {
        let points: [TrendPoint]
        let weekly: Bool
        let title: String
        let summary: String

        func makeChartDescriptor() -> AXChartDescriptor {
            let labels = points.map { label(for: $0.date) }
            let maximum = max(1, points.map(\.tokens).max() ?? 0)
            let xAxis = AXCategoricalDataAxisDescriptor(title: String(localized: "日期"), categoryOrder: labels)
            let yAxis = AXNumericDataAxisDescriptor(title: "Token", range: 0...Double(maximum), gridlinePositions: []) {
                "\(Int($0).formatted()) Token"
            }
            let series = ClipAgent.allCases.filter { agent in
                points.contains { ($0.agentTokens[agent] ?? 0) > 0 }
            }.map { agent in
                AXDataSeriesDescriptor(
                    name: agent.name, isContinuous: false,
                    dataPoints: points.map { AXDataPoint(x: label(for: $0.date), y: Double($0.agentTokens[agent] ?? 0)) }
                )
            }
            return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis,
                                     additionalAxes: [], series: series)
        }

        private func label(for date: Date) -> String {
            date.formatted(weekly ? .dateTime.year().month().day() : .dateTime.month().day())
        }
    }

    private struct CompositionPart: Identifiable {
        let label: String
        let value: Int?
        let color: Color
        let symbol: String
        var id: String { label }
    }

    private var composition: some View {
        let parts = [
            CompositionPart(label: String(localized: "输入"), value: summary.inputTokens, color: .blue, symbol: "arrow.down.circle.fill"),
            CompositionPart(label: String(localized: "输出"), value: summary.outputTokens, color: .purple, symbol: "arrow.up.circle.fill"),
            CompositionPart(label: String(localized: "缓存读取"), value: summary.cachedReadTokens, color: .teal, symbol: "tray.and.arrow.down.fill"),
            CompositionPart(label: String(localized: "缓存写入"), value: summary.cachedWriteTokens, color: .indigo, symbol: "tray.and.arrow.up.fill")
        ]
        let recorded = parts.filter { ($0.value ?? 0) > 0 }
        let total = recorded.compactMap(\.value).reduce(0, +)
        let denominator = max(1, total)
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("构成").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(total.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let spacing = CGFloat(max(0, recorded.count - 1))
                HStack(spacing: 1) {
                    ForEach(recorded) { part in
                        let share = Double(part.value ?? 0) / Double(denominator)
                        Rectangle().fill(part.color)
                            .frame(width: max(1, (geometry.size.width - spacing) * share))
                    }
                }
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Token 构成")
                .accessibilityValue(recorded.map { "\($0.label) \(($0.value ?? 0).formatted())" }.joined(separator: "，"))
            }.frame(height: 16)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 18)], alignment: .leading, spacing: 9) {
                ForEach(parts) { part in
                    let value = part.value ?? 0
                    let share = Double(value) / Double(denominator)
                    HStack(spacing: 7) {
                        Image(systemName: part.symbol).foregroundStyle(part.color).accessibilityHidden(true)
                        Text(part.label).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(part.value?.formatted() ?? String(localized: "未记录")).font(.caption.weight(.medium)).monospacedDigit()
                            if part.value != nil { Text("\(Int((share * 100).rounded()))%").font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(part.label)
                    .accessibilityValue(part.value.map { "\($0.formatted()) Token，\(Int((share * 100).rounded()))%" } ?? String(localized: "未记录"))
                }
            }
        }
    }

    private var tableAgents: [ClipAgent] {
        ClipAgent.allCases.filter { agent in buckets.contains { ($0.agents[agent]?.calls ?? 0) > 0 } }
    }

    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("日期").gridColumnAlignment(.leading)
                    ForEach(tableAgents) { Text($0.name) }
                    Text("合计"); Text("回传")
                }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Divider()
                ForEach(buckets.reversed()) { day in
                    GridRow {
                        Text(day.day, format: .dateTime.month(.defaultDigits).day()).gridColumnAlignment(.leading)
                        ForEach(tableAgents) { Text(day.agents[$0]?.totalTokens?.formatted() ?? "–") }
                        Text(day.total.totalTokens?.formatted() ?? "–")
                        Text("\(day.total.reportedCalls)/\(day.total.calls)")
                    }.font(.caption).monospacedDigit()
                }
            }.padding(12)
        }
        .frame(minHeight: 150, maxHeight: 260)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("backstage.usage.table")
    }

    static func color(for agent: ClipAgent) -> Color {
        switch agent {
        case .claude: .orange
        case .codex: .blue
        case .opencode: .green
        case .cursor: .purple
        case .workbuddy: .teal
        case .qwenwork: .indigo
        }
    }

    private func compact(_ value: Int?) -> String {
        guard let value else { return String(localized: "未记录") }
        switch value {
        case 1_000_000_000...: return compactUnit(value, divisor: 1_000_000_000, suffix: "B")
        case 1_000_000...: return compactUnit(value, divisor: 1_000_000, suffix: "M")
        case 1_000...: return compactUnit(value, divisor: 1_000, suffix: "K")
        default: return value.formatted()
        }
    }

    private func compactUnit(_ value: Int, divisor: Int, suffix: String) -> String {
        let scaled = Double(value) / Double(divisor)
        return String(format: scaled >= 10 ? "%.0f%@" : "%.1f%@", scaled, suffix)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
