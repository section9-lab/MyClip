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

/// Real queue, model and ACP processes, with no production library or model calls.
@main struct AgentSwitchingTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-AgentSwitching-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        func waitUntil(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<250 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw LibraryError.invalidResult("Agent switch did not finish within five seconds")
        }
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/MyClipCoreTests/Fixtures/acp_agent.py")
        func command(_ name: String, scenario: String) throws -> URL {
            let executable = root.appendingPathComponent(name)
            let quoted = "'" + fixture.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            try "#!/bin/sh\nexport MYCLIP_ACP_SCENARIO=\(scenario)\nexec /usr/bin/python3 \(quoted)\n"
                .write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return executable
        }
        let slow = try command("opencode", scenario: "hang")
        let fast = try command("codebuddy", scenario: "task_recovery_empty")
        let suite = "MyClip.AgentSwitchingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(slow.path, forKey: "myclip.opencodePath")
        defaults.set(fast.path, forKey: "myclip.workbuddyPath")
        let preferences = ClipPreferences(preview: false, defaults: defaults)
        preferences.enabledAgent = .opencode
        let model = try MyClipModel(root: root.appendingPathComponent("Library"), preview: false, preferences: preferences)
        defer { model.stop() }
        let graphics = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try CapturedImage(image: graphics.makeImage()!)
        try await model.store.record(image: image,
            context: CaptureContext(appName: "Fixture", bundleID: "test.switch", windowTitle: "Switch", windowID: 1,
                                    reason: .manual, date: .now.addingTimeInterval(-1000)),
            agent: .opencode, organize: true, extractedText: "test")
        await model.refresh()
        let run = Task { await model.processNext(immediately: true) }
        try await waitUntil { model.activityText.contains("等待取消") }
        let oldJob = model.currentJob!
        model.disableAgent()
        check(preferences.enabledAgent == nil, "Disable immediately clears the enabled Agent")
        try await waitUntil { !model.dispatching && model.currentJob == nil }
        await run.value
        await model.refresh()
        let stopped = try await model.store.snapshot()
        check(stopped.jobs.first { $0.id == oldJob.id }?.state == .cancelled,
              "Disable ends the old running batch")
        check(stopped.queue.pendingCount == 1 && !stopped.queue.paused,
              "Disable returns unfinished screenshots without pausing the queue")
        check(!model.state(.opencode).busy && model.state(.opencode).sessionID == nil,
              "The disabled Agent stops spinning and releases its session")
        await model.selectDefaultAgent(.workbuddy)
        check(preferences.enabledAgent == .workbuddy, "A different Agent can be selected after disabling")
        await model.processNext(immediately: true)
        let finished = try await model.store.snapshot()
        check(finished.jobs.contains { $0.agent == .workbuddy && $0.state == .completed && $0.sourceIDs == oldJob.sourceIDs },
              "The new Agent completes the same screenshots")
        check(finished.queue.pendingCount == 0 && finished.captures.count == 1,
              "Switching neither loses nor duplicates captures")

        func startBatch(_ scenario: String) async throws -> (Task<Void, Never>, ClipJob) {
            _ = try command("opencode", scenario: scenario)
            preferences.enabledAgent = .opencode
            let id = try await model.store.enqueue(sourceIDs: oldJob.sourceIDs, agent: .opencode)
            await model.refresh()
            let task = Task { await model.processNext(immediately: true, jobID: id, agent: .opencode) }
            try await waitUntil {
                model.currentJob?.id == id && (scenario == "connect_hang"
                    ? model.state(.opencode).phase == .connecting : model.activityText.contains("等待取消"))
            }
            return (task, model.currentJob!)
        }

        let (unresponsive, unresponsiveJob) = try await startBatch("hang_ignore_cancel")
        let stoppingAt = Date()
        model.enable(.workbuddy)
        try await waitUntil { !model.dispatching && model.currentJob == nil }
        await unresponsive.value
        check(Date().timeIntervalSince(stoppingAt) < 3.5, "An Agent ignoring cancel cannot block a switch beyond the shutdown grace period")
        check(try await model.store.snapshot().jobs.first { $0.id == unresponsiveJob.id }?.state == .cancelled,
              "Direct switching stops an unresponsive old Agent")
        await model.processNext(immediately: true)
        check(try await model.store.snapshot().queue.pendingCount == 0, "Direct switching hands unfinished screenshots to the new Agent")

        let (connecting, _) = try await startBatch("connect_hang")
        model.disableAgent()
        try await waitUntil { !model.dispatching && model.currentJob == nil }
        await connecting.value
        check(!model.state(.opencode).busy && model.agentRetryAt[.opencode] == nil,
              "Stopping during connection clears busy state without scheduling a provider failure retry")
        check(try await model.store.snapshot().queue.pendingCount == 1, "Stopping during connection preserves unsubmitted screenshots")
        model.enable(.workbuddy)
        await model.processNext(immediately: true)

        let (usageRun, usageJob) = try await startBatch("cancel_usage")
        model.disableAgent()
        try await waitUntil { !model.dispatching && model.currentJob == nil }
        await usageRun.value
        let usage = try await model.store.executionRecords(jobID: usageJob.id)
        check(usage.first?.usage?.totalTokens == 12 && usage.first?.stopReason == "cancelled",
              "A cooperative cancellation preserves already-spent token usage")
        model.enable(.workbuddy)
        await model.processNext(immediately: true)

        let (rapidRun, _) = try await startBatch("hang_ignore_cancel")
        model.enable(.workbuddy)
        model.disableAgent()
        model.enable(.workbuddy)
        try await waitUntil { !model.dispatching && model.currentJob == nil }
        await rapidRun.value
        check(preferences.enabledAgent == .workbuddy && !model.state(.opencode).busy,
              "Rapid stop/select actions retain the final selection without stale busy state")
        await model.processNext(immediately: true)
        check(try await model.store.snapshot().queue.pendingCount == 0, "Rapid switching returns each source to the queue once")

        let (mismatchedRun, _) = try await startBatch("hang")
        preferences.enabledAgent = .workbuddy // Reproduce an old task left running after a previous switch.
        model.disableAgent()
        try await waitUntil { !model.dispatching && model.currentJob == nil }
        await mismatchedRun.value
        check(!model.state(.opencode).busy, "Disable also stops an old task whose Agent no longer matches the selection")
        model.enable(.workbuddy)
        await model.processNext(immediately: true)

        let (manualRun, manualJob) = try await startBatch("hang")
        model.cancel(manualJob)
        try await waitUntil { !model.dispatching && model.currentJob == nil }
        await manualRun.value
        check(try await model.store.snapshot().queue.pendingCount == 0,
              "Explicitly cancelling one batch still removes it instead of handing it off")

        let queued = try await model.store.enqueue(sourceIDs: oldJob.sourceIDs, agent: .opencode)
        _ = try await model.store.claimNextJob(immediately: true, jobID: queued)
        try await model.store.scheduleRetry(id: queued, error: "timeout", at: .now.addingTimeInterval(600))
        model.enable(.workbuddy)
        try await waitUntil { model.library.jobs.first { $0.id == queued }?.state == .cancelled }
        check(model.library.queue.nextAgent == .workbuddy && model.library.queue.pendingCount == 1,
              "An old Agent's queued retry does not block a newly selected Agent")
        check(model.library.queue.readyAt.map { $0 <= Date() } == true,
              "Handing off a previously running batch does not add another five-minute delay")
        await model.processNext(immediately: true)
        let completedJob = try await model.store.snapshot().jobs.first { $0.state == .completed }!
        try await model.store.interruptOrganizationJob(id: completedJob.id)
        try await model.store.interruptOrganizationJob(id: queued)
        check(try await model.store.snapshot().queue.pendingCount == 0,
              "Completed and already-interrupted jobs cannot enqueue duplicate screenshots")

        _ = try command("opencode", scenario: "hang")
        preferences.enabledAgent = .opencode
        let stageID = try await model.store.enqueueTaskIngestion(response: "bad JSON", sourceIDs: Set(oldJob.sourceIDs), memoryIDs: [])
        let repair = Task { await model.processNext(immediately: true) }
        try await waitUntil { model.discoveringTasks && model.state(.opencode).phase == .working }
        model.enable(.workbuddy)
        try await waitUntil { !model.dispatching && !model.discoveringTasks }
        await repair.value
        let stage = try await model.store.taskIngestion(stageID)
        check(stage.state == .pending && stage.attempts == 0,
              "Switching during task repair releases the durable stage without consuming a retry")
        await model.processNext(immediately: true)
        check(try await model.store.taskIngestion(stageID).state == .completed,
              "The new Agent can finish the interrupted task repair")
        check(model.notice == nil, "Switching does not surface cancellation as an application error")

        let fresh = try LibraryStore(root: root.appendingPathComponent("Fresh"))
        try await fresh.record(image: image,
            context: CaptureContext(appName: "Fixture", bundleID: "test.fresh", windowTitle: "Fresh", windowID: 2,
                                    reason: .manual, date: .now), agent: .opencode, organize: true)
        let freshJob = try await fresh.claimNextJob(immediately: true)!
        try await fresh.setOrganizationPaused(true)
        try await fresh.interruptOrganizationJob(id: freshJob.id)
        let freshQueue = try await fresh.organizationQueue()
        check(freshQueue.pendingCount == 1 && freshQueue.readyAt.map { $0 <= Date() } == true,
              "Even a just-captured interrupted image is eligible immediately after handoff")
        check(freshQueue.paused && freshQueue.pauseReason == nil, "Handing off work preserves an explicit manual pause")
        print("Agent switching checks: \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}
