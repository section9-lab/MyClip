import AppKit
import Combine
import MyClipCore

@MainActor
final class ClipPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var enabledAgent: ClipAgent? { didSet { defaults.set(enabledAgent?.rawValue, forKey: "myclip.enabledAgent") } }
    @Published var autoOrganize: Bool { didSet { defaults.set(autoOrganize, forKey: "myclip.autoOrganize") } }
    @Published var captureSettings: CaptureSettings { didSet { captureSettings.save(to: defaults) } }
    @Published var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "myclip.retentionDays") } }
    @Published var excludedApps: String { didSet { defaults.set(excludedApps, forKey: "myclip.excludedApps") } }
    @Published var codexPath: String { didSet { defaults.set(codexPath, forKey: "myclip.codexPath") } }
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: "myclip.claudePath") } }
    @Published var mcpClients: Set<MCPClient> { didSet { defaults.set(mcpClients.map(\.rawValue).sorted(), forKey: "myclip.mcpClients") } }

    init(preview: Bool) {
        defaults = preview ? UserDefaults(suiteName: "MyClip.Preview")! : .standard
        enabledAgent = ClipAgent(rawValue: defaults.string(forKey: "myclip.enabledAgent") ?? "")
        autoOrganize = defaults.object(forKey: "myclip.autoOrganize") as? Bool ?? true
        captureSettings = CaptureSettings.load(from: defaults)
        retentionDays = defaults.object(forKey: "myclip.retentionDays") as? Int ?? 30
        excludedApps = defaults.string(forKey: "myclip.excludedApps") ?? "com.apple.Passwords\ncom.agilebits.onepassword7\ncom.1password.1password"
        codexPath = defaults.string(forKey: "myclip.codexPath") ?? ""
        claudePath = defaults.string(forKey: "myclip.claudePath") ?? ""
        mcpClients = defaults.stringArray(forKey: "myclip.mcpClients").map { Set($0.compactMap(MCPClient.init(rawValue:))) } ?? [.codex, .claudeCode]
    }

    func path(for agent: ClipAgent) -> String { agent == .codex ? codexPath : claudePath }
}

enum LibraryPage: String, CaseIterable, Identifiable {
    case memory, captures, dashboard, agents, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: "Kanban"
        case .memory: "Memory"
        case .captures: "Timeline"
        case .agents: "Backstage"
        case .settings: "设置"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: "rectangle.split.3x1"
        case .memory: "folder"
        case .captures: "rectangle.on.rectangle"
        case .agents: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}

struct ClipPermission: Identifiable {
    let agent: ClipAgent
    let request: ACPPermissionRequest
    var id: String { agent.rawValue + request.id }
}

enum MCPSetupResult {
    case configured
    case failed(String)
}

@MainActor
final class MyClipModel: ObservableObject {
    let store: LibraryStore
    let preferences: ClipPreferences
    let preview: Bool
    @Published var page: LibraryPage? = .captures
    @Published var search = "" {
        didSet {
            guard search != oldValue else { return }
            if oldValue.isEmpty { selectionBeforeSearch = (selectedEntry, memoryFolder) }
            if search.isEmpty {
                selectedEntry = selectionBeforeSearch?.entry
                memoryFolder = selectionBeforeSearch?.folder
                selectionBeforeSearch = nil
                if !captureFilter.isActive { results = library }
            } else {
                selectedEntry = nil
                memoryFolder = nil
            }
            scheduleSearch()
        }
    }
    @Published var library = LibrarySnapshot()
    @Published var results = LibrarySnapshot()
    @Published var captureFilter = CaptureFilter() {
        didSet { if captureFilter != oldValue { scheduleSearch() } }
    }
    @Published var selectedEntry: UUID?
    @Published var memoryFolder: String?
    @Published var selectedCapture: UUID?
    var memoryScrollOffsets: [UUID: CGFloat] = [:]
    @Published var capturing = false
    @Published var workTasks: [WorkTask] = []
    @Published var statistics = LibraryStatistics()
    @Published var tokenUsage = TokenUsageStatistics()
    @Published var workTaskEvents: [WorkTaskEvent] = []
    @Published var showingTaskReports = false
    @Published var discoveringTasks = false
    @Published var taskDiscoveryMessage: String?
    @Published var taskDiscoveryFailed = false
    @Published var updatingTaskIDs: Set<UUID> = []
    @Published var lastTaskReview: WorkTaskReview?
    @Published var proposals: [MemoryProposal] = []
    @Published var analyticsDays = 7 { didSet { Task { await refresh() } } }
    @Published var captureStatus = "正在准备采集"
    var processingPaused: Bool {
        get { library.queue.paused }
        set {
            Task {
                do { try await store.setOrganizationPaused(newValue); await refresh() }
                catch { notice = error.localizedDescription }
            }
        }
    }
    @Published private(set) var dispatching = false
    var canStartOrganization: Bool {
        guard let agent = preferences.enabledAgent else { return false }
        return !preview && !dispatching && currentJob == nil && !discoveringTasks && state(agent).phase == .ready
    }
    var canOrganizeNow: Bool {
        canStartOrganization && library.queue.pendingCount > 0 && library.queue.pauseReason == nil
            && library.queue.nextAgent == preferences.enabledAgent
    }
    var showPermissions: Bool { !preview && (!screenPermission || !accessibilityPermission) }
    @Published var screenPermission = false
    @Published var accessibilityPermission = false
    @Published var notice: String?
    @Published private(set) var mcpEnabled: Bool
    @Published private(set) var configuringMCP = false
    @Published private(set) var mcpSetupResults: [MCPClient: MCPSetupResult] = [:]
    @Published var agents: [ClipAgent: ClipAgentState] = [.codex: .init(), .claude: .init()]
    @Published private(set) var localAgents: [ClipAgent: LocalAgentAvailability] = [:]
    @Published private(set) var selectingDefaultAgent: ClipAgent?
    @Published var permissions: [ClipPermission] = []
    @Published var currentJob: ClipJob?
    @Published var activityText = "" { didSet { lastActivityAt = Date() } }
    private var currentJobStartedAt: Date?
    private var lastActivityAt = Date()
    var onOpenWindow: (() -> Void)?

