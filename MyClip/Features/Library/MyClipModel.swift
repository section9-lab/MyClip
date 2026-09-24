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
    @Published var opencodePath: String { didSet { defaults.set(opencodePath, forKey: "myclip.opencodePath") } }
    @Published var cursorPath: String { didSet { defaults.set(cursorPath, forKey: "myclip.cursorPath") } }
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
        opencodePath = defaults.string(forKey: "myclip.opencodePath") ?? ""
        cursorPath = defaults.string(forKey: "myclip.cursorPath") ?? ""
        mcpClients = defaults.stringArray(forKey: "myclip.mcpClients").map { Set($0.compactMap(MCPClient.init(rawValue:))) } ?? [.codex, .claudeCode]
    }

    func path(for agent: ClipAgent) -> String {
        switch agent {
        case .codex: codexPath
        case .claude: claudePath
        case .opencode: opencodePath
        case .cursor: cursorPath
        }
    }
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
        case .settings: "Settings"
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
    /// True when the last discovery failure happened after the batch's Memory was already saved.
    @Published var taskDiscoveryMemorySaved = false
    @Published var taskDiscoveryFailed = false
    @Published var updatingTaskIDs: Set<UUID> = []
    @Published var lastTaskReview: WorkTaskReview?
    @Published var proposals: [MemoryProposal] = []
    @Published var analyticsDays = 7 { didSet { Task { await refresh() } } }
    @Published var captureStatus = String(localized: "正在准备采集")
    var processingPaused: Bool {
        get { library.queue.paused }
        set {
            Task {
                do { try await store.setOrganizationPaused(newValue); await refresh() }
                catch { notice = error.localizedDescription }
            }
        }
    }
    @Published var dispatching = false
    var canStartOrganization: Bool {
        guard let agent = preferences.enabledAgent else { return false }
        // A disconnected Agent reconnects when a batch is due; only a failed one waits for the user.
        return !preview && !dispatching && currentJob == nil && !discoveringTasks && [.ready, .disconnected].contains(state(agent).phase)
    }
    /// The batch that stopped the queue, if any. Retrying it resumes automatic organization.
    var latestFailedJob: ClipJob? { library.jobs.first { $0.state == .failed } }
    /// A batch waiting for its automatic retry, oldest first.
    var jobAwaitingRetry: ClipJob? { library.jobs.last { $0.isAwaitingRetry } }
    var canOrganizeNow: Bool {
        canStartOrganization && library.queue.pendingCount > 0 && library.queue.pauseReason == nil
            && library.queue.nextAgent == preferences.enabledAgent
    }
    var showPermissions: Bool { !preview && (!screenPermission || !accessibilityPermission) }
    @Published var screenPermission = false
    @Published var accessibilityPermission = false
    @Published var folderPermission = false
    @Published var notice: String?
    @Published var mcpEnabled: Bool
    @Published var configuringMCP = false
    @Published var mcpSetupResults: [MCPClient: MCPSetupResult] = [:]
    @Published var agents: [ClipAgent: ClipAgentState] = Dictionary(uniqueKeysWithValues: ClipAgent.allCases.map { ($0, ClipAgentState()) })
    @Published var localAgents: [ClipAgent: LocalAgentAvailability] = [:]
    @Published var selectingDefaultAgent: ClipAgent?
    @Published var permissions: [ClipPermission] = []
    @Published var currentJob: ClipJob?
    @Published var activityText = "" { didSet { lastActivityAt = Date() } }
    var currentJobStartedAt: Date?
    var lastActivityAt = Date()
    var onOpenWindow: (() -> Void)?

    let captureService = FocusedCaptureService()
    let runtime: AgentRuntime
    let sessionCoordinator = AgentSessionCoordinator()
    private var preferencesObservation: AnyCancellable?
    private var textWorker: Task<Void, Never>?
    var worker: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var selectionBeforeSearch: (entry: UUID?, folder: String?)?
    var taskDiscovery: Task<Void, Never>?
    var discoveryAgent: ClipAgent?
    var cancelledJobs: Set<UUID> = []
    var lastCleanup = Date.distantPast

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
                self.captureStatus = repeated ? String(localized: "已记录本次出现，相同画面共用原图") : String(localized: "已保存 \(context.appName) · \(context.date.formatted(date: .omitted, time: .standard))")
            } catch { self.captureStatus = String(localized: "保存失败：\(error.localizedDescription)"); self.notice = error.localizedDescription }
        }
        captureService.onStatus = { [weak self] status in self?.captureStatus = status }
        sessionCoordinator.onEvent = { [weak self] event, agent in self?.handle(event, agent: agent) }
        preferencesObservation = preferences.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if preview { captureStatus = String(localized: "界面预览 · 采集已停用") }
        refreshPermissions()
    }

    func start() {
        guard worker == nil else { return }
        if !preview, let agent = preferences.enabledAgent { connect(agent) }
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.recoverInterruptedJobs()
                await runColdStartIngestionIfNeeded()
                if preview { try await seedPreview() }
                await refresh()
                startTextRecognition()
                #if DEBUG
                if preview {
                    try await previewPanelState()
                    if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--page=") }) {
                        page = LibraryPage(rawValue: String(argument.dropFirst("--page=".count)))
                    }
                }
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
        Task { [sessionCoordinator] in await sessionCoordinator.stopAll() }
    }

    func open(_ page: LibraryPage? = nil) {
        if let page { self.page = page }
        onOpenWindow?()
    }

    func state(_ agent: ClipAgent) -> ClipAgentState { agents[agent] ?? .init() }

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
}
