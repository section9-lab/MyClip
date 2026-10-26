import AppKit
import MyClipCore

@MainActor enum MyClipAppDelegate { static func relaunch() {} }
@MainActor final class FocusedCaptureService {
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

private actor FixtureAccountStorage: AgentAccountStorage {
    private var value = Data(#"{"uid":"fixture","access":"fixture-original"}"#.utf8)
    private var reads = 0
    private var saves = 0
    func read() -> Data? { reads += 1; return value }
    func save(_ data: Data) { saves += 1; value = data }
    func counts() -> (Int, Int) { (reads, saves) }
}

/// Real ACP subprocesses and application model, with an isolated library and preference suite.
@main struct AgentModelTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-ModelTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MyClip.AgentModelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            print("\(value ? "PASS" : "FAIL") \(message)")
            if !value { failures += 1 }
        }
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/MyClipCoreTests/Fixtures/acp_agent.py")
        func command(_ scenario: String) -> ACPCommand {
            ACPCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path],
                       environment: ["MYCLIP_ACP_SCENARIO": scenario])
        }
        func client(_ scenario: String) async throws -> (ACPClient, String) {
            let client = ACPClient()
            _ = try await client.connect(command: command(scenario))
            return (client, try await client.newSession(directory: root))
        }
        let accountFixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/SubscriptionAgent/account-fixture.py")
        for allowed in [false, true] {
            let storage = FixtureAccountStorage()
            let accountClient = ACPClient(accountStorage: storage)
            var accountCommand = ACPCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [accountFixture.path],
                environment: ["FIXTURE_ACCOUNT_ALLOWED": allowed ? "1" : "0"])
            if allowed { accountCommand.accountContext = AgentAccountContext(provider: .qwenwork, scope: root) }
            let events = Task { () -> (Bool, Double?) in
                var sawAuthorization = false
                for await event in accountClient.events {
                    if case .authorization = event { sawAuthorization = true }
                    if case .account(let info) = event { return (sawAuthorization, info.creditsRemaining) }
                }
                return (sawAuthorization, nil)
            }
            _ = try await accountClient.connect(command: accountCommand)
            try await accountClient.authenticate(methodID: "fixture")
            let (reads, saves) = await storage.counts()
            if allowed {
                let (opened, remaining) = await events.value
                check(reads == 1 && saves == 1 && opened, "Only an explicitly scoped account bridge can read, rotate and authorize its credential")
                check(remaining == 42.5, "Remaining-only quota is preserved without inventing total or used credits")
            } else {
                check(reads == 0 && saves == 0, "Ordinary Agent processes cannot request account credentials or open authorization URLs")
                events.cancel()
            }
            await accountClient.close()
        }
        let (modern, modernSession) = try await client("models_modern")
        for scenario in ["terminal_provider_error", "terminal_provider_warning"] {
            let (provider, providerSession) = try await client(scenario)
            do {
                let result = try await provider.prompt(sessionID: providerSession, text: "fixture only", images: [])
                check(scenario == "terminal_provider_warning" && result.stopReason == "end_turn", "Recovered provider warnings may complete normally")
            } catch {
                check(scenario == "terminal_provider_error" && error.localizedDescription.contains("model_not_found"), "A structured provider failure with end_turn is rejected instead of reported successful")
            }
            await provider.close()
        }
        let catalog = await modern.modelSelection(sessionID: modernSession)
        check(catalog.options.map(\.id) == ["fixture/default", "fixture/vision", "fixture/rejected", "fixture/flat"], "Live grouped and flat model options preserve order and deduplicate IDs")
        check(catalog.options[0].group == "Fixture provider" && catalog.options[0].description == "Default description", "Provider names and descriptions survive parsing")
        check(catalog.currentID == "fixture/default" && catalog.options.allSatisfy { $0.supportsImages == nil }, "Current model comes from the Agent and image capability stays unknown unless declared")
        try await modern.setModel(sessionID: modernSession, modelID: "fixture/vision")
        check(await modern.modelSelection(sessionID: modernSession).currentID == "fixture/vision", "Modern setter uses the returned config ID and confirms the current model")
        do { try await modern.setModel(sessionID: modernSession, modelID: "invented"); check(false, "Unlisted model must be rejected") }
        catch { check(true, "Unlisted model is rejected instead of guessed") }
        do { try await modern.setModel(sessionID: modernSession, modelID: "fixture/rejected"); check(false, "Rejected model must fail") }
        catch { check(await modern.modelSelection(sessionID: modernSession).currentID == "fixture/vision", "RPC rejection preserves the confirmed current model") }
        await modern.close()
        let (legacy, legacySession) = try await client("models_legacy")
        check(await legacy.modelSelection(sessionID: legacySession).usesLegacyAPI, "Older Agents expose their availableModels catalog")
        try await legacy.setModel(sessionID: legacySession, modelID: "fixture/vision")
        check(await legacy.modelSelection(sessionID: legacySession).currentID == "fixture/vision", "Legacy set_model acknowledgement selects the requested model")
        await legacy.close()
        let (unconfirmed, unconfirmedSession) = try await client("models_unconfirmed")
        do { try await unconfirmed.setModel(sessionID: unconfirmedSession, modelID: "fixture/vision"); check(false, "Missing confirmation must fail") }
        catch { check(true, "A modern setter without confirmation does not report success") }
        await unconfirmed.close()
        for scenario in ["models_notification", "models_removed"] {
            let (live, session) = try await client(scenario)
            _ = try await live.prompt(sessionID: session, text: "fixture only", images: [])
            let updated = await live.modelSelection(sessionID: session)
            check(scenario == "models_removed" ? !updated.canSelect && updated.options.isEmpty : updated.currentID == "fixture/flat", "Full config notifications refresh current model and remove obsolete options: \(scenario)")
            await live.close()
        }
        let (hanging, hangingSession) = try await client("models_hang")
        let prompt = Task { try await hanging.prompt(sessionID: hangingSession, text: "wait", images: []) }
        try await Task.sleep(for: .milliseconds(100))
        do { try await hanging.setModel(sessionID: hangingSession, modelID: "fixture/vision"); check(false, "Busy session must reject model changes") }
        catch { check(true, "An active prompt cannot change models") }
        try await hanging.cancel(sessionID: hangingSession)
        _ = try await prompt.value
        await hanging.close()
        let (unsupported, unsupportedSession) = try await client("success")
        check(await unsupported.modelSelection(sessionID: unsupportedSession).options.isEmpty, "Agents without a catalog have no invented fallback models")
        await unsupported.close()
        let capabilities = try OpenCodeModelCatalog.imageCapabilities(data: Data(#"{"provider":{"models":{"text":{"attachment":false,"modalities":{"input":["text"]}},"vision":{"modalities":{"input":["text","image"]}},"unknown":{"attachment":true}}}}"#.utf8))
        check(capabilities["provider/text"] == false && capabilities["provider/vision"] == true && capabilities["provider/unknown"] == nil, "Local capability metadata uses exact provider IDs and does not equate attachments with vision")

        let preferences = ClipPreferences(preview: false, defaults: defaults)
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        for agent in ClipAgent.allCases {
            let script = root.appendingPathComponent(agent.executableName)
            let scenario = agent == .claude ? "models_legacy" : "models_modern"
            try "#!/bin/sh\nexport MYCLIP_ACP_SCENARIO=\(scenario)\nexport MYCLIP_ACP_CONVERSATIONS=\(quote(root.appendingPathComponent(agent.rawValue + ".json").path))\nexec /usr/bin/python3 \(quote(fixture.path))\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            defaults.set(script.path, forKey: "myclip.\(agent.rawValue)Path")
        }
        let configured = ClipPreferences(preview: false, defaults: defaults)
        let model = try MyClipModel(root: root.appendingPathComponent("Library"), preview: false, preferences: configured)
        defer { model.stop() }
        func requests(_ agent: ClipAgent, _ method: String) throws -> [[String: Any]] {
            let file = root.appendingPathComponent(agent.rawValue + ".json.requests")
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            return try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter { $0["method"] as? String == method }
        }
        for agent in ClipAgent.allCases {
            await model.loadAgentModels(agent)
            check(model.state(agent).modelSelection.canSelect, "\(agent.name) loads a live model catalog through its own connection")
            let sentPrompts = try requests(agent, "session/prompt")
            check(model.preferences.enabledAgent == nil && sentPrompts.isEmpty, "Loading \(agent.name) models never enables it or sends a prompt")
            check(await model.selectAgentModel(agent, modelID: "fixture/vision"), "\(agent.name) can select a returned model")
            let saved = ClipPreferences(preview: false, defaults: defaults)
            check(saved.selectedModel(for: agent) == "fixture/vision", "\(agent.name) persists its confirmed selection")
            check(!(await model.selectAgentModel(agent, modelID: "invented")) && model.preferences.selectedModel(for: agent) == "fixture/vision", "\(agent.name) retains its saved choice when the new model is unavailable")
            await model.loadAgentModels(agent, refresh: true)
            check(model.state(agent).modelSelection.currentID == "fixture/vision", "\(agent.name) reapplies its saved model on a fresh session")
            let setter = agent == .claude ? "session/set_model" : "session/set_config_option"
            check(try requests(agent, setter).count >= 2, "\(agent.name) sends model selection to the correct protocol setter")
        }
        check(preferences.agentModels.isEmpty, "Independent preference instances do not mutate an in-memory snapshot")
        check(ClipPreferences(preview: false, defaults: defaults).agentModels.count == ClipAgent.allCases.count, "All Agent selections coexist independently")
        check(!(await model.selectAgentModel(.cursor, modelID: "fixture/rejected")) && model.preferences.selectedModel(for: .cursor) == "fixture/vision", "A provider RPC error never replaces the persisted choice")
        await model.loadAgentModels(.cursor, refresh: true)
        check(await model.selectAgentModel(.codex, modelID: nil), "Following the Agent default opens a fresh session")
        check(model.preferences.selectedModel(for: .codex) == nil && model.state(.codex).modelSelection.currentID == "fixture/default" && model.preferences.selectedModel(for: .claude) == "fixture/vision", "Resetting one Agent does not change another Agent's model")
        model.agents[.cursor]?.phase = .working
        let beforeBusy = try requests(.cursor, "session/new").count
        check(!(await model.selectAgentModel(.cursor, modelID: "fixture/flat")), "Application rejects model changes while organizing")
        check(try requests(.cursor, "session/new").count == beforeBusy, "A rejected busy switch does not disturb the running session")
        model.agents[.cursor]?.phase = .ready
        model.preferences.setSelectedModel("removed/model", for: .workbuddy)
        await model.loadAgentModels(.workbuddy, refresh: true)
        check(model.state(.workbuddy).phase == .failed && model.state(.workbuddy).modelError != nil && model.preferences.selectedModel(for: .workbuddy) == "removed/model", "An obsolete saved model blocks execution without silently falling back")
        check(await model.selectAgentModel(.workbuddy, modelID: "fixture/flat"), "The live catalog allows recovery from an obsolete saved model")

        // A declared text-only current model must fail before even sending the image prompt.
        var selection = model.state(.opencode).modelSelection
        selection.options = selection.options.map { option in var copy = option; copy.supportsImages = false; return copy }
        model.agents[.opencode]?.modelSelection = selection
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        try await model.store.record(image: CapturedImage(image: context.makeImage()!),
            context: CaptureContext(appName: "Fixture", bundleID: "fixture", windowTitle: "Model check", windowID: 1, reason: .manual),
            agent: .opencode, organize: true, extractedText: "fixture")
        model.enable(.opencode)
        await model.refresh()
        await model.processNext(immediately: true)
        check(try requests(.opencode, "session/prompt").isEmpty, "Known text-only models never receive screenshot prompts")
        check(try await model.store.snapshot().jobs.first?.state == .failed, "A blocked image batch is failed instead of marked completed")
        let providerError = root.appendingPathComponent("provider-error-adapter")
        try "#!/bin/sh\nexport MYCLIP_ACP_SCENARIO=terminal_provider_error\nexec /usr/bin/python3 \(quote(fixture.path))\n"
            .write(to: providerError, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: providerError.path)
        model.preferences.qwenworkPath = providerError.path
        model.preferences.setSelectedModel(nil, for: .qwenwork)
        await model.loadAgentModels(.qwenwork, refresh: true)
        let source = try await model.store.snapshot().captures.first!.id
        let failedJob = try await model.store.enqueue(sourceIDs: [source], agent: .qwenwork)
        model.preferences.enabledAgent = .qwenwork
        await model.processNext(immediately: true, jobID: failedJob, agent: .qwenwork)
        let providerSnapshot = try await model.store.snapshot()
        let providerRecords = try await model.store.executionRecords(jobID: failedJob)
        check(providerSnapshot.jobs.first(where: { $0.id == failedJob })?.state == .failed,
              "A provider failure cannot mark an image organization job completed with no Memory changes")
        check(providerRecords.last?.error?.contains("model_not_found") == true && providerRecords.last?.stopReason == nil,
              "The execution record preserves the provider error instead of a successful stop reason")
        let slow = root.appendingPathComponent("slow-adapter")
        try "#!/bin/sh\nexport MYCLIP_ACP_SCENARIO=models_slow\nexec /usr/bin/python3 \(quote(fixture.path))\n"
            .write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slow.path)
        model.preferences.codexPath = slow.path
        let loading = Task { await model.loadAgentModels(.codex, refresh: true) }
        try await Task.sleep(for: .milliseconds(100))
        loading.cancel()
        await loading.value
        check(model.state(.codex).phase == .disconnected && model.state(.codex).modelError == nil && model.configuringAgentModels.isEmpty,
              "Closing a loading picker releases the session without marking the Agent failed")
        print("Agent model checks: \(failures) failure(s)")
        if failures != 0 { exit(1) }
    }
}
