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
    @State private var configurationModelAgent: ClipAgent?
    @StateObject private var history = OrganizationHistoryState()
    @State private var windowVisible = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("自动整理", selection: $model.organizationSection) {
                ForEach(OrganizationSection.allCases) { section in
                    Text(section == .status && !model.permissions.isEmpty ? "\(section.title) · \(model.permissions.count)" : section.title).tag(section)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: 400).padding(.horizontal, 24).padding(.vertical, 16)
            .accessibilityIdentifier("organization.navigation")
            Divider()
            // Do not keep hidden charts, history lists or their tasks alive in a TabView/ZStack.
            switch model.organizationSection {
            case .status:
                ScrollView {
                    runtimeSection.padding(24).frame(maxWidth: 920).frame(maxWidth: .infinity, alignment: .top)
                }.accessibilityIdentifier("organization.status")
            case .history:
                OrganizationHistoryView(model: model, state: history, visible: windowVisible) { selectedJob = $0 }
            case .usage:
                ScrollView {
                    usageSection.padding(24).frame(maxWidth: 920).frame(maxWidth: .infinity, alignment: .top)
                }
                .accessibilityIdentifier("organization.usage")
                .task(id: windowVisible) { if windowVisible { await model.refreshTokenUsageIfNeeded() } }
            }
        }
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
        VStack(alignment: .leading, spacing: 22) {
            ForEach(model.permissions) { permission in PermissionRequestView(model: model, permission: permission) }
            HStack(spacing: 12) {
                if let agent = model.preferences.enabledAgent {
                    AgentBrandIcon(agent: agent, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name).font(.headline)
                        Button { selectedModelAgent = agent } label: {
                            Text(model.state(agent).modelSelection.current?.name ?? model.preferences.selectedModel(for: agent) ?? String(localized: "Agent 默认模型"))
                                .lineLimit(1).truncationMode(.middle)
                        }.buttonStyle(.link).font(.callout).disabled(!model.canConfigureAgentModel(agent))
                    }
                } else {
                    Label("选择一个 Agent 来整理截图与记忆。", systemImage: "person.crop.circle").foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Agent 与账号…") { showingAgentConfiguration = true }
                    .accessibilityIdentifier("organization.agent-configuration")
            }
            BackstageCard {
                VStack(alignment: .leading, spacing: 16) {
                    Label(runtimeTitle, systemImage: runtimeWarning ? "exclamationmark.circle" : model.currentJob == nil ? "circle.dotted" : "arrow.triangle.2.circlepath")
                        .font(.title3.weight(.semibold)).foregroundStyle(runtimeWarning ? Color.orange : Color.primary)
                    if let job = model.currentJob {
                        BackstageClock(running: true) { model.organizationActivity(at: $0) }.font(.callout).foregroundStyle(.secondary)
                        if model.processingPaused { Text("当前批次完成后暂停。").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("查看本次详情") { selectedJob = job }
                            Button("停止本次", role: .destructive) { model.cancel(job) }.disabled(model.preview)
                        }
                    } else if model.discoveringTasks {
                        Text(model.taskDiscoveryMessage ?? String(localized: "正在识别工作任务")).font(.callout).foregroundStyle(.secondary)
                    } else if let reason = model.library.queue.pauseReason {
                        Text(reason).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    } else if let agent = model.preferences.enabledAgent, model.state(agent).phase == .failed {
                        Text(model.state(agent).detail).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        if model.agentRetryAt[agent] != nil {
                            Text("将按退避时间自动重试。").font(.caption).foregroundStyle(.secondary)
                        } else { Button("重试连接") { model.connect(agent) }.disabled(model.preview) }
                    } else if model.preferences.enabledAgent == nil {
                        Button("选择 Agent…") { showingAgentConfiguration = true }.buttonStyle(.borderedProminent)
                    } else if let agent = model.preferences.enabledAgent,
                              model.state(agent).phase == .connecting || model.state(agent).phase == .installing {
                        Text(model.state(agent).detail).font(.callout).foregroundStyle(.secondary)
                    } else if model.library.queue.pendingCount > 0 || model.processingPaused {
                        BackstageClock(running: !model.processingPaused && model.library.queue.readyAt != nil) { model.organizationStatus(at: $0) }
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Text("待整理 \(model.library.queue.pendingCount) 张截图").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.preferences.enabledAgent != nil { HStack(spacing: 10) { queueActions } }
            if model.taskIngestionSummary.failedCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Label("部分任务线索仍待补处理。", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    Button("重试任务识别") { model.retryTaskIngestionFailures() }.disabled(!model.canStartOrganization)
                }
            }
            if model.currentJob == nil, let completed = model.library.jobs.first(where: { $0.state == .completed }) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近完成").font(.caption).foregroundStyle(.secondary)
                        Text(organizationOutcome(completed)).font(.callout)
                        Text(completed.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("查看结果") { selectedJob = completed }
                }
            }
            Button("查看全部执行记录") { model.organizationSection = .history }.buttonStyle(.link)
            DisclosureGroup("整理规则") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("按截图时间先后整理，自动整理之间至少间隔 5 分钟。")
                    Text("最多 8 张截图。")
                    Text("回车、鼠标和手动截图都将原图交给 Agent；OCR 文字只用于本机搜索和原文查看。")
                    Text(dreamHelp)
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
        }
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
                .buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
                .disabled(model.preview || model.preferences.enabledAgent == nil)
                .help("用同一个 Agent 重新整理失败的那批，然后继续队列")
        } else if model.processingPaused {
            Button(String(localized: "继续整理"), systemImage: "play.fill") { model.processingPaused = false }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(model.preview)
        } else {
            Button(String(localized: "整理记忆"), systemImage: "moon.stars", action: model.dreamNow).controlSize(.small).disabled(!model.canDreamNow)
                .help(dreamHelp)
            Button("立即整理", action: model.organizeNow).controlSize(.small).disabled(!model.canOrganizeNow)
                .help("不等间隔，马上整理下一批")
            Button(String(localized: "暂停"), systemImage: "pause.fill") { model.processingPaused = true }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.preview || model.preferences.enabledAgent == nil)
                .help("停止分配新批次，当前批次会先完成")
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Token 用量").font(.title3.weight(.semibold))
                    .help("只统计 Agent 回传的部分")
                Spacer()
                Picker("范围", selection: $usageRange) {
                    ForEach(UsageRange.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 170)
            }
            if let error = model.tokenUsageLoadError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Button("重试") { Task { await model.refreshTokenUsageIfNeeded() } }
            } else if !model.tokenUsageLoaded {
                ProgressView("正在读取用量…").frame(maxWidth: .infinity).padding(32)
            } else {
                BackstageCard { UsageDashboard(statistics: model.tokenUsage, days: usageRange.days, asTable: $usageAsTable) }
            }
        }
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
        return String(localized: "较前 \(days) 天 \(change >= 0 ? "+" : "")\(change)%")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tiles
            Divider()
            HStack {
                Text("只统计 Agent 回传的部分").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Token 用量", selection: $asTable) {
                    Text("图表").tag(false)
                    Text("表格").tag(true)
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 110)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            if summary.calls == 0 {
                Text(days == nil ? String(localized: "还没有回传过用量。任务结束后会在这里汇总。") : String(localized: "这段时间没有整理任务。"))
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if asTable {
                table
            } else {
                chart.padding(.horizontal, 14).padding(.bottom, 12)
                Divider()
                composition.padding(.horizontal, 14).padding(.vertical, 12)
            }
            Divider()
            Text("含截图整理、任务识别和重试。旧任务和没有回传用量的请求不计入；缓存明细为已回传部分。")
                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tiles: some View {
        HStack(spacing: 0) {
            tile(days.map { String(localized: "近 \($0) 天 Token") } ?? String(localized: "累计 Token"), value: compact(summary.totalTokens),
                 detail: deltaText ?? (days == nil ? String(localized: "\(summary.calls) 次请求") : String(localized: "全部 \(statistics.total.totalTokens?.formatted() ?? String(localized: "未记录"))")))
            Divider()
            tile(String(localized: "平均每次请求"), value: summary.reportedCalls > 0 ? compact((summary.totalTokens ?? 0) / summary.reportedCalls) : "–",
                 detail: String(localized: "\(summary.calls) 次请求"))
            Divider()
            tile(String(localized: "缓存命中率"), value: summary.cacheHitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–",
                 detail: String(localized: "读取缓存比重新输入便宜"))
            Divider()
            tile(String(localized: "回传完整度"), value: summary.calls > 0 ? "\(Int((Double(summary.reportedCalls) / Double(summary.calls) * 100).rounded()))%" : "–",
                 detail: String(localized: "\(summary.reportedCalls) / \(summary.calls) 次有用量"))
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func tile(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }.padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .help(detail).accessibilityElement(children: .combine).accessibilityHint(detail)
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

    private var axisDates: [Date] {
        let dates = Set(bars.map { weekly ? calendar.dateInterval(of: .weekOfYear, for: $0.day)?.start ?? $0.day : $0.day }).sorted()
        let step = max(1, Int(ceil(Double(dates.count) / 7)))
        return dates.enumerated().compactMap { index, date in index % step == 0 || index == dates.count - 1 ? date : nil }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(weekly ? String(localized: "每周用量，按 Agent") : String(localized: "每天用量，按 Agent")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(ClipAgent.allCases) { agent in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(UsageDashboard.color(for: agent)).frame(width: 10, height: 10)
                        Text(agent.name)
                        Text(compact(agentTotal(agent))).monospacedDigit().foregroundStyle(.primary)
                    }.font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Chart(bars) { bar in
                BarMark(x: .value(String(localized: "日期"), bar.day, unit: weekly ? .weekOfYear : .day),
                        y: .value("Token", bar.tokens))
                    .foregroundStyle(by: .value("Agent", bar.agent.rawValue))
                    .cornerRadius(3)
            }
            // Keep the categorical domain complete and stable. A partial four-agent palette
            // causes Charts to trap when WorkBuddy or Qwen Work contributes a bar.
            .chartForegroundStyleScale(domain: ClipAgent.allCases.map(\.rawValue),
                                       range: ClipAgent.allCases.map { UsageDashboard.color(for: $0) })
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let tokens = value.as(Int.self) { Text(compact(tokens)).font(.caption2) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: axisDates) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day()).font(.caption2)
                }
            }
            .frame(height: 130)
            .accessibilityLabel("按\(weekly ? String(localized: "周") : String(localized: "天"))的 Token 用量柱状图")
            .accessibilityIdentifier("backstage.usage.chart")
        }
    }

    private func agentTotal(_ agent: ClipAgent) -> Int? {
        let values = buckets.compactMap { $0.agents[agent]?.totalTokens }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var composition: some View {
        let parts: [(String, Int?, Color)] = [
            (String(localized: "输入"), summary.inputTokens, Color(hex: 0x2A78D6)),
            (String(localized: "输出"), summary.outputTokens, Color(hex: 0x104281)),
            (String(localized: "缓存读取"), summary.cachedReadTokens, Color(hex: 0x86B6EF)),
            (String(localized: "缓存写入"), summary.cachedWriteTokens, Color(hex: 0x5598E7))
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
                        Text(part.1?.formatted() ?? String(localized: "未记录")).font(.caption).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
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
        }.frame(maxHeight: 240).accessibilityIdentifier("backstage.usage.table")
    }

    static func color(for agent: ClipAgent) -> Color {
        switch agent {
        case .claude: Color(hex: 0xEB6834)
        case .codex: Color(hex: 0x2A78D6)
        case .opencode: Color(hex: 0x1BAF7A)
        case .cursor: Color(hex: 0x4A3AA7)
        case .workbuddy: .teal
        case .qwenwork: .indigo
        }
    }

    private func compact(_ value: Int?) -> String {
        guard let value else { return String(localized: "未记录") }
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