    private let captureService = FocusedCaptureService()
    private let runtime: AgentRuntime
    private var clients: [ClipAgent: ACPClient] = [:]
    private var eventTasks: [ClipAgent: Task<Void, Never>] = [:]
    private var preferencesObservation: AnyCancellable?
    private var textWorker: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var selectionBeforeSearch: (entry: UUID?, folder: String?)?
    private var taskDiscovery: Task<Void, Never>?
    private var discoveryAgent: ClipAgent?
    private var cancelledJobs: Set<UUID> = []
    private var lastCleanup = Date.distantPast

    init(root: URL, preview: Bool) throws {
        self.preview = preview
        store = try LibraryStore(root: root)
        mcpEnabled = MemoryMCP.isEnabled(in: root)
        preferences = ClipPreferences(preview: preview)
        runtime = AgentRuntime(root: root.appendingPathComponent("Runtime"))
        captureService.onCapture = { [weak self] image, context in
            guard let self else { return }
            do {
                let repeated = self.library.captures.first?.imageID == image.fingerprint
                try await self.store.record(image: image, context: context, agent: self.preferences.enabledAgent ?? .codex, organize: self.preferences.autoOrganize)
                await self.refresh()
                self.captureStatus = repeated ? "已记录本次出现，相同画面共用原图" : "已保存 \(context.appName) · \(context.date.formatted(date: .omitted, time: .standard))"
            } catch { self.captureStatus = "保存失败：\(error.localizedDescription)"; self.notice = error.localizedDescription }
        }
        captureService.onStatus = { [weak self] status in self?.captureStatus = status }
        preferencesObservation = preferences.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if preview { captureStatus = "界面预览 · 采集已停用" }
        refreshPermissions()
    }

    func start() {
        guard worker == nil else { return }
        if !preview, let agent = preferences.enabledAgent { connect(agent) }
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.recoverInterruptedJobs()
                if preview { try await seedPreview() }
                await refresh()
                startTextRecognition()
                #if DEBUG
                if preview { try await previewPanelState() }
                #endif
            } catch { notice = error.localizedDescription }
            while !Task.isCancelled {
                refreshPermissions()
                if !preview {
                    await cleanupIfNeeded()
                    if !processingPaused { await processNext() }
                    await refresh()
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        refreshPermissions()
    }

    private func startTextRecognition() {
        textWorker?.cancel()
        textWorker = Task { [weak self] in
            var failed: Set<String> = []
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    if let image = try await store.nextImageForTextIndex(excluding: failed) {
                        do {
                            _ = try await store.recognizeImageText(id: image.id)
                            await refresh()
                        } catch is CancellationError { return }
                        catch { failed.insert(image.id) }
                    } else {
                        try await Task.sleep(for: .seconds(3))
                    }
                } catch is CancellationError { return }
                catch { return }
            }
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        captureService.stop()
        capturing = false
        textWorker?.cancel()
        searchTask?.cancel()
        taskDiscovery?.cancel()
        eventTasks.values.forEach { $0.cancel() }
        let runningClients = Array(clients.values)
        Task { for client in runningClients { await client.close() } }
    }

    func open(_ page: LibraryPage? = nil) {
        if let page { self.page = page }
        onOpenWindow?()
    }

    func state(_ agent: ClipAgent) -> ClipAgentState { agents[agent] ?? .init() }

    func isInstalled(_ agent: ClipAgent) -> Bool {
        runtime.command(for: agent, customPath: preferences.path(for: agent)) != nil
    }

    func refreshAgentAvailability() {
        localAgents = Dictionary(uniqueKeysWithValues: ClipAgent.allCases.map {
            ($0, runtime.availability(of: $0, customPath: preferences.path(for: $0)))
        })
    }

