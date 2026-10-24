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
                print("FAIL Backstage blocked the main run loop for more than four seconds")
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
            catch { check(false, "Backstage checks: \(error.localizedDescription)") }
            let delay = probe.stop()
            check(delay < 2, "Main run loop stays responsive (maximum delay \(String(format: "%.3f", delay))s)")
            print("Backstage responsiveness checks: \(failures) failure(s)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }

    private func settle(_ milliseconds: Int = 80) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// The sidebar and page can change native view order. Find the nested history by containment.
    private func history(in window: NSWindow) throws -> (page: NSScrollView, rows: NSScrollView) {
        guard let host = window.contentView,
              let page = scrollViews(in: host).first(where: { $0.documentView.map { !scrollViews(in: $0).isEmpty } == true }),
              let document = page.documentView, let rows = scrollViews(in: document).first else {
            throw LibraryError.invalidResult("Backstage did not create its nested execution history")
        }
        return (page, rows)
    }

    private func scroll(_ view: NSScrollView, fraction: CGFloat) {
        guard let document = view.documentView else { return }
        let y = document.bounds.minY + max(0, document.bounds.height - view.contentSize.height) * fraction
        view.contentView.scroll(to: NSPoint(x: 0, y: y))
        view.reflectScrolledClipView(view.contentView)
    }

    private func jobs(_ count: Int) -> [ClipJob] {
        (0..<count).map { index in
            var job = ClipJob(id: UUID(), agent: .codex, state: index == 2 ? .running : .completed,
                              createdAt: .now.addingTimeInterval(-Double(index * 3600)),
                              sourceIDs: Array(repeating: UUID(), count: 8), error: nil)
            if index % 4 == 0 { job.kind = .dream }
            return job
        }
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
        model.library.jobs = jobs(5)
        window.contentView = NSHostingView(rootView: MyClipRootView(model: model))
        probe.start()
        try await settle(200)
        let fiveRowHeight = try history(in: window).rows.contentSize.height
        check(fiveRowHeight > 0, "Five-row history has a visible viewport")
        window.setContentSize(NSSize(width: 1120, height: 580))
        try await settle(150)
        for count in [6, 14, 49, 50, 75] {
            model.library.jobs = jobs(count)
            try await settle(200)
            let (page, rows) = try history(in: window)
            let expectedHeight = fiveRowHeight * CGFloat(min(count, 50)) / 5
            var stable = true
            var topReachable = true
            var bottomReachable = true
            for outerFraction: CGFloat in [0, 0.3, 0.7, 1] {
                scroll(page, fraction: outerFraction)
                for fraction: CGFloat in [0, 0.1, 0.5, 0.85, 1, 0.5, 0.1, 0] {
                    scroll(rows, fraction: fraction)
                    try await settle()
                    guard let document = rows.documentView else { throw LibraryError.invalidResult("History document disappeared") }
                    stable = stable && abs(document.bounds.height - expectedHeight) <= 1
                    if fraction == 0 { topReachable = topReachable && abs(rows.documentVisibleRect.minY - document.bounds.minY) <= 1 }
                    if fraction == 1 { bottomReachable = bottomReachable && abs(rows.documentVisibleRect.maxY - document.bounds.maxY) <= 1 }
                }
            }
            check(stable, "\(count) records keep a fixed content height while nested scrolling")
            check(topReachable && bottomReachable, "\(count) records can reach the first and last managed rows without drift")
        }

        model.library.jobs = jobs(14)
        let originals = model.library.jobs
        for iteration in 0..<40 {
            let first = originals[0]
            model.library.jobs[0] = ClipJob(id: first.id, agent: first.agent, state: iteration % 2 == 0 ? .running : .completed,
                                          createdAt: first.createdAt, sourceIDs: first.sourceIDs, error: nil)
            model.activityText = "进度更新 \(iteration)：检查当前资料并保留来源。"
            if iteration % 8 == 0 {
                window.orderOut(nil)
                window.setContentSize(NSSize(width: iteration % 16 == 0 ? 840 : 1120, height: 760))
                window.orderFrontRegardless()
            }
            let (page, rows) = try history(in: window)
            scroll(page, fraction: iteration % 2 == 0 ? 0.4 : 1)
            scroll(rows, fraction: iteration % 2 == 0 ? 0.1 : 0.9)
            try await settle(50)
        }
        let (_, rows) = try history(in: window)
        check(abs((rows.documentView?.bounds.height ?? 0) - fiveRowHeight * 14 / 5) <= 1,
              "Progress, completion, resizing and reopening preserve history geometry")
        model.library.jobs = jobs(1)
        try await settle(150)
        let single = try history(in: window).rows
        check(abs(single.documentVisibleRect.minY) <= 1, "Shrinking a scrolled history reveals the remaining record")
        model.library.jobs = []
        try await settle(150)
        check(!scrollViews(in: window.contentView!).contains { $0.documentView.map { !scrollViews(in: $0).isEmpty } == true },
              "An empty history removes its inner scroll viewport")
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
