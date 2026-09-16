import AppKit
import Observation
import MyClipCore

@MainActor
@Observable
final class ClipPreferences {
    private let defaults: UserDefaults
    var captureWasEnabled: Bool { didSet { defaults.set(captureWasEnabled, forKey: "myclip.captureWasEnabled") } }
    var agent: ClipAgent { didSet { defaults.set(agent.rawValue, forKey: "myclip.agent") } }
    var autoOrganize: Bool { didSet { defaults.set(autoOrganize, forKey: "myclip.autoOrganize") } }
    var captureSettings: CaptureSettings { didSet { captureSettings.save(to: defaults) } }
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "myclip.retentionDays") } }
    var excludedApps: String { didSet { defaults.set(excludedApps, forKey: "myclip.excludedApps") } }
    var codexPath: String { didSet { defaults.set(codexPath, forKey: "myclip.codexPath") } }
    var claudePath: String { didSet { defaults.set(claudePath, forKey: "myclip.claudePath") } }
    var mcpClients: Set<MCPClient> { didSet { defaults.set(mcpClients.map(\.rawValue).sorted(), forKey: "myclip.mcpClients") } }

    init(preview: Bool) {
        defaults = preview ? UserDefaults(suiteName: "MyClip.Preview")! : .standard
        captureWasEnabled = defaults.bool(forKey: "myclip.captureWasEnabled")
        agent = ClipAgent(rawValue: defaults.string(forKey: "myclip.agent") ?? "") ?? .codex
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
    case captures, memory, dashboard, agents, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: "任务看板"
        case .memory: "Memory"
        case .captures: "截图时间线"
        case .agents: "Agent"
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
@Observable
final class MyClipModel {
    let store: LibraryStore
    let preferences: ClipPreferences
    let preview: Bool
    var page: LibraryPage? = .captures
    var search = "" {
        didSet {
            guard search != oldValue else { return }
            if oldValue.isEmpty { selectionBeforeSearch = (selectedEntry, memoryFolder) }
            if search.isEmpty {
                selectedEntry = selectionBeforeSearch?.entry
                memoryFolder = selectionBeforeSearch?.folder
                selectionBeforeSearch = nil
                results = library
            } else {
                selectedEntry = nil
                memoryFolder = nil
            }
            scheduleSearch()
        }
    }
    var library = LibrarySnapshot()
    var results = LibrarySnapshot()
    var selectedEntry: UUID?
    var memoryFolder: String?
    var selectedCapture: UUID?
    @ObservationIgnored var memoryScrollOffsets: [UUID: CGFloat] = [:]
    var capturing = false
    var workTasks: [WorkTask] = []
    var statistics = LibraryStatistics()
    var taskStatistics = WorkTaskStatistics()
    var discoveringTasks = false
    var taskDiscoveryMessage: String?
    var taskDiscoveryFailed = false
    var updatingTaskIDs: Set<UUID> = []
    var proposals: [MemoryProposal] = []
    var analyticsDays = 7 { didSet { Task { await refresh() } } }
    var captureStatus = "采集已暂停"
    var processingPaused: Bool {
        get { library.queue.paused }
        set {
            Task {
                do { try await store.setOrganizationPaused(newValue); await refresh() }
                catch { notice = error.localizedDescription }
            }
        }
    }
    private(set) var dispatching = false
    var canStartOrganization: Bool { !preview && !dispatching && currentJob == nil && !discoveringTasks }
    var canOrganizeNow: Bool { canStartOrganization && library.queue.pendingCount > 0 && library.queue.pauseReason == nil }
    var showPermissions = false
    var screenPermission = false
    var accessibilityPermission = false
    var notice: String?
    private(set) var mcpEnabled: Bool
    private(set) var configuringMCP = false
    private(set) var mcpSetupResults: [MCPClient: MCPSetupResult] = [:]
    var agents: [ClipAgent: ClipAgentState] = [.codex: .init(), .claude: .init()] {
        didSet { onStatusChange?() }
    }
    var permissions: [ClipPermission] = []
    var currentJob: ClipJob?
    var activityText = ""
    var onOpenWindow: (() -> Void)?
    var onStatusChange: (() -> Void)?

    @ObservationIgnored private let captureService = FocusedCaptureService()
    @ObservationIgnored private let runtime: AgentRuntime
    @ObservationIgnored private var clients: [ClipAgent: ACPClient] = [:]
    @ObservationIgnored private var sessions: [ClipAgent: String] = [:]
    @ObservationIgnored private var eventTasks: [ClipAgent: Task<Void, Never>] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var selectionBeforeSearch: (entry: UUID?, folder: String?)?
    @ObservationIgnored private var taskDiscovery: Task<Void, Never>?
    @ObservationIgnored private var discoveryAgent: ClipAgent?
    @ObservationIgnored private var cancelledJobs: Set<UUID> = []
    @ObservationIgnored private var lastCleanup = Date.distantPast

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
                try await self.store.record(image: image, context: context, agent: self.preferences.agent, organize: self.preferences.autoOrganize)
                await self.refresh()
                self.captureStatus = repeated ? "已记录本次出现，相同画面共用原图" : "已保存 \(context.appName) · \(context.date.formatted(date: .omitted, time: .standard))"
            } catch { self.captureStatus = "保存失败：\(error.localizedDescription)"; self.notice = error.localizedDescription }
        }
        captureService.onStatus = { [weak self] status in self?.captureStatus = status }
        refreshPermissions()
    }

    func start() {
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.recoverInterruptedJobs()
                if preview { try await seedPreview() }
                if !preview && preferences.captureWasEnabled {
                    refreshPermissions()
                    if screenPermission && accessibilityPermission { applyCaptureSettings(); capturing = captureService.start() }
                    else { captureStatus = "采集未恢复：请在设置中允许屏幕录制和辅助功能" }
                }
                await refresh()
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
    }

    func stop() {
        captureService.stop()
        worker?.cancel()
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

    func refreshPermissions() {
        screenPermission = captureService.hasScreenPermission
        accessibilityPermission = captureService.hasAccessibilityPermission
        if capturing && (!screenPermission || !accessibilityPermission) {
            capturing = false
            captureService.stop()
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

    func toggleCapture() {
        if capturing {
            captureService.stop()
            capturing = false
        } else if preview {
            notice = "这是界面预览，采集和 Agent 调用已停用。"
        } else {
            refreshPermissions()
            guard screenPermission, accessibilityPermission else { showPermissions = true; open(); return }
            applyCaptureSettings()
            capturing = captureService.start()
        }
        preferences.captureWasEnabled = capturing
        onStatusChange?()
    }

    func refresh() async {
        do {
            library = try await store.snapshot()
            proposals = try await store.proposals()
            statistics = try await store.statistics(since: analyticsDays == 0 ? .distantPast : Calendar.current.date(byAdding: .day, value: -analyticsDays, to: Date())!)
            workTasks = try await store.workTasks()
            taskStatistics = try await store.workTaskStatistics(days: analyticsDays)
            let query = search
            let found = query.isEmpty ? library : try await store.snapshot(query: query)
            if search == query { results = found }
            onStatusChange?()
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
            do { try await store.setWorkTaskStatus(id, status: status); await refresh() }
            catch { notice = error.localizedDescription }
        }
    }

    func saveTask(id: UUID?, title: String, project: String, waitingReason: String) async throws -> UUID {
        let saved: UUID
        if let id { try await store.updateWorkTask(id, title: title, project: project, waitingReason: waitingReason); saved = id }
        else { saved = try await store.createWorkTask(title: title, project: project, waitingReason: waitingReason) }
        await refresh()
        return saved
    }

    func discoverTasks() {
        guard !preview, !dispatching, !discoveringTasks, currentJob == nil, !state(preferences.agent).busy else { return }
        let agent = preferences.agent
        discoveringTasks = true
        discoveryAgent = agent
        taskDiscoveryFailed = false
        taskDiscoveryMessage = "正在从 Memory 识别任务…"
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
                let response = try await client.prompt(sessionID: session, text: TaskComposer.discoveryPrompt(memories: memories, tasks: existing), images: [])
                try Task.checkCancellation()
                guard response.stopReason == "end_turn" else { throw LibraryError.invalidResult("任务识别未完成，请重试。") }
                let count = try await store.ingestTaskSuggestions(TaskComposer.parse(response.text), allowedSourceIDs: [], allowedMemoryIDs: Set(memories.map(\.id)))
                agents[agent]?.phase = .ready
                agents[agent]?.detail = "已连接 · 持续会话"
                taskDiscoveryMessage = count == 0 ? "已分析 \(memories.count) 篇 Memory，没有新的任务线索。" : "已分析 \(memories.count) 篇 Memory，新增或补充了 \(count) 项任务线索。"
            } catch {
                if Task.isCancelled { taskDiscoveryMessage = "任务识别已取消。" }
                else { taskDiscoveryMessage = "任务识别失败：\(error.localizedDescription)"; taskDiscoveryFailed = true }
                if let client = clients[agent] { await client.close() }
                clients[agent] = nil; sessions[agent] = nil
                agents[agent]?.phase = .disconnected
                agents[agent]?.detail = "尚未连接"
            }
            await refresh()
        }
    }

    func cancelTaskDiscovery() {
        taskDiscovery?.cancel()
        guard let agent = discoveryAgent, let client = clients[agent] else { return }
        Task {
            if let session = sessions[agent] { try? await client.cancel(sessionID: session) }
            await client.close()
        }
    }

    func connect(_ agent: ClipAgent) {
        guard !state(agent).busy, !preview else { return }
        Task {
            do { _ = try await connectedClient(agent) }
            catch { setFailure(agent, error) }
        }
    }

    func copyClaudeLoginCommand() {
        guard let command = runtime.command(for: .claude, customPath: preferences.claudePath) else { return }
        let quotedPath = "'" + command.executable.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quotedPath + " --cli auth login --claudeai", forType: .string)
        notice = "登录命令已复制。请在终端运行并完成登录，然后回到 MyClip 连接 Claude。"
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
                agents[agent]?.detail = "已连接 · 持续会话"
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

    func enqueue(_ capture: ClipCapture, agent: ClipAgent? = nil) {
        Task {
            do {
                let target = agent ?? preferences.agent
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

    func retry(_ job: ClipJob) {
        Task {
            guard canStartOrganization else { return }
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
                return "正在整理 \(job.sourceIDs.count) 张 · 另有 \(count) 张等待"
            }
            return "\(count) 张等待 · 正在使用 \(job.agent.name)"
        }
        if processingPaused { return "整理已暂停 · \(count) 张等待" }
        guard count > 0 else { return "等待新的截图" }
        if discoveringTasks { return "\(count) 张等待 · 正在识别任务" }
        if let agent, library.queue.nextAgent != agent { return "\(count) 张等待 · 前方还有其他 Agent 的截图" }
        let seconds = max(0, Int(ceil((library.queue.readyAt ?? date).timeIntervalSince(date))))
        return seconds == 0 ? "\(count) 张等待 · 即将整理" : "\(count) 张等待 · 约 \(seconds / 60) 分 \(seconds % 60) 秒后整理"
    }

    func cancel(_ job: ClipJob) {
        cancelledJobs.insert(job.id)
        Task {
            if currentJob?.id == job.id, let client = clients[job.agent] {
                permissions.removeAll { $0.agent == job.agent }
                if let session = sessions[job.agent] { try? await client.cancel(sessionID: session) }
                // Closing also interrupts a pending initialize/session request.
                await client.close()
                clients[job.agent] = nil
                sessions[job.agent] = nil
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
        guard let command = runtime.command(for: agent, customPath: preferences.path(for: agent)) else {
            throw ACPError.disconnected("请先在连接设置中安装组件。")
        }
        if let old = clients[agent] { await old.close() }
        eventTasks[agent]?.cancel()
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
        agents[agent]?.detail = "已连接 · 持续会话"
        onStatusChange?()
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

    func copyMCPConfiguration() {
        let command = memoryCommand
        let config: [String: Any] = ["mcpServers": ["myclip": ["command": command.executable.path, "args": command.arguments]]]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            notice = "MCP 配置已复制。MyClip 提供搜索、阅读、关联和来源查询；在客户端添加后即可使用。"
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
        let conversation = try await client.conversation(directory: try workspaceDirectory(), memoryServer: memoryCommand,
            stateFile: store.root.appendingPathComponent("Sessions/\(agent.rawValue).json"))
        if conversation.origin != .reused {
            try await client.setMode(sessionID: conversation.id, modeID: agent == .codex ? "agent" : "acceptEdits")
        }
        sessions[agent] = conversation.id
        if conversation.origin == .replaced { notice = "\(agent.name) 的旧会话无法恢复，已建立新会话继续整理。" }
        return conversation.id
    }

    private func processNext(immediately: Bool = false, jobID: UUID? = nil, agent: ClipAgent? = nil) async {
        guard canStartOrganization else { return }
        // Reserve dispatch before the first await so timer ticks and repeated clicks cannot race.
        dispatching = true
        defer { dispatching = false }
        do {
            let queue = try await store.organizationQueue()
            guard let target = agent ?? queue.nextAgent, !state(target).busy,
                  let job = try await store.claimNextJob(immediately: immediately, jobID: jobID) else { return }
            currentJob = job
            activityText = "准备读取 \(job.sourceIDs.count) 张截图"
            await refresh()
            do {
                let previousRevisions = try await store.beginMemoryEditing(jobID: job.id)
                let client = try await connectedClient(job.agent)
                if cancelledJobs.contains(job.id) { throw CancellationError() }
                agents[job.agent]?.phase = .working
                agents[job.agent]?.detail = "正在整理 \(job.sourceIDs.count) 张截图"
                let inputs = try await store.captures(ids: job.sourceIDs)
                let data = try await Task.detached(priority: .utility) { try inputs.map { try Data(contentsOf: $0.imageURL) } }.value
                let session = try await session(for: job.agent, using: client)
                let existingTasks = try await store.workTasks()
                let taskContext = TaskComposer.context(tasks: existingTasks)
                let result = try await client.prompt(sessionID: session, text: KnowledgeComposer.filePrompt(captures: inputs) + "\n" + taskContext, images: data)
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
            cancelledJobs.remove(job.id)
            currentJob = nil
            activityText = ""
            await refresh()
        } catch {
            currentJob = nil
            notice = error.localizedDescription
        }
    }

    private func handle(_ event: ACPEvent, agent: ClipAgent) {
        switch event {
        case .message: activityText = "正在生成记忆…"
        case .tool(_, let title, _): activityText = title
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
            agents[agent]?.phase = .disconnected
            agents[agent]?.detail = message.isEmpty ? "连接已关闭" : message
        }
        onStatusChange?()
    }

    private func setFailure(_ agent: ClipAgent, _ error: any Error) {
        agents[agent]?.phase = .failed
        agents[agent]?.detail = error.localizedDescription
        onStatusChange?()
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
            WorkTaskDraft(title: "验证弱网下的资料同步", project: "MyClip", evidence: "示例线索：弱网场景尚未验证。", sourceIDs: [context.id])
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