    func selectDefaultAgent(_ agent: ClipAgent) async {
        guard !preview, selectingDefaultAgent == nil, !state(agent).busy,
              !agents.values.contains(where: { $0.phase == .installing }) else { return }
        refreshAgentAvailability()
        guard localAgents[agent]?.canSelect == true else { return }
        selectingDefaultAgent = agent
        defer { selectingDefaultAgent = nil; refreshAgentAvailability() }
        do {
            if !isInstalled(agent) {
                agents[agent]?.phase = .installing
                agents[agent]?.detail = "正在安装连接组件…"
                try await runtime.install(agent)
            }
            _ = try await connectedClient(agent)
            enable(agent)
        } catch { setFailure(agent, error) }
    }

    func refreshPermissions() {
        screenPermission = captureService.hasScreenPermission
        accessibilityPermission = captureService.hasAccessibilityPermission
        guard !preview, worker != nil else { return }
        capturing = captureService.isRunning
        if !screenPermission || !accessibilityPermission {
            if capturing { captureService.stop() }
            capturing = false
            captureStatus = "等待屏幕录制和辅助功能权限，授权后将自动开始采集"
        } else if !capturing {
            applyCaptureSettings()
            capturing = captureService.start()
        }
    }

    func requestScreenPermission() { captureService.requestScreenPermission(); refreshPermissions() }
    func requestAccessibilityPermission() { captureService.requestAccessibilityPermission(); refreshPermissions() }

    func applyCaptureSettings() {
        let excluded = Set(preferences.excludedApps.split(whereSeparator: { $0.isNewline || $0 == "," }).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
        captureService.configure(settings: preferences.captureSettings, excludedBundleIDs: excluded)
    }

    func refresh() async {
        do {
            if let agent = preferences.enabledAgent { try await store.reassignPendingCaptures(to: agent) }
            library = try await store.snapshot()
            proposals = try await store.proposals()
            statistics = try await store.statistics(since: analyticsDays == 0 ? .distantPast : Calendar.current.date(byAdding: .day, value: -analyticsDays, to: Date())!)
            tokenUsage = try await store.tokenUsageStatistics()
            workTasks = try await store.workTasks()
            workTaskEvents = try await store.workTaskEvents()
            let query = search
            let filter = captureFilter
            let found = query.isEmpty && !filter.isActive ? library : try await store.snapshot(query: query, captureFilter: filter)
            if search == query && captureFilter == filter { results = found }
        } catch { notice = error.localizedDescription }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            await self?.refresh()
        }
    }

    func setTaskStatus(_ id: UUID, _ status: WorkTaskStatus) {
        guard !updatingTaskIDs.contains(id) else { return }
        updatingTaskIDs.insert(id)
        Task {
            defer { updatingTaskIDs.remove(id) }
            do {
                try await store.setWorkTaskStatus(id, status: status)
                if lastTaskReview?.taskID == id { lastTaskReview = nil }
                await refresh()
            }
            catch { notice = error.localizedDescription }
        }
    }

    func reviewTask(_ id: UUID, _ status: WorkTaskStatus) {
        guard !updatingTaskIDs.contains(id) else { return }
        updatingTaskIDs.insert(id)
        Task {
            defer { updatingTaskIDs.remove(id) }
            do {
                lastTaskReview = try await store.reviewWorkTask(id, status: status)
                await refresh()
            } catch { notice = error.localizedDescription }
        }
    }

    func undoTaskReview() {
        guard let review = lastTaskReview, !updatingTaskIDs.contains(review.taskID) else { return }
        updatingTaskIDs.insert(review.taskID)
        Task {
            defer { updatingTaskIDs.remove(review.taskID) }
            do {
                try await store.undoWorkTaskReview(review)
                if lastTaskReview?.taskID == review.taskID { lastTaskReview = nil }
                await refresh()
            } catch { notice = error.localizedDescription }
        }
    }

    func saveTask(id: UUID?, title: String, project: String, waitingReason: String) async throws -> UUID {
        let saved: UUID
        if let id { try await store.updateWorkTask(id, title: title, project: project, waitingReason: waitingReason); saved = id }
        else { saved = try await store.createWorkTask(title: title, project: project, waitingReason: waitingReason) }
        if lastTaskReview?.taskID == saved { lastTaskReview = nil }
        await refresh()
        return saved
    }

