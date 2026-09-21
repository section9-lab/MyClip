import AppKit
import MyClipCore

// Keep capture outside these checks; exercise the real model, store, and ACP process.
@MainActor
final class FocusedCaptureService {
    var hasScreenPermission = false
    var hasAccessibilityPermission = false
    var isRunning = false
    var onCapture: ((CapturedImage, CaptureContext) async -> Void)?
    var onStatus: ((String) -> Void)?
    func configure(settings: CaptureSettings, excludedBundleIDs: Set<String>) {}
    func requestScreenPermission() {}
    func requestAccessibilityPermission() {}
    func start() -> Bool { false }
    func stop() {}
}

@main
struct AgentActivationTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-AgentTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        func waitUntil(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            check(false, "Timed out waiting for the test adapter")
        }
        let discoveryRoot = root.appendingPathComponent("Discovery")
        let discoveryBin = discoveryRoot.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: discoveryBin, withIntermediateDirectories: true)
        let codexApp = discoveryRoot.appendingPathComponent("Renamed Codex.app")
        let bundledCLI = codexApp.appendingPathComponent("Contents/Resources/codex")
        try FileManager.default.createDirectory(at: bundledCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        let discovery = AgentRuntime(root: discoveryRoot, searchPaths: [], desktopApplications: [.codex: codexApp])
        check(discovery.availability(of: .claude, customPath: "") == .missing, "Discovery does not invent an installed Agent")
        check(discovery.availability(of: .codex, customPath: "") == .desktopOnly, "A desktop app without an executable is not a usable Agent")
        try "#!/bin/sh\nexit 0\n".write(to: bundledCLI, atomically: true, encoding: .utf8)
        check(discovery.availability(of: .codex, customPath: "") == .desktopOnly, "A non-executable CLI is not advertised as available")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundledCLI.path)
        check(discovery.availability(of: .codex, customPath: "") == .commandLine, "Discovery finds the CLI bundled in a renamed desktop app")
        check(discovery.sessionCommand(for: .codex, customPath: "")?.executable == bundledCLI, "Connections use the same bundled CLI that discovery finds")
        let claudeCLI = discoveryBin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: claudeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claudeCLI.path)
        check(discovery.availability(of: .claude, customPath: "") == .commandLine, "Discovery finds locally installed Claude Code")
        check(discovery.availability(of: .claude, customPath: discoveryRoot.appendingPathComponent("missing-adapter").path) == .missing, "An invalid custom adapter is not silently replaced by another installation")
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/MyClipCoreTests/Fixtures/acp_agent.py")
        func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        for agent in ClipAgent.allCases {
            let script = root.appendingPathComponent(agent.executableName)
            let record = root.appendingPathComponent("\(agent.rawValue).json")
            try "#!/bin/sh\nexport MYCLIP_ACP_CONVERSATIONS=\(shellQuote(record.path))\nexport MYCLIP_ACP_SCENARIO=conversation_delayed\nexec /usr/bin/python3 \(shellQuote(fixture.path))\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        let previousEnabled = UserDefaults.standard.object(forKey: "myclip.enabledAgent")
        let previousCodexPreference = UserDefaults.standard.object(forKey: "myclip.codexPath")
        defer {
            UserDefaults.standard.set(previousEnabled, forKey: "myclip.enabledAgent")
            UserDefaults.standard.set(previousCodexPreference, forKey: "myclip.codexPath")
        }
        UserDefaults.standard.removeObject(forKey: "myclip.enabledAgent")
        UserDefaults.standard.setVolatileDomain([
            "myclip.agent": "codex", "myclip.autoOrganize": true,
            "myclip.codexPath": root.appendingPathComponent("codex-acp").path,
            "myclip.claudePath": root.appendingPathComponent("claude-agent-acp").path
        ], forName: UserDefaults.argumentDomain)
        func requests(_ agent: ClipAgent, method: String) throws -> [[String: Any]] {
            let log = root.appendingPathComponent("\(agent.rawValue).json.requests")
            guard FileManager.default.fileExists(atPath: log.path) else { return [] }
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
                .filter { $0["method"] as? String == method }
        }
        let model = try MyClipModel(root: root.appendingPathComponent("Library"), preview: false)
        model.refreshAgentAvailability()
        check(ClipAgent.allCases.allSatisfy { model.localAgents[$0] == .connector }, "Discovery recognizes both configured adapters")
        check(model.preferences.enabledAgent == nil, "A legacy default preference does not implicitly enable an Agent")
        model.enable(.claude)
        check(model.preferences.enabledAgent == nil, "An unconnected Agent cannot be enabled")
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try CapturedImage(image: context.makeImage()!)
        try await model.store.record(image: image,
            context: CaptureContext(appName: "Test", bundleID: "test", windowTitle: "Activation", windowID: 1,
                reason: .pointerIdle, date: Date().addingTimeInterval(-240)),
            agent: .codex, organize: true, extractedText: "test")
        await model.refresh()
        check(!model.canOrganizeNow, "Pending captures wait until an Agent is explicitly enabled")
        for agent in ClipAgent.allCases {
            model.connect(agent)
            try await waitUntil { model.state(agent).available || model.state(agent).phase == .failed }
            check(model.state(agent).available, "\(agent.name) can connect independently")
        }
        check(!model.canOrganizeNow, "Connecting both Agents does not enable organization")
        model.start()
        try await Task.sleep(for: .milliseconds(750))
        let snapshot = try await model.store.snapshot()
        check(snapshot.jobs.isEmpty && snapshot.queue.pendingCount == 1, "Startup keeps captures queued when no Agent is enabled")
        for agent in ClipAgent.allCases {
            check(try requests(agent, method: "session/prompt").isEmpty, "Connection does not send a task to \(agent.name)")
            let mode = try requests(agent, method: "session/set_mode").last?["params"] as? [String: Any]
            check(mode?["modeId"] as? String == (agent == .codex ? "agent-full-access" : "bypassPermissions"), "\(agent.name) defaults to full access before its first task")
        }
        check(AgentRuntime(root: root).environment["INITIAL_AGENT_MODE"] == "agent-full-access", "Codex starts in full access mode")
        model.discoverTasks()
        check(!model.discoveringTasks, "Task discovery also waits for an enabled Agent")
        model.enqueue(snapshot.captures[0])
        try await Task.sleep(for: .milliseconds(50))
        check(try await model.store.snapshot().jobs.isEmpty, "Manual organization cannot bypass activation")

        try await model.store.setOrganizationPaused(true)
        await model.refresh()
        model.enable(.codex)
        check(model.preferences.enabledAgent == .codex && model.canOrganizeNow, "Enabling a connected Agent allows organization")
        model.connect(.claude)
        check(model.preferences.enabledAgent == .codex, "Connecting another Agent preserves the enabled selection")
        model.enable(.claude)
        await model.refresh()
        check(model.preferences.enabledAgent == .claude, "Enabling another Agent switches the single active selection")
        check(model.state(.codex).available && model.state(.claude).available, "Switching does not disconnect the other Agent")
        check(model.library.queue.pendingCounts == [.claude: 1], "Waiting captures move to the enabled Agent")

        model.organizeNow()
        try await waitUntil { model.currentJob?.agent == .claude && (try? requests(.claude, method: "session/prompt").count) == 1 }
        let running = model.currentJob
        model.disableAgent()
        check(model.preferences.enabledAgent == nil && model.currentJob?.id == running?.id, "Disabling stops new work without cancelling the current batch")
        model.enable(.codex)
        check(model.currentJob?.agent == .claude, "Switching preserves the Agent for the running batch")
        try await model.store.record(image: image,
            context: CaptureContext(appName: "Test", bundleID: "test", windowTitle: "Next batch", windowID: 2,
                reason: .pointerIdle), agent: .claude, organize: true, extractedText: "test")
        await model.refresh()
        check(model.library.queue.pendingCounts == [.codex: 1], "New waiting captures follow the selection while another batch finishes")
        try await waitUntil { model.currentJob == nil && !model.dispatching }
        let completed = try await model.store.snapshot().jobs.first { $0.id == running?.id }
        check(completed?.state == .completed && completed?.agent == .claude, "The previous Agent completes its batch normally")
        let execution = try await model.store.executionRecords(jobID: completed!.id)
        check(execution.count == 1 && execution.first?.stopReason == "end_turn", "Organization automatically saves a completed execution record")
        let firstClaudePrompt = try requests(.claude, method: "session/prompt").first?["params"] as? [String: Any]
        check(execution.first?.sessionID == firstClaudePrompt?["sessionId"] as? String, "Execution history retains the exact Agent session")
        check(model.state(.claude).sessionID == nil, "Completed batches release their temporary session")
        let firstBlocks = firstClaudePrompt?["prompt"] as? [[String: Any]] ?? []
        check(firstBlocks.allSatisfy { $0["type"] as? String == "text" }, "Mouse captures send OCR without image attachments")

        model.organizeNow()
        try await waitUntil { (try? requests(.codex, method: "session/prompt").count) == 1 }
        try await waitUntil { model.currentJob == nil && !model.dispatching }
        let switched = try await model.store.snapshot()
        check(switched.jobs.first?.agent == .codex && switched.jobs.first?.state == .completed, "The next batch is sent to the newly enabled Agent")

        let retryID = try await model.store.enqueue(sourceIDs: [snapshot.captures[0].id], agent: .claude)
        await model.refresh()
        check(!model.canOrganizeNow, "An old queued job waits for its original Agent to be enabled")
        try await model.store.finishJob(id: retryID, state: .failed, error: "Test failure")
        let retry = try await model.store.snapshot().jobs.first { $0.id == retryID }!
        check(!model.canRetry(retry), "A retry cannot silently use an inactive Agent")
        model.retry(retry)
        try await Task.sleep(for: .milliseconds(50))
        check(try await model.store.snapshot().jobs.first { $0.id == retryID }?.state == .failed, "Rejecting an inactive retry preserves its state")
        model.enable(.claude)
        check(model.canRetry(retry), "Re-enabling the original Agent allows its retry")
        model.retry(retry)
        try await waitUntil { (try? requests(.claude, method: "session/prompt").count) == 2 }
        try await waitUntil { model.currentJob == nil && !model.dispatching }
        check(try await model.store.snapshot().jobs.first { $0.id == retryID }?.state == .completed, "The retry completes on its original, enabled Agent")
        check(try await model.store.executionRecords(jobID: retryID).count == 1, "A retried job saves its own execution history")
        let claudePrompts = try requests(.claude, method: "session/prompt").compactMap { $0["params"] as? [String: Any] }
        check(Set(claudePrompts.compactMap { $0["sessionId"] as? String }).count == 2, "Each batch gets a fresh session")
        for request in try requests(.claude, method: "session/new") {
            let params = request["params"] as? [String: Any]
            let meta = params?["_meta"] as? [String: Any]
            let claude = meta?["claudeCode"] as? [String: Any]
            let options = claude?["options"] as? [String: Any]
            check(options?["persistSession"] as? Bool == false, "Claude session persistence is explicitly disabled")
        }
        check(ClipPreferences(preview: false).enabledAgent == .claude, "The enabled selection is persisted independently of connections")
        for agent in ClipAgent.allCases {
            let sessions = try requests(agent, method: "session/new").count
            let modes = try requests(agent, method: "session/set_mode").compactMap { $0["params"] as? [String: Any] }
            check(modes.count == sessions && modes.allSatisfy { $0["modeId"] as? String == (agent == .codex ? "agent-full-access" : "bypassPermissions") }, "Every \(agent.name) batch and retry uses full access")
        }
        model.stop()
        try await Task.sleep(for: .milliseconds(100))

        let restarted = try MyClipModel(root: root.appendingPathComponent("Library"), preview: false)
        restarted.start()
        try await waitUntil { restarted.state(.claude).available }
        check(!restarted.state(.codex).available, "Startup reconnects only the previously enabled Agent")
        check(try requests(.claude, method: "session/resume").isEmpty, "Startup never restores previous conversation history")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Sessions/claude.json").path), "Temporary sessions do not create resumable session records")
        restarted.disableAgent()
        check(ClipPreferences(preview: false).enabledAgent == nil, "Disabling clears the saved activation")
        restarted.stop()
        try await Task.sleep(for: .milliseconds(100))
        let disabledRestart = try MyClipModel(root: root.appendingPathComponent("Library"), preview: false)
        disabledRestart.start()
        try await Task.sleep(for: .milliseconds(150))
        check(ClipAgent.allCases.allSatisfy { !disabledRestart.state($0).available }, "A disabled Agent stays disabled after restart")
        disabledRestart.stop()
        try await Task.sleep(for: .milliseconds(100))
        let onboarding = try MyClipModel(root: root.appendingPathComponent("Onboarding"), preview: false)
        await onboarding.selectDefaultAgent(.claude)
        check(onboarding.state(.claude).available && onboarding.preferences.enabledAgent == .claude, "Onboarding connects and explicitly enables the selected default Agent")
        check(ClipPreferences(preview: false).enabledAgent == .claude, "The onboarding default survives a restart")
        let failingAdapter = root.appendingPathComponent("failed-adapter")
        try "#!/bin/sh\nexit 1\n".write(to: failingAdapter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failingAdapter.path)
        let previousCodexPath = onboarding.preferences.codexPath
        onboarding.preferences.codexPath = failingAdapter.path
        await onboarding.selectDefaultAgent(.codex)
        check(onboarding.state(.codex).phase == .failed, "A failed onboarding connection displays an error")
        check(onboarding.preferences.enabledAgent == .claude && onboarding.selectingDefaultAgent == nil, "Connection failure preserves the working default and allows retry")
        onboarding.preferences.codexPath = previousCodexPath
        await onboarding.selectDefaultAgent(.codex)
        check(onboarding.preferences.enabledAgent == .codex, "Retry can switch the default after a successful connection")
        onboarding.stop()
        onboarding.disableAgent()
        try await Task.sleep(for: .milliseconds(100))
        print("Agent activation checks: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
