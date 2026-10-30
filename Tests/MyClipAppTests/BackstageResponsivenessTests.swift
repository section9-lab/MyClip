import AppKit
import SwiftUI
import MyClipCore
@testable import MyClip

/// A separate timer detects a wedged main run loop even when the UI test's next await never resumes.
private final class MainRunLoopProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingAt: TimeInterval?
    private var longestDelay: TimeInterval = 0
    private var timer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "myclip.backstage-test.watchdog"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [self] in
            lock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            let send = pendingAt == nil
            if send { pendingAt = now }
            let delay = now - (pendingAt ?? now)
            longestDelay = max(longestDelay, delay)
            lock.unlock()
            if delay > 4 {
                print("FAIL Automatic organization blocked the main run loop for more than four seconds")
                fflush(stdout)
                exit(1)
            }
            if send {
                DispatchQueue.main.async { [self] in
                    lock.lock()
                    if let pendingAt { longestDelay = max(longestDelay, ProcessInfo.processInfo.systemUptime - pendingAt) }
                    pendingAt = nil
                    lock.unlock()
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() -> TimeInterval {
        timer?.setEventHandler {}
        timer?.cancel(); timer = nil
        lock.lock(); defer { lock.unlock() }
        return longestDelay
    }
}

@MainActor
private final class BackstageChecks: NSObject, NSApplicationDelegate {
    private var failures = 0
    private let probe = MainRunLoopProbe()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() }
            catch { check(false, "Organization checks: \(error.localizedDescription)") }
            let delay = probe.stop()
            check(delay < 2, "Main run loop stays responsive (maximum delay \(String(format: "%.3f", delay))s)")
            print("Organization responsiveness checks: \(failures) failure(s)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }
    private func settle(_ milliseconds: Int = 80) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-BackstageChecks-" + UUID().uuidString)
        let model = try MyClipModel(root: root, preview: true)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.refreshAgentAvailability()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let icon = AgentCharacterView(agent: .codex)
        window.contentView = icon
        icon.configure(state: .init(), animated: false)
        window.orderFrontRegardless()
        try await settle(150)
        icon.displayIfNeeded()
        for _ in 0..<100 { icon.configure(state: .init(), animated: false) }
        check(!icon.needsDisplay, "Identical static icon updates do not request redraws")
        icon.updateTrackingAreas()
        check(icon.trackingAreas.isEmpty, "Static history icons do not register mouse tracking")
        icon.configure(state: .init(), animated: true, interactive: true)
        icon.updateTrackingAreas()
        let tracking = icon.trackingAreas.first
        icon.updateTrackingAreas()
        let systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        check(systemReducesMotion ? icon.trackingAreas.isEmpty : tracking != nil && icon.trackingAreas.count == 1 && tracking === icon.trackingAreas.first,
              "Animated icons reuse tracking areas and respect system motion preferences")
        icon.configure(state: .init(), animated: true, interactive: true, reduceMotion: true)
        check(icon.trackingAreas.isEmpty, "Reduced motion removes animated mouse tracking")
        var state = ClipAgentState()
        state.detail = "新的状态说明"
        icon.configure(state: state, animated: false, interactive: true)
        check(icon.accessibilityLabel()?.contains(state.detail) == true && icon.isAccessibilityElement(),
              "Changed status and interaction remain accessible")
        check(icon.trackingAreas.isEmpty, "Disabling animation removes mouse tracking")

        model.page = .agents
        window.contentView = NSHostingView(rootView: MyClipRootView(model: model))
        probe.start()
        try await settle(200)
        try await runOrganizationNavigationChecks(window: window, model: model, check: check)
        try await runUsageDashboardChecks(window: window, check: check)
        await model.refresh()
        model.preferences.enabledAgent = .workbuddy
        let original = model.library.jobs.first!
        for iteration in 0..<40 {
            model.organizationSection = OrganizationSection.allCases[iteration % 3]
            var current = original
            current.state = .running
            model.currentJob = iteration.isMultiple(of: 2) ? current : nil
            model.activityText = "进度更新 \(iteration)：检查当前资料并保留来源。"
            if iteration % 8 == 0 {
                window.orderOut(nil)
                window.setContentSize(NSSize(width: iteration % 16 == 0 ? 840 : 1120, height: 760))
                window.orderFrontRegardless()
            }
            try await settle(70)
        }
        check(!scrollViews(in: window.contentView!).contains { $0.documentView.map { !scrollViews(in: $0).isEmpty } == true },
              "Page switching, progress, resizing and reopening never reintroduce nested scrolling")
    }
}

@main
struct BackstageResponsivenessTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let checks = BackstageChecks()
        NSApp.delegate = checks
        withExtendedLifetime(checks) { NSApp.run() }
    }
}
