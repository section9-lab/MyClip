import AppKit
import Combine
@testable import MyClipCore

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

/// Real application worker, SQLite queue and ACP subprocess; no account or model service is used.
@main struct AgentRecoveryTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-AgentRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        func waitUntil(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<400 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw LibraryError.invalidResult("Timed out waiting for the recovery worker")
        }
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/MyClipCoreTests/Fixtures/acp_agent.py")
        let executable = root.appendingPathComponent("opencode")
        func setScenario(_ scenario: String) throws {
            let fixturePath = "'" + fixture.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            try "#!/bin/sh\nexport MYCLIP_ACP_SCENARIO=\(scenario)\nexec /usr/bin/python3 \(fixturePath)\n"
                .write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let suite = "MyClip.AgentRecoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(executable.path, forKey: "myclip.opencodePath")
        let preferences = ClipPreferences(preview: false, defaults: defaults)
        preferences.enabledAgent = .opencode
        let model = try MyClipModel(root: root.appendingPathComponent("Library"), preview: false, preferences: preferences)
        defer { model.stop() }

        // Exercise the complete no-work cycle, not just refreshIfNeeded: an unpublished
        // reservation must prevent reentrancy without toggling the visible dispatcher state.
        model.agents[.opencode]?.phase = .ready
        try await model.store.recordConsolidation()
        await model.refresh()
        var idlePublications = 0
        let idleObservation = model.objectWillChange.sink { idlePublications += 1 }
        for _ in 0..<10 {
            model.refreshPermissions()
            await model.recoverOrganizationIfNeeded()
            await model.processNext()
            await model.refreshIfNeeded()
        }
        check(idlePublications == 0, "Complete idle dispatcher cycles publish no false busy state")
        check(model.organizationTask == nil && !model.dispatching && model.sessionCoordinator.client(.opencode) == nil,
              "Idle checks release reservations without starting an Agent")
        idleObservation.cancel()
        model.agents[.opencode]?.phase = .disconnected

        let graphics = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try CapturedImage(image: graphics.makeImage()!)
        let now = Date()
        for message in ["Internal error: unknown certificate verification error", "certificate verify failed",
                        "SELF_SIGNED_CERT_IN_CHAIN", "unable to verify the first certificate", "fetch failed"] {
            check(RetryPolicy.classify(message: message) == .transient, "Durable transport error is retryable: \(message)")
        }
        check(RetryPolicy.classify(URLError(.serverCertificateUntrusted)) == .transient,
              "Native TLS errors use the same bounded retry policy")
        check(RetryPolicy.classify(message: "Invalid API key: fetch failed") == .permanent,
              "Account errors take precedence over transport wording")

        let limited = try LibraryStore(root: root.appendingPathComponent("Limited"))
        try await limited.record(image: image,
            context: CaptureContext(appName: "Fixture", bundleID: "test.limited", windowTitle: "Limit", windowID: 1,
                                    reason: .manual, date: now), agent: .opencode, organize: true, extractedText: "test")
        let limitedID = try await limited.claimNextJob(immediately: true)!.id
        for _ in 1..<RetryPolicy.maxAttempts {
            try await limited.scheduleRetry(id: limitedID, error: "timeout", at: now)
            _ = try await limited.claimNextJob(immediately: true, jobID: limitedID)
        }
        try await limited.finishJob(id: limitedID, state: .failed, error: "certificate verify failed")
        check(try await !limited.recoverRetryableOrganizationFailure(agent: .opencode),
              "Automatic recovery never resets an exhausted attempt budget")
        check(try await limited.snapshot().queue.paused, "Exhausted retries keep a visible failure for user action")

        try await model.store.record(image: image,
            context: CaptureContext(appName: "Fixture", bundleID: "test.recovery", windowTitle: "Recovery", windowID: 1,
                                    reason: .manual, date: now.addingTimeInterval(-1000)),
            agent: .opencode, organize: true, extractedText: "test")
        await model.refresh()

        try setScenario("connect_certificate")
        model.connect(.opencode)
        try await waitUntil { model.state(.opencode).phase == .failed }
        let retryAt = model.agentRetryAt[.opencode]!
        check(retryAt > now, "A failed connection schedules recovery with backoff")
        check(model.state(.opencode).detail.contains("将自动重试"), "Connection errors explain automatic recovery")
        await model.recoverOrganizationIfNeeded(at: retryAt.addingTimeInterval(-1))
        check(!model.canStartOrganization, "Timer ticks before backoff cannot retry a failed connection")
        model.disableAgent()
        await model.recoverOrganizationIfNeeded(at: retryAt)
        check(model.state(.opencode).phase == .failed, "Disabled Agents do not recover or receive work")
        preferences.enabledAgent = .opencode
        try setScenario("task_recovery_empty")
        await model.recoverOrganizationIfNeeded(at: retryAt)
        check(model.canStartOrganization, "A due connection retry releases the failed-state dispatch gate")
        await model.processNext(immediately: true)
        check(model.library.jobs.first?.state == .completed, "The original Agent reconnects and finishes the waiting batch")
        check(model.agentRetryAt[.opencode] == nil, "A successful connection clears the old retry deadline")
        check(!model.dispatching && model.currentJob == nil, "Recovery releases all dispatcher busy states")

        try setScenario("connect_authentication")
        model.handle(.disconnected(""), agent: .opencode)
        model.connect(.opencode)
        try await waitUntil { model.state(.opencode).phase == .failed }
        check(model.agentRetryAt[.opencode] == nil, "Authentication failure requires user action")
        await model.recoverOrganizationIfNeeded(at: now.addingTimeInterval(100_000))
        check(model.state(.opencode).phase == .failed, "Time passing does not retry an authentication failure")

        try setScenario("prompt_certificate")
        model.connect(.opencode)
        try await waitUntil { model.state(.opencode).available }
        let source = model.library.captures[0]
        let jobID = try await model.store.enqueue(sourceIDs: [source.id], agent: .opencode)
        await model.processNext(immediately: true, jobID: jobID)
        let queued = model.library.jobs.first { $0.id == jobID }!
        check(queued.isAwaitingRetry && queued.attempts == 1 && queued.retryAt != nil,
              "A certificate error during organization requeues the same batch")
        check(!model.processingPaused && model.library.queue.pauseReason == nil,
              "A recoverable certificate error does not stop other waiting batches")
        await model.processNext()
        check(model.library.jobs.first { $0.id == jobID }?.attempts == 1, "Normal dispatch respects the scheduled retry deadline")
        try setScenario("task_recovery_empty")
        await model.processNext(immediately: true, jobID: jobID)
        check(model.library.jobs.first { $0.id == jobID }?.state == .completed, "A later healthy connection settles the same batch")

        // Recreate the screenshot: one queued timeout retry plus a newer certificate failure that stopped everything.
        let olderID = try await model.store.enqueue(sourceIDs: [source.id], agent: .opencode)
        for _ in 1...3 {
            _ = try await model.store.claimNextJob(immediately: true, jobID: olderID)
            try await model.store.scheduleRetry(id: olderID, error: "Agent 响应超时，可以重试。", at: now.addingTimeInterval(-2000))
        }
        let failedID = try await model.store.enqueue(sourceIDs: [source.id], agent: .opencode)
        _ = try await model.store.claimNextJob(immediately: true, jobID: failedID)
        try await model.store.finishJob(id: failedID, state: .failed, error: "Internal error: unknown certificate verification error")
        // Both deadlines elapsed while the previous app version was stopped. Change only this temporary test database.
        let database = try SQLiteConnection(url: model.store.root.appendingPathComponent("Library.sqlite"))
        try database.run("UPDATE job_times SET finished_at=? WHERE id=?", [String(now.addingTimeInterval(-1000).timeIntervalSince1970), failedID.uuidString])
        try database.run("UPDATE organization_queue SET last_started_at=? WHERE id=1", [String(now.addingTimeInterval(-1000).timeIntervalSince1970)])
        await model.refresh()
        check(model.processingPaused, "The fixture reproduces the persisted queue pause")
        try await model.store.setOrganizationPaused(true)
        await model.refresh()
        await model.recoverOrganizationIfNeeded()
        check(model.processingPaused && model.library.jobs.first { $0.id == failedID }?.state == .failed,
              "Automatic recovery preserves a manual pause")
        try await model.store.setOrganizationPaused(true, reason: "Internal error: unknown certificate verification error")
        let restarted = try MyClipModel(root: model.store.root, preview: false, preferences: preferences)
        defer { restarted.stop() }
        // Keep the existing one-time import outside this fixture's worker lifecycle.
        let previousColdStart = UserDefaults.standard.object(forKey: "myclip.coldStartIngestionAttempted")
        UserDefaults.standard.set(true, forKey: "myclip.coldStartIngestionAttempted")
        defer { UserDefaults.standard.set(previousColdStart, forKey: "myclip.coldStartIngestionAttempted") }
        restarted.start()
        try await waitUntil { restarted.library.jobs.contains { $0.id == olderID && $0.state == .completed } }
        check(!restarted.processingPaused, "The actual startup worker automatically lifts a legacy retryable pause")
        let recovered = restarted.library.jobs.first { $0.id == failedID }
        check(recovered?.isAwaitingRetry == true && recovered?.attempts == 1,
              "Startup preserves the certificate batch and its original retry budget")
        check(restarted.library.jobs.first { $0.id == olderID }?.attempts == 4,
              "The previously blocked timeout batch completes its fourth attempt automatically")
        if failures > 0 { throw LibraryError.invalidResult("\(failures) Agent recovery checks failed") }
    }
}
