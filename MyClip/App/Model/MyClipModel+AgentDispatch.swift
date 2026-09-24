import AppKit
import MyClipCore

extension MyClipModel {
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
                agents[agent]?.detail = String(localized: "正在安装连接组件…")
                try await runtime.install(agent)
            }
            _ = try await connectedClient(agent)
            enable(agent)
        } catch { setFailure(agent, error) }
    }

    func discoverTasks() {
        guard canStartOrganization, let agent = preferences.enabledAgent else { return }
        discoveringTasks = true
        discoveryAgent = agent
        taskDiscoveryFailed = false
        taskDiscoveryMessage = String(localized: "AI 正在发现待办并更新任务进展…")
        taskDiscoveryMemorySaved = false
        taskDiscovery = Task {
            defer { discoveringTasks = false; discoveryAgent = nil; taskDiscovery = nil }
            do {
                let snapshot = try await store.snapshot()
                let memories = Array(snapshot.entries.prefix(200))
                guard !memories.isEmpty else { taskDiscoveryMessage = String(localized: "还没有可分析的 Memory。"); return }
                try await withAgentSession(agent) { client, session in
                    try Task.checkCancellation()
                    agents[agent]?.phase = .working
                    agents[agent]?.detail = String(localized: "正在识别工作任务")
                    let existing = try await store.workTasks()
                    let response = try await trackedPrompt(client, agent: agent, session: session,
                        text: TaskPrompt.discoveryPrompt(memories: memories, tasks: existing), images: [])
                    try Task.checkCancellation()
                    guard response.stopReason == "end_turn" else { throw LibraryError.invalidResult(String(localized: "任务识别未完成，请重试。")) }
                    let count = try await store.ingestTaskSuggestions(TaskResponse.parse(response.text), allowedSourceIDs: [], allowedMemoryIDs: Set(memories.map(\.id)))
                    agents[agent]?.phase = .ready
                    agents[agent]?.detail = String(localized: "已就绪 · 每批独立整理")
                    taskDiscoveryMessage = count == 0 ? String(localized: "已分析 \(memories.count) 篇 Memory，没有新的任务进展。") : String(localized: "已分析 \(memories.count) 篇 Memory，更新了 \(count) 项任务的线索或进展。")
                }
            } catch {
                if Task.isCancelled { taskDiscoveryMessage = String(localized: "任务识别已取消。") }
                else { taskDiscoveryMessage = String(localized: "任务识别失败：\(error.localizedDescription)"); taskDiscoveryFailed = true }
                agents[agent]?.phase = .disconnected
                agents[agent]?.detail = String(localized: "尚未连接")
            }
            await refresh()
        }
    }

    func cancelTaskDiscovery() {
        taskDiscovery?.cancel()
        guard let agent = discoveryAgent, let client = sessionCoordinator.client(agent) else { return }
        Task {
            if let session = state(agent).sessionID { try? await client.cancel(sessionID: session) }
            await client.close()
        }
    }

    func connect(_ agent: ClipAgent) {
        guard !state(agent).busy, !state(agent).available, !preview else { return }
        agents[agent]?.phase = .connecting
        agents[agent]?.detail = String(localized: "正在连接…")
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

    func copyClaudeLoginCommand() { copyLoginCommand(for: .claude) }

    /// Agents that log in through their own terminal command rather than an ACP auth method.
    func hasLoginCommand(_ agent: ClipAgent) -> Bool { agent != .codex && isInstalled(agent) }

    func copyLoginCommand(for agent: ClipAgent) {
        guard let command = runtime.command(for: agent, customPath: preferences.path(for: agent)) else { return }
        let quotedPath = "'" + command.executable.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let login: String
        switch agent {
        case .claude: login = quotedPath + " --cli auth login --claudeai"
        case .opencode: login = quotedPath + " auth login"
        case .cursor: login = quotedPath + " login"
        case .codex: return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(login, forType: .string)
        notice = String(localized: "登录命令已复制。请在终端运行并完成登录，然后回到 MyClip 连接 \(agent.name)。")
    }

    func openClaudeDesktop() {
        guard !preview else { return }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            notice = String(localized: "未找到 Claude Desktop，请先安装桌面端。")
            return
        }
        if !NSWorkspace.shared.open(application) { notice = String(localized: "无法打开 Claude Desktop，请尝试从“应用程序”中打开。") }
    }

    func install(_ agent: ClipAgent) {
        guard !state(agent).busy, !preview, !agents.values.contains(where: { $0.phase == .installing }) else { return }
        agents[agent]?.phase = .installing
        agents[agent]?.detail = String(localized: "正在安装连接组件…")
        Task {
            do {
                try await runtime.install(agent)
                agents[agent]?.phase = .disconnected
                agents[agent]?.detail = String(localized: "组件已安装，可以连接")
                _ = try await connectedClient(agent)
            } catch { setFailure(agent, error) }
        }
    }

    func authenticate(_ agent: ClipAgent, method: ACPAuthMethod) {
        guard let client = sessionCoordinator.client(agent), !state(agent).busy else { return }
        agents[agent]?.phase = .connecting
        agents[agent]?.detail = String(localized: "等待登录完成…")
        Task {
            do {
                try await client.authenticate(methodID: method.id)
                _ = try await session(for: agent, using: client)
                agents[agent]?.phase = .ready
                agents[agent]?.detail = String(localized: "已就绪 · 每批独立整理")
            } catch { setFailure(agent, error) }
        }
    }

    func resolve(_ permission: ClipPermission, optionID: String?) {
        guard let client = sessionCoordinator.client(permission.agent) else { return }
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

    func canRetry(_ job: ClipJob) -> Bool {
        guard let agent = preferences.enabledAgent, agent == job.agent, !preview, !dispatching, currentJob == nil, !discoveringTasks else { return false }
        return !state(agent).busy
    }

    func retry(_ job: ClipJob) {
        Task {
            guard canRetry(job) else { return }
            if state(job.agent).phase == .failed {
                agents[job.agent]?.phase = .disconnected
                agents[job.agent]?.detail = String(localized: "正在重新连接…")
            }
            dispatching = true
            do {
                try await store.retryJob(id: job.id)
                dispatching = false
                await processNext(immediately: true, jobID: job.id, agent: job.agent)
                await refresh()
            } catch { dispatching = false; notice = error.localizedDescription }
        }
    }

    /// A dream can be asked for whenever an Agent is enabled and no dream is already waiting or running.
    var canDreamNow: Bool {
        !preview && preferences.enabledAgent != nil && library.queue.pauseReason == nil
            && !library.jobs.contains { $0.kind == .dream && ($0.state == .queued || $0.state == .running) }
    }

    /// Queues a dream ahead of waiting screenshots and starts it as soon as the current batch, if any, finishes.
    func dreamNow() {
        guard canDreamNow, let agent = preferences.enabledAgent else { return }
        Task {
            do {
                guard try await store.enqueueDreamNow(agent: agent) != nil else { return }
                await refresh()
                if !processingPaused { await processNext(immediately: true) }
            } catch { notice = error.localizedDescription }
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
                return String(localized: "正在整理 \(job.sourceIDs.count) 条 · 另有 \(count) 条等待")
            }
            return String(localized: "\(count) 条等待 · 正在使用 \(job.agent.name)")
        }
        guard let enabled = preferences.enabledAgent else { return String(localized: "等待选择 Agent · \(count) 条等待") }
        if library.queue.pauseReason != nil { return String(localized: "整理已停止 · \(count) 条等待") }
        if processingPaused { return String(localized: "整理已暂停 · \(count) 条等待") }
        switch state(enabled).phase {
        case .failed: return String(localized: "\(enabled.name) 出错 · \(count) 条等待")
        case .connecting: return String(localized: "正在连接 \(enabled.name) · \(count) 条等待")
        case .installing: return String(localized: "正在安装 \(enabled.name) 连接组件 · \(count) 条等待")
        default: break
        }
        guard count > 0 else { return String(localized: "等待新的截图") }
        if discoveringTasks { return String(localized: "\(count) 条等待 · 正在识别任务") }
        if let next = library.queue.nextAgent, next != enabled { return String(localized: "\(count) 条等待 · 请启用 \(next.name) 继续原任务") }
        if let agent, library.queue.nextAgent != agent { return String(localized: "\(count) 条等待 · 前方还有其他 Agent 的截图") }
        let seconds = max(0, Int(ceil((library.queue.readyAt ?? date).timeIntervalSince(date))))
        let countdown = seconds == 0 ? String(localized: "即将") : String(localized: "约 \(seconds / 60) 分 \(seconds % 60) 秒后")
        if let retrying = jobAwaitingRetry {
            return String(localized: "\(count) 条等待 · \(countdown)第 \(retrying.attempts + 1) 次尝试上一批")
        }
        return String(localized: "\(count) 条等待 · \(countdown)整理")
    }

    func cancel(_ job: ClipJob) {
        cancelledJobs.insert(job.id)
        Task {
            if currentJob?.id == job.id, let client = sessionCoordinator.client(job.agent) {
                permissions.removeAll { $0.agent == job.agent }
                await client.cancelAndClose(sessionID: state(job.agent).sessionID)
                if sessionCoordinator.isCurrent(client, for: job.agent) {
                    _ = await sessionCoordinator.teardown(job.agent)
                    agents[job.agent]?.sessionID = nil
                }
            }
            do { try await store.finishJob(id: job.id, state: .cancelled); await refresh() }
            catch { notice = error.localizedDescription }
        }
    }

    private func connectedClient(_ agent: ClipAgent) async throws -> ACPClient {
        if let client = sessionCoordinator.client(agent), state(agent).available { return client }
        guard let command = try runtime.organizationCommand(for: agent, customPath: preferences.path(for: agent)) else {
            throw ACPError.disconnected(String(localized: "请先在连接设置中安装组件。"))
        }
        await releaseSession(agent)
        agents[agent]?.phase = .connecting
        agents[agent]?.detail = String(localized: "正在连接…")
        let (client, handshake) = try await sessionCoordinator.open(agent, command: command)
        agents[agent]?.authMethods = handshake.authMethods
        guard handshake.supportsImages else { throw ACPError.unsupportedImages }
        _ = try await session(for: agent, using: client)
        agents[agent]?.phase = .ready
        agents[agent]?.detail = String(localized: "已就绪 · 每批独立整理")
        return client
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
        try await client.setMode(sessionID: id, modeID: agent.fullAccessModeID)
        agents[agent]?.sessionID = id
        agents[agent]?.sessionIsEphemeral = true
        return id
    }

    private func releaseSession(_ agent: ClipAgent) async {
        await sessionCoordinator.teardown(agent)
        agents[agent]?.sessionID = nil
        permissions.removeAll { $0.agent == agent }
    }

    /// Connects (or reuses) `agent`'s client, ensures a session, runs `body`, then always releases the
    /// session afterward — on success, on a thrown error, and even if connecting or preparing the session
    /// itself fails. Rethrows whatever failed, after releasing.
    private func withAgentSession(_ agent: ClipAgent, run body: (ACPClient, String) async throws -> Void) async throws {
        do {
            let client = try await connectedClient(agent)
            let session = try await session(for: agent, using: client)
            try await body(client, session)
            await releaseSession(agent)
        } catch {
            await releaseSession(agent)
            throw error
        }
    }

    private static let coldStartIngestionKey = "myclip.coldStartIngestionAttempted"

    /// One-time cold start: when Memory is still empty, seed it from the user's existing Desktop/Documents files
    /// through the same organize-into-Memory agent flow used for screenshots. Silent on failure; retries next launch
    /// only for transient errors, matching the app's no-alert self-healing behavior.
    func runColdStartIngestionIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !preview, !defaults.bool(forKey: Self.coldStartIngestionKey), let agent = preferences.enabledAgent else { return }
        // Reading the folders without access would raise the system prompt unasked; wait until onboarding grants it.
        guard PermissionCoordinator.hasFolderAccess() else { return }
        do {
            guard try await store.isMemoryEmpty() else { defaults.set(true, forKey: Self.coldStartIngestionKey); return }
            let files = ColdStartIngestion.scan()
            guard !files.isEmpty else { defaults.set(true, forKey: Self.coldStartIngestionKey); return }
            try await withAgentSession(agent) { client, session in
                do {
                    let result = try await trackedPrompt(client, agent: agent, session: session,
                        text: MemoryPrompt.coldStartPrompt(files: files.map { (label: $0.label, text: $0.text) }), images: [], jobID: nil)
                    guard result.stopReason == "end_turn" else { throw LibraryError.agentStopped }
                    _ = try await store.synchronizeMemoryFiles()
                    defaults.set(true, forKey: Self.coldStartIngestionKey)
                } catch {
                    if RetryPolicy.classify(error) != .transient { defaults.set(true, forKey: Self.coldStartIngestionKey) }
                }
            }
        } catch {
            if RetryPolicy.classify(error) != .transient { defaults.set(true, forKey: Self.coldStartIngestionKey) }
        }
    }

    func processNext(immediately: Bool = false, jobID: UUID? = nil, agent: ClipAgent? = nil) async {
        guard canStartOrganization, let enabled = preferences.enabledAgent else { return }
        // Reserve dispatch before the first await so timer ticks and repeated clicks cannot race.
        dispatching = true
        defer { dispatching = false }
        do {
            try await store.reassignPendingCaptures(to: enabled)
            // Once a day, when nothing is waiting and the user has been away, the queue gets a dream.
            if jobID == nil { try await store.enqueueDreamIfDue(agent: enabled) }
            let queue = try await store.organizationQueue()
            guard let target = agent ?? queue.nextAgent, target == preferences.enabledAgent,
                  !state(target).busy, state(target).phase != .failed else { return }
            if !immediately {
                guard !queue.paused, let readyAt = queue.readyAt, Date() >= readyAt else { return }
            }
            if jobID == nil { try await store.prepareOrganizationText() }
            guard target == preferences.enabledAgent, !state(target).busy, state(target).phase != .failed,
                  let job = try await store.claimNextJob(immediately: immediately, jobID: jobID) else { return }
            currentJob = job
            currentJobStartedAt = Date()
            activityText = String(localized: "正在连接 \(job.agent.name) ACP…")
            await refresh()
            if job.kind == .dream {
                await dream(job)
                await releaseSession(job.agent)
                cancelledJobs.remove(job.id)
                currentJob = nil
                currentJobStartedAt = nil
                activityText = ""
                await refresh()
                return
            }
            do {
                let previousRevisions = try await store.beginMemoryEditing(jobID: job.id)
                try await withAgentSession(job.agent) { client, session in
                    if cancelledJobs.contains(job.id) { throw CancellationError() }
                    agents[job.agent]?.phase = .working
                    agents[job.agent]?.detail = String(localized: "正在整理 \(job.sourceIDs.count) 条记录")
                    activityText = String(localized: "正在读取 \(job.sourceIDs.count) 条记录…")
                    let inputs = try await store.organizationInputs(jobID: job.id)
                    let data = try await Task.detached(priority: .utility) {
                        try inputs.filter(\.usesImage).map { try Data(contentsOf: $0.capture.imageURL) }
                    }.value
                    activityText = String(localized: "正在准备 \(job.agent.name) 会话…")
                    let existingTasks = try await store.workTasks()
                    let handoff = try await store.organizationHandoff()
                    activityText = String(localized: "已提交 \(data.count) 张图片、\(inputs.count - data.count) 条文本，等待 \(job.agent.name) 回复…")
                    let result = try await trackedPrompt(client, agent: job.agent, session: session,
                        text: MemoryPrompt.organizeBatchPrompt(inputs: inputs, handoff: handoff, previousAttempt: job.attempts > 1 ? job.error : nil, tasks: existingTasks),
                        images: data, jobID: job.id)
                    if cancelledJobs.contains(job.id) || result.stopReason == "cancelled" { throw CancellationError() }
                    guard result.stopReason == "end_turn" else { throw LibraryError.agentStopped }
                    activityText = String(localized: "正在同步 Memory 文件…")
                    let changedCount = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: previousRevisions)
                    do {
                        let memories = try await store.snapshot().entries
                        _ = try await store.ingestTaskSuggestions(TaskResponse.parse(result.text), allowedSourceIDs: Set(job.sourceIDs), allowedMemoryIDs: Set(memories.map(\.id)))
                        if taskDiscoveryFailed { taskDiscoveryMessage = nil; taskDiscoveryFailed = false }
                    } catch {
                        taskDiscoveryMessage = String(localized: "Memory 已保存；任务识别未完成：\(error.localizedDescription)")
                        taskDiscoveryMemorySaved = true
                        taskDiscoveryFailed = true
                    }
                    agents[job.agent]?.phase = .ready
                    agents[job.agent]?.detail = changedCount == 0 ? String(localized: "已整理，Memory 无需更新") : String(localized: "已更新 \(changedCount) 个 Memory 文件")
                    agents[job.agent]?.lastCompleted = Date()
                }
            } catch {
                if cancelledJobs.contains(job.id) || error is CancellationError {
                    try await store.finishJob(id: job.id, state: .cancelled)
                    agents[job.agent]?.phase = .disconnected
                    agents[job.agent]?.detail = String(localized: "整理已取消")
                } else if RetryPolicy.classify(error) == .transient, RetryPolicy.canRetry(afterAttempt: job.attempts) {
                    // Timeouts, dropped connections and overloaded providers get another run without stopping the queue.
                    let delay = RetryPolicy.delay(afterAttempt: job.attempts)
                    try await store.scheduleRetry(id: job.id, error: error.localizedDescription, at: Date().addingTimeInterval(delay))
                    agents[job.agent]?.phase = .disconnected
                    agents[job.agent]?.detail = String(localized: "\(firstLine(error)) · 将自动重试")
                } else {
                    let attemptsNote = job.attempts > 1 ? String(localized: "已自动重试 \(job.attempts - 1) 次仍未成功。") : ""
                    try await store.finishJob(id: job.id, state: .failed, error: attemptsNote + error.localizedDescription)
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

    /// Runs a dream turn by turn. It never pauses the queue or marks the Agent failed: a dropped connection gets one
    /// more try later, anything else ends the dream with what it managed, and tomorrow brings another.
    private func dream(_ job: ClipJob) async {
        var before: [UUID: Int] = [:]
        do {
            guard let plan = job.dreamPlan else { throw LibraryError.invalidResult(String(localized: "做梦计划缺失。")) }
            let turns = MemoryPrompt.dreamTurns(plan: plan, handoff: try await store.organizationHandoff())
            before = try await store.beginConsolidation()
            try await withAgentSession(job.agent) { client, session in
                agents[job.agent]?.phase = .working
                for (index, turn) in turns.enumerated() {
                    if cancelledJobs.contains(job.id) { throw CancellationError() }
                    activityText = String(localized: "做梦中 · \(turn.title)（\(index + 1)/\(turns.count)）")
                    agents[job.agent]?.detail = activityText
                    let result = try await trackedPrompt(client, agent: job.agent, session: session, text: turn.text, images: [],
                                                         jobID: job.id, maximumDuration: MemoryDream.turnLimit)
                    if cancelledJobs.contains(job.id) || result.stopReason == "cancelled" { throw CancellationError() }
                    guard result.stopReason == "end_turn" else { throw LibraryError.agentStopped }
                }
            }
            let changed = try await store.finishDream(jobID: job.id, previousRevisions: before)
            agents[job.agent]?.phase = .ready
            agents[job.agent]?.detail = String(localized: "做梦完成，更新了 \(changed) 个 Memory 文件")
            agents[job.agent]?.lastCompleted = Date()
        } catch {
            do {
                if cancelledJobs.contains(job.id) || error is CancellationError {
                    try await store.settleConsolidation(previousRevisions: before)
                    try await store.finishJob(id: job.id, state: .cancelled)
                } else if RetryPolicy.classify(error) == .transient, job.attempts < MemoryDream.maxAttempts {
                    try await store.settleConsolidation(previousRevisions: before)
                    try await store.scheduleRetry(id: job.id, error: error.localizedDescription, at: Date().addingTimeInterval(MemoryDream.retryDelay))
                } else {
                    try await store.finishDream(jobID: job.id, previousRevisions: before, error: String(localized: "\(firstLine(error))。明天会再做。"))
                }
            } catch { notice = error.localizedDescription }
            agents[job.agent]?.phase = .ready
            agents[job.agent]?.detail = String(localized: "做梦未完成，稍后再试")
        }
    }

    private func trackedPrompt(_ client: ACPClient, agent: ClipAgent, session: String, text: String,
                               images: [Data], jobID: UUID? = nil, maximumDuration: Duration? = nil) async throws -> ACPCompletion {
        try await store.executePrompt(client, agent: agent, sessionID: session, text: text, images: images, jobID: jobID, maximumDuration: maximumDuration)
    }

    func organizationActivity(at date: Date) -> String {
        guard let started = currentJobStartedAt else { return activityText }
        let elapsed = max(0, Int(date.timeIntervalSince(started)))
        let idle = max(0, Int(date.timeIntervalSince(lastActivityAt)))
        let waiting = idle >= 30 ? String(localized: " · 已有 \(idle) 秒未收到新进度") : ""
        return String(localized: "\(activityText) · 已用时 \(elapsed / 60) 分 \(elapsed % 60) 秒\(waiting)")
    }

    private func updateActivity(_ text: String, session: String, agent: ClipAgent) {
        guard state(agent).sessionID == session else { return }
        if currentJob?.agent == agent { activityText = text }
        else if discoveryAgent == agent { taskDiscoveryMessage = text }
    }

    func handle(_ event: ACPEvent, agent: ClipAgent) {
        switch event {
        case .message(let session, _): updateActivity(String(localized: "\(agent.name) 正在生成结果…"), session: session, agent: agent)
        case .thinking(let session): updateActivity(String(localized: "\(agent.name) 正在思考…"), session: session, agent: agent)
        case .tool(let session, let title, _): updateActivity(title, session: session, agent: agent)
        case .permission(let request):
            permissions.removeAll { $0.agent == agent && $0.request.id == request.id }
            permissions.append(ClipPermission(agent: agent, request: request))
            agents[agent]?.phase = .permission
            agents[agent]?.detail = String(localized: "需要你的确认")
        case .permissionResolved(let id):
            permissions.removeAll { $0.agent == agent && $0.request.id == id }
            agents[agent]?.phase = currentJob?.agent == agent || discoveryAgent == agent ? .working : .ready
            agents[agent]?.detail = discoveryAgent == agent ? String(localized: "正在识别工作任务") : currentJob?.agent == agent ? String(localized: "正在整理") : String(localized: "已连接")
        case .disconnected(let message):
            permissions.removeAll { $0.agent == agent }
            agents[agent]?.sessionID = nil
            agents[agent]?.phase = .disconnected
            agents[agent]?.detail = message.isEmpty ? String(localized: "连接已关闭") : message
        }
    }

    private func setFailure(_ agent: ClipAgent, _ error: any Error) {
        agents[agent]?.phase = .failed
        agents[agent]?.detail = firstLine(error)
    }

    private func firstLine(_ error: any Error) -> String {
        error.localizedDescription.components(separatedBy: "\n").first ?? error.localizedDescription
    }

    /// "重试并继续": re-run the batch that stopped the queue, or just lift the pause when nothing failed.
    func resumeAfterFailure() {
        if let job = latestFailedJob, canRetry(job) { retry(job); return }
        if let agent = preferences.enabledAgent, state(agent).phase == .failed { connect(agent) }
        processingPaused = false
    }
}