    func discoverTasks() {
        guard canStartOrganization, let agent = preferences.enabledAgent else { return }
        discoveringTasks = true
        discoveryAgent = agent
        taskDiscoveryFailed = false
        taskDiscoveryMessage = "AI 正在发现待办并更新任务进展…"
        taskDiscovery = Task {
            defer { discoveringTasks = false; discoveryAgent = nil; taskDiscovery = nil }
            do {
                let snapshot = try await store.snapshot()
                let memories = Array(snapshot.entries.prefix(200))
                guard !memories.isEmpty else { taskDiscoveryMessage = "还没有可分析的 Memory。"; return }
                let client = try await connectedClient(agent)
                try Task.checkCancellation()
                agents[agent]?.phase = .working
                agents[agent]?.detail = "正在识别工作任务"
                let session = try await session(for: agent, using: client)
                let existing = try await store.workTasks()
                let response = try await trackedPrompt(client, agent: agent, session: session,
                    text: TaskComposer.discoveryPrompt(memories: memories, tasks: existing), images: [])
                try Task.checkCancellation()
                guard response.stopReason == "end_turn" else { throw LibraryError.invalidResult("任务识别未完成，请重试。") }
                let count = try await store.ingestTaskSuggestions(TaskComposer.parse(response.text), allowedSourceIDs: [], allowedMemoryIDs: Set(memories.map(\.id)))
                agents[agent]?.phase = .ready
                agents[agent]?.detail = "已就绪 · 每批独立整理"
                taskDiscoveryMessage = count == 0 ? "已分析 \(memories.count) 篇 Memory，没有新的任务进展。" : "已分析 \(memories.count) 篇 Memory，更新了 \(count) 项任务的线索或进展。"
            } catch {
                if Task.isCancelled { taskDiscoveryMessage = "任务识别已取消。" }
                else { taskDiscoveryMessage = "任务识别失败：\(error.localizedDescription)"; taskDiscoveryFailed = true }
                if let client = clients[agent] { await client.close() }
                clients[agent] = nil; agents[agent]?.sessionID = nil
                agents[agent]?.phase = .disconnected
                agents[agent]?.detail = "尚未连接"
            }
            await releaseSession(agent)
            await refresh()
        }
    }

    func cancelTaskDiscovery() {
        taskDiscovery?.cancel()
        guard let agent = discoveryAgent, let client = clients[agent] else { return }
        Task {
            if let session = state(agent).sessionID { try? await client.cancel(sessionID: session) }
            await client.close()
        }
    }

    func connect(_ agent: ClipAgent) {
        guard !state(agent).busy, !state(agent).available, !preview else { return }
        agents[agent]?.phase = .connecting
        agents[agent]?.detail = "正在连接…"
        Task {
            do { _ = try await connectedClient(agent) }
            catch { setFailure(agent, error) }
        }
    }

    func enable(_ agent: ClipAgent) {
        guard !preview, state(agent).available else { return }
        preferences.enabledAgent = agent
        Task { await refresh() }
    }

    func disableAgent() {
        guard !preview else { return }
        preferences.enabledAgent = nil
    }

