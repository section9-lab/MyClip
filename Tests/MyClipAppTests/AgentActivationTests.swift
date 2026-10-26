import AppKit
import SwiftUI
import MyClipCore

// Language switching restarts the real app; keep that OS boundary outside the onboarding checks.
@MainActor enum MyClipAppDelegate {
    static func relaunch() {}
}

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
        check(discovery.availability(of: .codex, customPath: "") == .desktopEngine, "Discovery finds the CLI bundled in a renamed desktop app")
        check(discovery.sessionCommand(for: .codex, customPath: "")?.executable == bundledCLI, "Connections use the same bundled CLI that discovery finds")
        let claudeCLI = discoveryBin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: claudeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claudeCLI.path)
        check(discovery.availability(of: .claude, customPath: "") == .commandLine, "Discovery finds locally installed Claude Code")
        check(discovery.availability(of: .claude, customPath: discoveryRoot.appendingPathComponent("missing-adapter").path) == .missing, "An invalid custom adapter is not silently replaced by another installation")
        let nvmHome = discoveryRoot.appendingPathComponent("Home")
        let nvmRoot = nvmHome.appendingPathComponent(".nvm")
        let nvmBin = nvmRoot.appendingPathComponent("versions/node/v24.22.1/bin")
        func writeExecutable(_ url: URL, contents: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let modernCodexApp = discoveryRoot.appendingPathComponent("Renamed ChatGPT.app")
        let modernCodex = modernCodexApp.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        try writeExecutable(modernCodex, contents: "#!/bin/sh\nexit 0\n")
        let modernDiscovery = AgentRuntime(root: discoveryRoot, searchPaths: [], desktopApplications: [.codex: modernCodexApp])
        check(modernDiscovery.availability(of: .codex, customPath: "") == .desktopEngine,
              "The current desktop Codex package is available without installing an external CLI")
        check(modernDiscovery.sessionCommand(for: .codex, customPath: "")?.executable == modernCodex,
              "Codex connections and MCP setup share current desktop-package discovery")
        check(LocalAgentAvailability.desktopEngine.canSelect && !LocalAgentAvailability.desktopEngine.hasConnector,
              "A desktop Codex engine can prepare its missing connector from the application")
        try writeExecutable(modernDiscovery.binDirectory.appendingPathComponent("codex"), contents: "#!/bin/sh\nexit 0\n")
        try writeExecutable(modernDiscovery.binDirectory.appendingPathComponent("codex-acp"), contents: "#!/bin/sh\nexit 0\n")
        check(modernDiscovery.sessionCommand(for: .codex, customPath: "")?.executable == modernCodex
              && modernDiscovery.availability(of: .codex, customPath: "") == .desktopConnector,
              "Preparing a connector cannot shadow the desktop engine with its bundled Codex dependency")
        try FileManager.default.removeItem(at: modernCodex)
        let nestedCodex = modernCodexApp.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        try writeExecutable(nestedCodex, contents: "#!/bin/sh\nexit 0\n")
        check(BundledCodexExecutable.find(in: modernCodexApp) == nestedCodex,
              "Codex discovery can fall back to its nested native executable")
        check(ClipAgent.allCases.count == 6, "The Agent catalog includes all six onboarding choices")
        let workbuddyApp = discoveryRoot.appendingPathComponent("WorkBuddy.app")
        let qwenworkApp = discoveryRoot.appendingPathComponent("Renamed QwenWork.app")
        let desktopDiscovery = AgentRuntime(root: discoveryRoot, searchPaths: [],
            desktopApplications: [.workbuddy: workbuddyApp, .qwenwork: qwenworkApp])
        check(desktopDiscovery.availability(of: .workbuddy, customPath: "") == .accountSetup,
              "WorkBuddy account setup is available without its companion CLI")
        check(desktopDiscovery.availability(of: .qwenwork, customPath: "") == .accountSetup,
              "QwenWork account setup does not require a bundled desktop engine")
        let workbuddyHost = workbuddyApp.appendingPathComponent("Contents/MacOS/Buddy Runtime")
        try writeExecutable(workbuddyHost, contents: "#!/bin/sh\nexit 0\n")
        let workbuddyInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Buddy Runtime", "CFBundleIdentifier": "myclip.tests.workbuddy"], format: .xml, options: 0)
        try workbuddyInfo.write(to: workbuddyApp.appendingPathComponent("Contents/Info.plist"))
        let workbuddyCLI = workbuddyApp.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli")
        try writeExecutable(workbuddyCLI.appendingPathComponent("bin/codebuddy"), contents: "// Desktop CLI entry\n")
        check(desktopDiscovery.availability(of: .workbuddy, customPath: "") == .accountSetup,
              "Incomplete desktop components do not prevent managed account setup")
        try writeExecutable(workbuddyCLI.appendingPathComponent("dist/codebuddy-lite-wb.mjs"), contents: "// WorkBuddy bundle\n")
        check(desktopDiscovery.availability(of: .workbuddy, customPath: "") == .accountSetup,
              "Host-managed desktop components are not mistaken for prepared MyClip components")
        check(desktopDiscovery.command(for: .workbuddy, customPath: "") == nil,
              "WorkBuddy never launches a desktop component without a verified external connection")
        check(desktopDiscovery.command(for: .workbuddy, customPath: discoveryRoot.appendingPathComponent("missing-workbuddy").path) == nil,
              "An invalid custom WorkBuddy path cannot silently fall back to the desktop engine")
        let qwenworkHost = qwenworkApp.appendingPathComponent("Contents/MacOS/QwenWork")
        try writeExecutable(qwenworkHost, contents: "#!/bin/sh\nexit 0\n")
        let appInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "QwenWork", "CFBundleIdentifier": "myclip.tests.qwenwork"], format: .xml, options: 0)
        try appInfo.write(to: qwenworkApp.appendingPathComponent("Contents/Info.plist"))
        let qwenworkVersion = qwenworkApp.appendingPathComponent("Contents/Resources/agent-sdk/components/flash-cli/1.18.18")
        let qwenworkEngine = qwenworkVersion.appendingPathComponent("runtime/flash-cli-acp.mjs")
        try writeExecutable(qwenworkEngine, contents: "// ACP entry point\n")
        let manifest = #"{"protocol":"acp-stdio","runtime":{"kind":"electron-node","entrypoint":"runtime/flash-cli-acp.mjs","args":[],"env":{"ELECTRON_RUN_AS_NODE":"1"}}}"#
        try manifest.write(to: qwenworkVersion.appendingPathComponent("engine-manifest.json"), atomically: true, encoding: .utf8)
        let qwenworkCommand = desktopDiscovery.command(for: .qwenwork, customPath: "")
        check(qwenworkCommand == nil,
              "QwenWork accounts wait for managed components instead of launching an unauthenticated desktop engine")
        check(desktopDiscovery.command(for: .qwenwork, customPath: discoveryRoot.appendingPathComponent("missing-qwenwork").path) == nil,
              "An invalid custom QwenWork path never falls back to the bundled engine")
        try writeExecutable(discoveryBin.appendingPathComponent("codebuddy"), contents: "#!/bin/sh\nexit 0\n")
        check(desktopDiscovery.availability(of: .workbuddy, customPath: "") == .accountSetup,
              "A personal WorkBuddy CLI does not replace the managed account connection")
        check(desktopDiscovery.command(for: .workbuddy, customPath: discoveryBin.appendingPathComponent("codebuddy").path)?.arguments == ["--acp", "--no-session-persistence"],
              "WorkBuddy uses its official ACP entry point without persisting temporary sessions")
        // Model a Finder launch: the inherited PATH has no Node version manager entries.
        let guiDiscovery = AgentRuntime(root: discoveryRoot, desktopApplications: [:], homeDirectory: nvmHome,
            inheritedEnvironment: ["PATH": "/usr/bin:/bin"])
        for version in ["v9.11.2", "v22.9.0", "v24.22.1"] {
            let executable = nvmRoot.appendingPathComponent("versions/node/\(version)/bin/opencode")
            try writeExecutable(executable, contents: "#!/usr/bin/env node\n")
        }
        try writeExecutable(nvmBin.appendingPathComponent("node"), contents: "#!/bin/sh\nprintf 'nvm-node-found'\n")
        check(guiDiscovery.availability(of: .opencode, customPath: "") == .connector, "Finder discovery finds OpenCode installed through nvm")
        let nvmCommand = guiDiscovery.command(for: .opencode, customPath: "")
        check(nvmCommand?.executable.resolvingSymlinksInPath() == nvmBin.appendingPathComponent("opencode").resolvingSymlinksInPath(),
              "nvm fallback prefers the newest installed version numerically")
        check(nvmCommand?.arguments == ["acp"], "Discovered OpenCode keeps its ACP arguments")
        check(guiDiscovery.sessionCommand(for: .opencode, customPath: "")?.executable == nvmCommand?.executable,
              "Session commands use the same nvm installation as discovery")
        let accountRuntime = AgentRuntime(root: discoveryRoot.appendingPathComponent("AccountRuntime"), searchPaths: [nvmBin.path],
            desktopApplications: [.workbuddy: workbuddyApp, .qwenwork: qwenworkApp])
        for agent in [ClipAgent.workbuddy, .qwenwork] {
            check(accountRuntime.availability(of: agent, customPath: "") == .accountSetup,
                  "\(agent.name) account setup does not assume the user's Node/OpenCode is a compatible managed component")
            check(accountRuntime.command(for: agent, customPath: "") == nil,
                  "\(agent.name) waits for verified components before advertising readiness")
            check(accountRuntime.usesAccountBridge(agent, customPath: ""),
                  "\(agent.name) keeps account authorization separate from desktop installation discovery")
            check(accountRuntime.command(for: agent, customPath: "/missing/custom") == nil,
                  "\(agent.name) custom commands never silently become an account bridge")
        }
        check(SubscriptionAgentCommand.allowsAuthorization(URL(string: "https://gateway.qwenwork.cn/device/selectAccounts")!, provider: .qwenwork),
              "Qwen authorization accepts its product endpoint")
        check(SubscriptionAgentCommand.allowsAuthorization(URL(string: "https://www.workbuddy.cn/login")!, provider: .workbuddy),
              "WorkBuddy authorization accepts its product endpoint")
        for url in ["http://www.workbuddy.cn/login", "https://www.workbuddy.cn.evil.example/login", "https://evil.example/login",
                    "https://user@www.workbuddy.cn/login", "https://www.workbuddy.cn:1234/login"] {
            check(!SubscriptionAgentCommand.allowsAuthorization(URL(string: url)!, provider: .workbuddy),
                  "Account authorization rejects an unrelated or unsafe URL")
        }
        if let nvmCommand {
            let process = Process()
            let output = Pipe()
            process.executableURL = nvmCommand.executable
            process.environment = nvmCommand.environment
            process.standardOutput = output
            try process.run()
            let contents = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            check(process.terminationStatus == 0 && String(decoding: contents, as: UTF8.self) == "nvm-node-found",
                  "A discovered npm CLI can resolve Node when launched with the Agent environment")
        }
        var inheritedDiscovery = guiDiscovery
        let selectedBin = nvmRoot.appendingPathComponent("versions/node/v22.9.0/bin").path
        inheritedDiscovery.inheritedEnvironment["PATH"] = selectedBin + ":/usr/bin:/bin:" + selectedBin
        check(inheritedDiscovery.command(for: .opencode, customPath: "")?.executable.path == selectedBin + "/opencode",
              "An inherited PATH preserves the shell's selected Node version")
        let inheritedPaths = (inheritedDiscovery.environment["PATH"] ?? "").split(separator: ":")
        check(inheritedPaths.count == Set(inheritedPaths).count, "Agent PATH does not repeat inherited or discovered directories")
        var customNvmDiscovery = guiDiscovery
        let customNvm = discoveryRoot.appendingPathComponent("CustomNVM")
        let customOpenCode = customNvm.appendingPathComponent("versions/node/v24.22.1/bin/opencode")
        try writeExecutable(customOpenCode, contents: "#!/bin/sh\nexit 0\n")
        customNvmDiscovery.inheritedEnvironment["NVM_DIR"] = customNvm.path
        check(customNvmDiscovery.command(for: .opencode, customPath: "")?.executable.resolvingSymlinksInPath() == customOpenCode.resolvingSymlinksInPath(),
              "Discovery respects a custom NVM_DIR")
        customNvmDiscovery.searchPaths = []
        check(customNvmDiscovery.command(for: .opencode, customPath: "") == nil,
              "Explicit search paths remain isolated from inherited PATH and nvm")
        check(guiDiscovery.command(for: .opencode, customPath: discoveryRoot.appendingPathComponent("missing-opencode").path) == nil,
              "An invalid custom OpenCode path is not replaced by an nvm installation")
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
            "myclip.claudePath": root.appendingPathComponent("claude-agent-acp").path,
            "myclip.opencodePath": root.appendingPathComponent("opencode").path,
            "myclip.cursorPath": root.appendingPathComponent("cursor-agent").path,
            "myclip.workbuddyPath": root.appendingPathComponent("codebuddy").path,
            "myclip.qwenworkPath": root.appendingPathComponent("qwenwork").path
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
            check(mode?["modeId"] as? String == agent.fullAccessModeID, "\(agent.name) defaults to full access before its first task")
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
        check(firstBlocks.filter { $0["type"] as? String == "image" }.count == 1,
              "Mouse captures send the original screenshot")

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
            check(modes.count == sessions && modes.allSatisfy { $0["modeId"] as? String == agent.fullAccessModeID }, "Every \(agent.name) batch and retry uses full access")
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

        let choosing = try MyClipModel(root: root.appendingPathComponent("OnboardingSelection"), preview: false)
        defer { choosing.stop() }
        let selection = OnboardingAgentSelection()
        selection.restore(nil)
        let previousOpenCodeConnections = try requests(.opencode, method: "initialize").count
        let previousQwenWorkConnections = try requests(.qwenwork, method: "initialize").count
        selection.select(.opencode)
        selection.select(.qwenwork)
        selection.restore(.claude)
        check(selection.selectedAgent == .qwenwork, "Returning to onboarding preserves its uncommitted selection")
        check(choosing.preferences.enabledAgent == nil && choosing.agents.values.allSatisfy { $0.phase == .disconnected },
              "Selecting and switching cards never connects or enables an Agent")
        check(try requests(.opencode, method: "initialize").count == previousOpenCodeConnections &&
              requests(.qwenwork, method: "initialize").count == previousQwenWorkConnections,
              "Changing the onboarding selection never launches an Agent process")
        check(await selection.start(using: choosing), "Start using completes after connecting the final selection")
        check(choosing.preferences.enabledAgent == .qwenwork && choosing.state(.qwenwork).available,
              "Start using connects and enables the final selected Agent")
        check(try requests(.opencode, method: "initialize").count == previousOpenCodeConnections &&
              requests(.qwenwork, method: "initialize").count == previousQwenWorkConnections + 1,
              "Start using launches only the final selected Agent once")
        selection.select(.codex)
        choosing.preferences.codexPath = failingAdapter.path
        check(!(await selection.start(using: choosing)), "A failed connection keeps the setup guide open")
        check(choosing.preferences.enabledAgent == .qwenwork && !selection.starting,
              "A failed start preserves the working Agent and allows another attempt")
        choosing.preferences.codexPath = previousCodexPath
        check(await selection.start(using: choosing), "Start using can retry after a failed connection")
        choosing.stop()
        choosing.disableAgent()
        let skipping = OnboardingAgentSelection()
        check(await skipping.start(using: choosing), "Start using can skip Agent setup without a selection")
        check(choosing.preferences.enabledAgent == nil, "Skipping Agent setup does not enable an Agent")
        let iconNames = ["OpenAIBlossom", "CursorIcon", "WorkBuddyIcon", "QwenWorkIcon"]
        let iconImages = iconNames.compactMap { name -> NSImage? in
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("MyClip/Assets.xcassets/\(name).imageset")
            guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
                  let file = contents.first(where: { $0.pathExtension != "json" }), let image = NSImage(contentsOf: file) else { return nil }
            image.setName(name)
            return image
        }
        defer { withExtendedLifetime(iconImages) {} }
        for width: CGFloat in [344, 520] {
            let host = NSHostingView(rootView: OnboardingAgentPicker(model: choosing, selection: selection)
                .padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let height = host.fittingSize.height
            check(height > 0 && height <= 400, "Six Agent cards fit the onboarding column at width \(Int(width))")
            host.setFrameSize(NSSize(width: width, height: max(1, height)))
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let imageURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent("build/app-tests/onboarding-agents-\(Int(width)).png")
                    try png.write(to: imageURL)
                }
            }
            window.close()
        }
        try await Task.sleep(for: .milliseconds(100))
        print("Agent activation checks: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
