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
    @Published var workbuddyPath: String { didSet { defaults.set(workbuddyPath, forKey: "myclip.workbuddyPath") } }
    @Published var qwenworkPath: String { didSet { defaults.set(qwenworkPath, forKey: "myclip.qwenworkPath") } }
    @Published private(set) var agentModels: [String: String] { didSet { defaults.set(agentModels, forKey: "myclip.agentModels") } }
    @Published var mcpClients: Set<MCPClient> { didSet { defaults.set(mcpClients.map(\.rawValue).sorted(), forKey: "myclip.mcpClients") } }

    init(preview: Bool, defaults suppliedDefaults: UserDefaults? = nil) {
        let defaults = suppliedDefaults ?? (preview ? UserDefaults(suiteName: "MyClip.Preview")! : .standard)
        self.defaults = defaults
        enabledAgent = ClipAgent(rawValue: defaults.string(forKey: "myclip.enabledAgent") ?? "")
        autoOrganize = defaults.object(forKey: "myclip.autoOrganize") as? Bool ?? true
        captureSettings = CaptureSettings.load(from: defaults)
        retentionDays = defaults.object(forKey: "myclip.retentionDays") as? Int ?? 30
        excludedApps = defaults.string(forKey: "myclip.excludedApps") ?? "com.apple.Passwords\ncom.agilebits.onepassword7\ncom.1password.1password"
        codexPath = defaults.string(forKey: "myclip.codexPath") ?? ""
        claudePath = defaults.string(forKey: "myclip.claudePath") ?? ""
        opencodePath = defaults.string(forKey: "myclip.opencodePath") ?? ""
        cursorPath = defaults.string(forKey: "myclip.cursorPath") ?? ""
        workbuddyPath = defaults.string(forKey: "myclip.workbuddyPath") ?? ""
        qwenworkPath = defaults.string(forKey: "myclip.qwenworkPath") ?? ""
        agentModels = defaults.dictionary(forKey: "myclip.agentModels") as? [String: String] ?? [:]
        mcpClients = defaults.stringArray(forKey: "myclip.mcpClients").map { Set($0.compactMap(MCPClient.init(rawValue:))) } ?? [.codex, .claudeCode]
    }

    func path(for agent: ClipAgent) -> String {
        switch agent {
        case .codex: codexPath
        case .claude: claudePath
        case .opencode: opencodePath
        case .cursor: cursorPath
        case .workbuddy: workbuddyPath
        case .qwenwork: qwenworkPath
        }
    }

    func selectedModel(for agent: ClipAgent) -> String? { agentModels[agent.rawValue] }

    func setSelectedModel(_ id: String?, for agent: ClipAgent) {
        agentModels[agent.rawValue] = id
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
    let cloudSync: CloudSyncController
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
    @Published private(set) var workTasksLoaded = false
    @Published private(set) var workTasksLoadError: String?
    @Published private(set) var workTasksUpdatedAt: Date?
    @Published var statistics = LibraryStatistics()
    @Published var tokenUsage = TokenUsageStatistics()
    @Published var workTaskEvents: [WorkTaskEvent] = []
    @Published var showingTaskReports = false
    @Published var discoveringTasks = false
    @Published var taskDiscoveryMessage: String?
    /// True when the last discovery failure happened after the batch's Memory was already saved.
    @Published var taskDiscoveryMemorySaved = false
    @Published var taskDiscoveryFailed = false
    @Published var taskIngestionSummary = TaskIngestionSummary()
    @Published var updatingTaskIDs: Set<UUID> = []
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
        return !preview && !dispatching && currentJob == nil && !discoveringTasks && configuringAgentModels.isEmpty && [.ready, .disconnected].contains(state(agent).phase)
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
    @Published var configuringAgentModels: Set<ClipAgent> = []
    @Published var authorizingAccounts: Set<ClipAgent> = []
    var accountAuthorizationTasks: [ClipAgent: Task<Void, Never>] = [:]
    var modelImageCapabilities: [ClipAgent: [String: Bool]] = [:]
    var agentRetryAt: [ClipAgent: Date] = [:]
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
    private var textRecognitionFailures: Set<String> = []
    private var workspaceObservation: AnyCancellable?
    private var backgroundSuspended = false
    var worker: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var refreshOperation: Task<Void, Never>?
    private var refreshAgain = false
    private var forceReconcileRequested = false
    private var lastLibraryVersion: String?
    private var lastTaskVersion: String?
    private var lastStatisticsVersion: String?
    private var lastTokenVersion: String?
    private var lastLibraryRefresh = Date.distantPast
    private var lastStatisticsRefresh = Date.distantPast
    private var lastAnalyticsDays: Int?
    private var lastQuery: String?
    private var lastFilter: CaptureFilter?
    private var selectionBeforeSearch: (entry: UUID?, folder: String?)?
    var taskDiscovery: Task<Void, Never>?
    var organizationTask: Task<Void, Never>?
    var organizationAgent: ClipAgent?
    var discoveryAgent: ClipAgent?
    var cancelledJobs: Set<UUID> = []
    var interruptedJobs: Set<UUID> = []
    var lastCleanup = Date.distantPast

    init(root: URL, preview: Bool, preferences suppliedPreferences: ClipPreferences? = nil) throws {
        self.preview = preview
        store = try LibraryStore(root: root)
        cloudSync = CloudSyncController(store: store, preview: preview)
        mcpEnabled = MemoryMCP.isEnabled(in: root)
        preferences = suppliedPreferences ?? ClipPreferences(preview: preview)
        runtime = AgentRuntime(root: root.appendingPathComponent("Runtime"))
        captureService.onCapture = { [weak self] image, context in
            guard let self else { return }
            do {
                let repeated = self.library.captures.first?.imageID == image.fingerprint
                try await self.store.record(image: image, context: context, agent: self.preferences.enabledAgent ?? .codex, organize: self.preferences.autoOrganize,
                                            filterStrategies: self.preferences.captureSettings.filterStrategies)
                await self.refreshIfNeeded()
                self.startTextRecognition()
                self.captureStatus = repeated ? String(localized: "已记录本次出现，相同画面共用原图") : String(localized: "已保存 \(context.appName) · \(context.date.formatted(date: .omitted, time: .standard))")
            } catch { self.captureStatus = String(localized: "保存失败：\(error.localizedDescription)"); self.notice = error.localizedDescription }
        }
        captureService.onStatus = { [weak self] status in
            guard let self, self.captureStatus != status else { return }
            self.captureStatus = status
        }
        sessionCoordinator.onEvent = { [weak self] event, agent in self?.handle(event, agent: agent) }
        preferencesObservation = preferences.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if preview { captureStatus = String(localized: "界面预览 · 采集已停用") }
        refreshPermissions()
    }

    func start() {
        guard worker == nil else { return }
        textRecognitionFailures.removeAll()
        backgroundSuspended = false
        cloudSync.start()
        let center = NSWorkspace.shared.notificationCenter
        let sleepNames = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
        let wakeNames = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        workspaceObservation = Publishers.MergeMany((sleepNames + wakeNames).map { center.publisher(for: $0) })
            .sink { [weak self] notification in
                let sleeping = sleepNames.contains(notification.name)
                Task { @MainActor in self?.backgroundSuspended = sleeping }
            }
        if !preview, let agent = preferences.enabledAgent { connect(agent) }
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.recoverInterruptedJobs()
                if let agent = preferences.enabledAgent { try await store.handoffQueuedOrganizationJobs(to: agent) }
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
                if !backgroundSuspended { refreshPermissions() }
                if !preview && !backgroundSuspended {
                    await cleanupIfNeeded()
                    await recoverOrganizationIfNeeded()
                    if !processingPaused { await processNext() }
                    await refreshIfNeeded()
                    startTextRecognition()
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        refreshPermissions()
    }

    private func startTextRecognition() {
        guard textWorker == nil else { return }
        textWorker = Task(priority: .utility) { [weak self] in
            defer { self?.textWorker = nil }
            while !Task.isCancelled {
                guard let self else { return }
                if backgroundSuspended { return }
                do {
                    if let image = try await store.nextImageForTextIndex(excluding: textRecognitionFailures) {
                        // Thermal pressure delays only background OCR; explicit document reads still work.
                        if !BackgroundWorkBudget.allowsOCR {
                            try await Task.sleep(for: .seconds(15))
                            continue
                        }
                        do {
                            _ = try await store.recognizeImageText(id: image.id)
                            await refreshIfNeeded()
                            if ProcessInfo.processInfo.isLowPowerModeEnabled { try await Task.sleep(for: .milliseconds(500)) }
                        } catch is CancellationError { return }
                        catch { textRecognitionFailures.insert(image.id) }
                    } else { return }
                } catch is CancellationError { return }
                catch { return }
            }
        }
    }

    func stop() {
        cloudSync.stop()
        workspaceObservation?.cancel()
        workspaceObservation = nil
        worker?.cancel()
        worker = nil
        captureService.stop()
        capturing = false
        textWorker?.cancel()
        searchTask?.cancel()
        refreshOperation?.cancel()
        taskDiscovery?.cancel()
        organizationTask?.cancel()
        accountAuthorizationTasks.values.forEach { $0.cancel() }
        Task { [sessionCoordinator] in await sessionCoordinator.stopAll() }
    }

    func open(_ page: LibraryPage? = nil) {
        if let page { self.page = page }
        onOpenWindow?()
    }

    func state(_ agent: ClipAgent) -> ClipAgentState { agents[agent] ?? .init() }

    /// Explicit reads reconcile disk immediately. Worker ticks use cheap domain versions instead.
    func refresh() async { await requestRefresh(forceReconcile: true) }
    func refreshIfNeeded() async { await requestRefresh(forceReconcile: false) }

    private func requestRefresh(forceReconcile: Bool) async {
        refreshAgain = true
        forceReconcileRequested = forceReconcileRequested || forceReconcile
        if let refreshOperation { await refreshOperation.value; return }
        let operation = Task { [weak self] in
            guard let self else { return }
            while refreshAgain && !Task.isCancelled {
                refreshAgain = false
                let force = forceReconcileRequested
                forceReconcileRequested = false
                await performRefresh(forceReconcile: force)
            }
            // Clear ownership before completing, so a caller cannot join an already-finished refresh.
            refreshOperation = nil
        }
        refreshOperation = operation
        await operation.value
    }

    private func performRefresh(forceReconcile: Bool) async {
        do {
            if let agent = preferences.enabledAgent { try await store.reassignPendingCaptures(to: agent) }
            let versions = try await store.refreshVersions()
            let reconcile = Date().timeIntervalSince(lastLibraryRefresh) >= 60
            let libraryChanged = forceReconcile || reconcile || lastLibraryVersion != versions.library
            // The independent board must remain readable even when a Memory file fails validation.
            if reconcile || lastTaskVersion != versions.tasks || !workTasksLoaded || workTasksLoadError != nil {
                if await refreshWorkTasks() { lastTaskVersion = versions.tasks }
            }
            if libraryChanged {
                let snapshot = try await store.snapshot()
                if library != snapshot { library = snapshot }
                cloudSync.observe(snapshot.entries)
                let nextProposals = try await store.proposals()
                if proposals != nextProposals { proposals = nextProposals }
                lastLibraryVersion = versions.library
                lastLibraryRefresh = Date()
            }
            if reconcile || lastStatisticsVersion != versions.statistics || lastAnalyticsDays != analyticsDays
                || Date().timeIntervalSince(lastStatisticsRefresh) >= 60 {
                let next = try await store.statistics(since: analyticsDays == 0 ? .distantPast : Calendar.current.date(byAdding: .day, value: -analyticsDays, to: Date())!)
                if statistics != next { statistics = next }
                lastStatisticsVersion = versions.statistics
                lastAnalyticsDays = analyticsDays
                lastStatisticsRefresh = Date()
            }
            if reconcile || lastTokenVersion != versions.tokens {
                let next = try await store.tokenUsageStatistics()
                if tokenUsage != next { tokenUsage = next }
                lastTokenVersion = versions.tokens
            }
            let query = search
            let filter = captureFilter
            if libraryChanged || lastQuery != query || lastFilter != filter {
                let found = query.isEmpty && !filter.isActive ? library : try await store.snapshot(query: query, captureFilter: filter)
                if search == query && captureFilter == filter {
                    if results != found { results = found }
                    lastQuery = query
                    lastFilter = filter
                }
            }
        } catch {
            if notice != error.localizedDescription { notice = error.localizedDescription }
        }
    }

    @discardableResult
    private func refreshWorkTasks() async -> Bool {
        do {
            let tasks = try await store.workTasks()
            let events = try await store.workTaskEvents()
            let summary = try await store.taskIngestionSummary()
            let changed = workTasks != tasks || workTaskEvents != events || taskIngestionSummary != summary
            if workTasks != tasks { workTasks = tasks }
            if workTaskEvents != events { workTaskEvents = events }
            if taskIngestionSummary != summary { taskIngestionSummary = summary }
            if !workTasksLoaded { workTasksLoaded = true }
            if workTasksLoadError != nil { workTasksLoadError = nil }
            if changed || workTasksUpdatedAt == nil { workTasksUpdatedAt = Date() }
            return true
        } catch {
            // Keep the last readable board while the normal refresh loop retries.
            if workTasksLoadError != error.localizedDescription { workTasksLoadError = error.localizedDescription }
            if notice != error.localizedDescription { notice = error.localizedDescription }
            return false
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            await self?.refresh()
        }
    }
}