    func copyClaudeLoginCommand() {
        guard let command = runtime.command(for: .claude, customPath: preferences.claudePath) else { return }
        let quotedPath = "'" + command.executable.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quotedPath + " --cli auth login --claudeai", forType: .string)
        notice = "登录命令已复制。请在终端运行并完成登录，然后回到 MyClip 连接 Claude Code。"
    }

    func openClaudeDesktop() {
        guard !preview else { return }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            notice = "未找到 Claude Desktop，请先安装桌面端。"
            return
        }
        if !NSWorkspace.shared.open(application) { notice = "无法打开 Claude Desktop，请尝试从“应用程序”中打开。" }
    }

    func install(_ agent: ClipAgent) {
        guard !state(agent).busy, !preview, !agents.values.contains(where: { $0.phase == .installing }) else { return }
        agents[agent]?.phase = .installing
        agents[agent]?.detail = "正在安装连接组件…"
        Task {
            do {
                try await runtime.install(agent)
                agents[agent]?.phase = .disconnected
                agents[agent]?.detail = "组件已安装，可以连接"
                _ = try await connectedClient(agent)
            } catch { setFailure(agent, error) }
        }
    }

    func authenticate(_ agent: ClipAgent, method: ACPAuthMethod) {
        guard let client = clients[agent], !state(agent).busy else { return }
        agents[agent]?.phase = .connecting
        agents[agent]?.detail = "等待登录完成…"
        Task {
            do {
                try await client.authenticate(methodID: method.id)
                _ = try await session(for: agent, using: client)
                agents[agent]?.phase = .ready
                agents[agent]?.detail = "已就绪 · 每批独立整理"
            } catch { setFailure(agent, error) }
        }
    }

    func resolve(_ permission: ClipPermission, optionID: String?) {
        guard let client = clients[permission.agent] else { return }
        Task {
            do { try await client.respondToPermission(id: permission.request.id, optionID: optionID) }
            catch { notice = error.localizedDescription }
        }
    }

    func enqueue(_ capture: ClipCapture) {
        guard !preview, let target = preferences.enabledAgent, state(target).available else { return }
        Task {
            do {
                let id = try await store.enqueue(sourceIDs: [capture.id], agent: target)
                await refresh()
                await processNext(immediately: true, jobID: id, agent: target)
            } catch { notice = error.localizedDescription }
        }
    }

    func rebuildIndex() {
        Task {
            do { try await store.rebuildSearchIndex(); await refresh(); notice = "搜索索引已重建。" }
            catch { notice = error.localizedDescription }
        }
    }

    func canRetry(_ job: ClipJob) -> Bool { canStartOrganization && preferences.enabledAgent == job.agent }

    func retry(_ job: ClipJob) {
        Task {
            guard canRetry(job) else { return }
            dispatching = true
            do {
                try await store.retryJob(id: job.id)
                dispatching = false
                await processNext(immediately: true, jobID: job.id, agent: job.agent)
                await refresh()
            } catch { dispatching = false; notice = error.localizedDescription }
        }
    }

    func organizeNow() {
        guard canOrganizeNow else { return }
        Task { await processNext(immediately: true) }
    }

    func organizationStatus(at date: Date, agent: ClipAgent? = nil) -> String {
        let count = agent.map { library.queue.pendingCounts[$0, default: 0] } ?? library.queue.pendingCount
        if let job = currentJob {
            if agent == nil || job.agent == agent {
                return "正在整理 \(job.sourceIDs.count) 条 · 另有 \(count) 条等待"
            }
            return "\(count) 条等待 · 正在使用 \(job.agent.name)"
        }
        guard let enabled = preferences.enabledAgent else { return "等待启用 Agent · \(count) 条等待" }
        if processingPaused { return "整理已暂停 · \(count) 条等待" }
        guard state(enabled).available else { return "等待连接 \(enabled.name) · \(count) 条等待" }
        guard count > 0 else { return "等待新的截图" }
        if discoveringTasks { return "\(count) 条等待 · 正在识别任务" }
        if let next = library.queue.nextAgent, next != enabled { return "\(count) 条等待 · 请启用 \(next.name) 继续原任务" }
        if let agent, library.queue.nextAgent != agent { return "\(count) 条等待 · 前方还有其他 Agent 的截图" }
        let seconds = max(0, Int(ceil((library.queue.readyAt ?? date).timeIntervalSince(date))))
        return seconds == 0 ? "\(count) 条等待 · 即将整理" : "\(count) 条等待 · 约 \(seconds / 60) 分 \(seconds % 60) 秒后整理"
    }

    func cancel(_ job: ClipJob) {
        cancelledJobs.insert(job.id)
        Task {
            if currentJob?.id == job.id, let client = clients[job.agent] {
                permissions.removeAll { $0.agent == job.agent }
                await client.cancelAndClose(sessionID: state(job.agent).sessionID)
                if clients[job.agent] === client {
                    clients[job.agent] = nil
                    agents[job.agent]?.sessionID = nil
                }
            }
            do { try await store.finishJob(id: job.id, state: .cancelled); await refresh() }
            catch { notice = error.localizedDescription }
        }
    }

    func save(_ entry: KnowledgeEntry, title: String, body: String) async -> Bool {
        do {
            try await store.updateEntry(id: entry.id, title: title, body: body, expectedRevision: entry.revision)
            await refresh()
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    func delete(_ entry: KnowledgeEntry) {
        Task {
            do {
                try await store.deleteEntry(id: entry.id)
                if selectedEntry == entry.id { selectedEntry = nil }
                await refresh()
            } catch { notice = error.localizedDescription }
        }
    }

    func move(_ entry: KnowledgeEntry, to path: String) async -> Bool {
        do {
            try await store.moveMemory(entry.id, to: path, expectedRevision: entry.revision)
            await refresh()
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    private func connectedClient(_ agent: ClipAgent) async throws -> ACPClient {
        if let client = clients[agent], state(agent).available { return client }
        guard let command = try runtime.organizationCommand(for: agent, customPath: preferences.path(for: agent)) else {
            throw ACPError.disconnected("请先在连接设置中安装组件。")
        }
        if let old = clients[agent] { await old.close() }
        eventTasks[agent]?.cancel()
        agents[agent]?.sessionID = nil
        agents[agent]?.phase = .connecting
        agents[agent]?.detail = "正在连接…"
        let client = ACPClient()
        clients[agent] = client
        eventTasks[agent] = Task { [weak self] in
            for await event in client.events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event, agent: agent)
            }
        }
        let handshake = try await client.connect(command: command)
        agents[agent]?.authMethods = handshake.authMethods
        guard handshake.supportsImages else { throw ACPError.unsupportedImages }
        _ = try await session(for: agent, using: client)
        agents[agent]?.phase = .ready
        agents[agent]?.detail = "已就绪 · 每批独立整理"
        return client
    }

    var memoryCommand: ACPCommand {
        ACPCommand(executable: Bundle.main.executableURL!, arguments: ["--mcp", "--library", store.root.path])
    }

    func setMCPEnabled(_ enabled: Bool) {
        do {
            try MemoryMCP.setEnabled(enabled, in: store.root)
            mcpEnabled = enabled
        } catch { notice = "无法更改 MCP 状态：\(error.localizedDescription)" }
    }

    func configureMCP() {
        guard mcpEnabled, !configuringMCP, !preview, !preferences.mcpClients.isEmpty else { return }
        let selected = MCPClient.allCases.filter { preferences.mcpClients.contains($0) }
        let bundledCodex = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?
            .appendingPathComponent("Contents/Resources/codex")
        let installer = MCPClientInstaller(codexExecutable: bundledCodex.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil })
        configuringMCP = true
        mcpSetupResults = [:]
        Task {
            defer { configuringMCP = false }
            for client in selected {
                do {
                    try await installer.install(client, command: memoryCommand)
                    mcpSetupResults[client] = .configured
                } catch { mcpSetupResults[client] = .failed(error.localizedDescription) }
            }
        }
    }

    func openMemoryLink(_ url: URL) {
        guard url.scheme == "myclip-memory" else { return }
        let target = String(url.path(percentEncoded: false).dropFirst())
        Task {
            do {
                let entry = try await store.resolveMemoryLink(target)
                if !library.entries.contains(where: { $0.id == entry.id }) { library.entries.append(entry) }
                selectedEntry = entry.id
            } catch { notice = error.localizedDescription }
        }
    }

    private func workspaceDirectory() throws -> URL {
        let directory = store.root.appendingPathComponent("Memory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func session(for agent: ClipAgent, using client: ACPClient) async throws -> String {
        // A connection may prepare a blank session before activation. It is consumed by one batch only.
        if let id = state(agent).sessionID { return id }
        let id = try await client.newSession(directory: try workspaceDirectory(), memoryServer: memoryCommand, ephemeralFor: agent)
        try await client.setMode(sessionID: id, modeID: agent == .codex ? "agent-full-access" : "bypassPermissions")
        agents[agent]?.sessionID = id
        agents[agent]?.sessionIsEphemeral = true
        return id
    }

    private func releaseSession(_ agent: ClipAgent) async {
        eventTasks[agent]?.cancel()
        eventTasks[agent] = nil
        let client = clients.removeValue(forKey: agent)
        agents[agent]?.sessionID = nil
        permissions.removeAll { $0.agent == agent }
        await client?.close()
    }

    private func processNext(immediately: Bool = false, jobID: UUID? = nil, agent: ClipAgent? = nil) async {
        guard canStartOrganization, let enabled = preferences.enabledAgent else { return }
        // Reserve dispatch before the first await so timer ticks and repeated clicks cannot race.
        dispatching = true
        defer { dispatching = false }
        do {
            try await store.reassignPendingCaptures(to: enabled)
            let queue = try await store.organizationQueue()
            guard let target = agent ?? queue.nextAgent, target == preferences.enabledAgent,
                  state(target).available, !state(target).busy else { return }
            if !immediately {
                guard !queue.paused, let readyAt = queue.readyAt, Date() >= readyAt else { return }
            }
            if jobID == nil { try await store.prepareOrganizationText() }
            guard target == preferences.enabledAgent, state(target).available, !state(target).busy,
                  let job = try await store.claimNextJob(immediately: immediately, jobID: jobID) else { return }
            currentJob = job
            currentJobStartedAt = Date()
            activityText = "正在连接 \(job.agent.name) ACP…"
            await refresh()
            do {
                let previousRevisions = try await store.beginMemoryEditing(jobID: job.id)
                let client = try await connectedClient(job.agent)
                if cancelledJobs.contains(job.id) { throw CancellationError() }
                agents[job.agent]?.phase = .working
                agents[job.agent]?.detail = "正在整理 \(job.sourceIDs.count) 条记录"
                activityText = "正在读取 \(job.sourceIDs.count) 条记录…"
                let inputs = try await store.organizationInputs(jobID: job.id)
                let data = try await Task.detached(priority: .utility) {
                    try inputs.filter(\.usesImage).map { try Data(contentsOf: $0.capture.imageURL) }
                }.value
                activityText = "正在准备 \(job.agent.name) 会话…"
                let session = try await session(for: job.agent, using: client)
                let existingTasks = try await store.workTasks()
                let taskContext = TaskComposer.context(tasks: existingTasks)
                let handoff = try await store.organizationHandoff()
                activityText = "已提交 \(data.count) 张图片、\(inputs.count - data.count) 条文本，等待 \(job.agent.name) 回复…"
                let result = try await trackedPrompt(client, agent: job.agent, session: session,
                    text: KnowledgeComposer.filePrompt(inputs: inputs, handoff: handoff) + "\n" + taskContext, images: data, jobID: job.id)
                if cancelledJobs.contains(job.id) || result.stopReason == "cancelled" { throw CancellationError() }
                guard result.stopReason == "end_turn" else { throw LibraryError.invalidResult("Agent 在完成前停止，请重试。") }
                activityText = "正在同步 Memory 文件…"
                let changedCount = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: previousRevisions)
                do {
                    let memories = try await store.snapshot().entries
                    _ = try await store.ingestTaskSuggestions(TaskComposer.parse(result.text), allowedSourceIDs: Set(job.sourceIDs), allowedMemoryIDs: Set(memories.map(\.id)))
                    if taskDiscoveryFailed { taskDiscoveryMessage = nil; taskDiscoveryFailed = false }
                } catch {
                    taskDiscoveryMessage = "Memory 已保存；任务识别未完成：\(error.localizedDescription)"
                    taskDiscoveryFailed = true
                }
                agents[job.agent]?.phase = .ready
                agents[job.agent]?.detail = changedCount == 0 ? "已整理，Memory 无需更新" : "已更新 \(changedCount) 个 Memory 文件"
                agents[job.agent]?.lastCompleted = Date()
            } catch {
                if cancelledJobs.contains(job.id) || error is CancellationError {
                    try await store.finishJob(id: job.id, state: .cancelled)
                    agents[job.agent]?.phase = .disconnected
                    agents[job.agent]?.detail = "整理已取消"
                } else {
                    try await store.finishJob(id: job.id, state: .failed, error: error.localizedDescription)
                    setFailure(job.agent, error)
                }
            }
            await releaseSession(job.agent)
            cancelledJobs.remove(job.id)
            currentJob = nil
            currentJobStartedAt = nil
            activityText = ""
            await refresh()
        } catch {
            if let job = currentJob { await releaseSession(job.agent) }
            currentJob = nil
            currentJobStartedAt = nil
            notice = error.localizedDescription
        }
    }

    private func trackedPrompt(_ client: ACPClient, agent: ClipAgent, session: String, text: String,
                               images: [Data], jobID: UUID? = nil) async throws -> ACPCompletion {
        try await store.executePrompt(client, agent: agent, sessionID: session, text: text, images: images, jobID: jobID)
    }

    func organizationActivity(at date: Date) -> String {
        guard let started = currentJobStartedAt else { return activityText }
        let elapsed = max(0, Int(date.timeIntervalSince(started)))
        let idle = max(0, Int(date.timeIntervalSince(lastActivityAt)))
        let waiting = idle >= 30 ? " · 已有 \(idle) 秒未收到新进度" : ""
        return "\(activityText) · 已用时 \(elapsed / 60) 分 \(elapsed % 60) 秒\(waiting)"
    }

    private func updateActivity(_ text: String, session: String, agent: ClipAgent) {
        guard state(agent).sessionID == session else { return }
        if currentJob?.agent == agent { activityText = text }
        else if discoveryAgent == agent { taskDiscoveryMessage = text }
    }

    private func handle(_ event: ACPEvent, agent: ClipAgent) {
        switch event {
        case .message(let session, _): updateActivity("\(agent.name) 正在生成结果…", session: session, agent: agent)
        case .thinking(let session): updateActivity("\(agent.name) 正在思考…", session: session, agent: agent)
        case .tool(let session, let title, _): updateActivity(title, session: session, agent: agent)
        case .permission(let request):
            permissions.removeAll { $0.agent == agent && $0.request.id == request.id }
            permissions.append(ClipPermission(agent: agent, request: request))
            agents[agent]?.phase = .permission
            agents[agent]?.detail = "需要你的确认"
        case .permissionResolved(let id):
            permissions.removeAll { $0.agent == agent && $0.request.id == id }
            agents[agent]?.phase = currentJob?.agent == agent || discoveryAgent == agent ? .working : .ready
            agents[agent]?.detail = discoveryAgent == agent ? "正在识别工作任务" : currentJob?.agent == agent ? "正在整理" : "已连接"
        case .disconnected(let message):
            permissions.removeAll { $0.agent == agent }
            agents[agent]?.sessionID = nil
            agents[agent]?.phase = .disconnected
            agents[agent]?.detail = message.isEmpty ? "连接已关闭" : message
        }
    }

    private func setFailure(_ agent: ClipAgent, _ error: any Error) {
        agents[agent]?.phase = .failed
        agents[agent]?.detail = error.localizedDescription.components(separatedBy: "\n").first ?? error.localizedDescription
    }

    private func cleanupIfNeeded() async {
        guard Date().timeIntervalSince(lastCleanup) > 3600 else { return }
        lastCleanup = Date()
        guard preferences.retentionDays > 0 else { return }
        do {
            try await store.expireImages(before: Date().addingTimeInterval(-Double(preferences.retentionDays) * 86_400))
            await refresh()
        } catch { notice = error.localizedDescription }
    }

    private func seedPreview() async throws {
        guard try await store.snapshot().captures.isEmpty else { return }
        let size = CGSize(width: 1200, height: 760)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill(); rect.fill()
            let title = "MyClip · 截图预览" as NSString
            title.draw(at: NSPoint(x: 80, y: 630), withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.labelColor])
            let content = "用截图留住上下文\n\n应用中的焦点窗口 → 本地资料库 → Memory\n\n此画面为界面验证生成，不来自真实应用。" as NSString
            content.draw(at: NSPoint(x: 80, y: 330), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.secondaryLabelColor])
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let captured = try CapturedImage(image: cgImage)
        let context = CaptureContext(appName: "预览示例", bundleID: "myclip.preview", windowTitle: "聚焦窗口的截图整理", windowID: 1, reason: .pointerIdle)
        try await store.record(image: captured, context: context, agent: .codex, organize: true)
        guard let job = try await store.claimNextJob(immediately: true) else { return }
        try await store.commit(jobID: job.id, drafts: [
            KnowledgeDraft(kind: .memory, title: "让工作中的上下文，成为可以找回的知识", body: "MyClip 将应用窗口中的信息，整理为有来源的本地知识。\n\n## 从一张截图开始\n\n鼠标移动后静止一秒，再点击或双击；上下滚动停止两秒；或按下回车，记录当前应用的焦点窗口。重复画面共享一份图片，每次出现的时间仍被保留。\n\n## 从记录到理解\n\nCodex 或 Claude 通过 ACP 读取截图，整理 Memory。点击下方来源，可以回到知识产生的那一刻。\n\n这是用于验证界面的示例内容。", sourceIDs: [context.id]),
            KnowledgeDraft(kind: .memory, title: "截图只来自当前焦点窗口", body: "MyClip 记录前台应用的焦点窗口。无法确认焦点时跳过该帧，不截取整个桌面。", sourceIDs: [context.id]),
            KnowledgeDraft(kind: .memory, title: "重复画面，保留每一次出现", body: "相同像素的截图共用一个图片文件，时间、应用和来源记录仍分别保存。", sourceIDs: [context.id])
        ])
        try await store.ingestTaskSuggestions([
            WorkTaskDraft(title: "补充客户提到的导出格式", project: "客户协作", evidence: "示例线索：导出时是否可以保留来源？", sourceIDs: [context.id]),
            WorkTaskDraft(title: "验证弱网下的资料同步", project: "MyClip", evidence: "示例线索：弱网场景尚未验证。", sourceIDs: [context.id]),
            WorkTaskDraft(title: "为截图时间线添加触发方式图标", project: "MyClip", suggestedStatus: .doing, evidence: "示例线索：时间线正在接入触发图标，还需要区分鼠标与键盘事件。", sourceIDs: [context.id]),
            WorkTaskDraft(title: "优化浮层磨砂与气泡对比度", project: "chat-bridge", suggestedStatus: .done, evidence: "示例线索：浮层背景与气泡对比度已调整，并已检查浅色与深色外观。", sourceIDs: [context.id]),
            WorkTaskDraft(title: "配置完成后自动发送命令指南", project: "chat-bridge", suggestedStatus: .doing, evidence: "示例线索：正在添加首次连接后的命令指南。", sourceIDs: [context.id]),
            WorkTaskDraft(title: "排查 iMessage 配对失败", project: "chat-bridge", evidence: "示例线索：配对后手机未收到消息，需要检查发送记录。", sourceIDs: [context.id]),
            WorkTaskDraft(title: "修复微信端 session 与 agent 切换", project: "chat-bridge", evidence: "示例线索：会话与 agent 切换未生效，问题已记录。", sourceIDs: [context.id]),
            WorkTaskDraft(title: "整理本周发布说明", project: "MyClip", evidence: "示例线索：需要汇总本周的界面与连接改动。", sourceIDs: [context.id])
        ], allowedSourceIDs: [context.id], allowedMemoryIDs: [])
        let examples: [(String, String, WorkTaskStatus, Int)] = [
            ("回归单击与双击的截图时机", "MyClip", .todo, 0),
            ("整理本周客户反馈", "客户协作", .todo, 1),
            ("补齐资料库的使用说明", "资料整理", .todo, 3),
            ("设计任务看板的第一版", "MyClip", .doing, 1),
            ("确认导出字段与交付范围", "客户协作", .doing, 5),
            ("调整鼠标静止时间为 1 秒", "MyClip", .done, 6),
            ("整理资料目录与命名", "资料整理", .done, 7)
        ]
        for (title, project, status, days) in examples {
            let date = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            let id = try await store.createWorkTask(title: title, project: project, waitingReason: title == "确认导出字段与交付范围" ? "客户确认字段" : "", at: date)
            if status != .todo { try await store.setWorkTaskStatus(id, status: status, at: date.addingTimeInterval(60)) }
        }
    }

    #if DEBUG
    private func previewPanelState() async throws {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--panel-state=") }),
              let capture = library.captures.first else { return }
        let value = String(argument.dropFirst("--panel-state=".count))
        agents[.codex]?.phase = .ready
        agents[.codex]?.detail = "已连接"
        agents[.codex]?.sessionID = "00000000-0000-0000-0000-000000000001"
        if ["waiting", "paused", "working", "permission", "failed"].contains(value) {
            _ = try await store.enqueue(sourceIDs: [capture.id], agent: .codex)
        }
        switch value {
        case "paused": try await store.setOrganizationPaused(true)
        case "working", "permission", "failed":
            currentJob = try await store.claimNextJob(immediately: true)
            agents[.codex]?.phase = value == "permission" ? .permission : .working
            if value == "failed", let job = currentJob {
                try await store.finishJob(id: job.id, state: .failed, error: "示例：连接中断，来源截图已保留。")
                try await store.setOrganizationPaused(true, reason: "示例：连接中断")
                currentJob = nil
                agents[.codex]?.phase = .failed
                agents[.codex]?.detail = "示例：连接中断，来源截图已保留。"
            }
        case "done":
            agents[.codex]?.lastCompleted = .now
            agents[.codex]?.detail = "本批新增了 3 篇记忆"
        case "disconnected": agents[.codex] = .init()
        case "connecting": agents[.codex]?.phase = .connecting
        case "installing": agents[.codex]?.phase = .installing
        default: break
        }
        await refresh()
    }
    #endif
}
