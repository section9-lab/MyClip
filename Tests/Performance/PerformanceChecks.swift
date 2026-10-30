import AppKit
import Combine
import SwiftUI
import Darwin
@testable import MyClipCore

// The performance harness uses real model/storage/UI code, but never requests capture permissions or
// connects a live agent. The execution-details sheet is outside the measured Backstage surface.
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
struct ExecutionDetailView: View {
    let model: MyClipModel
    let job: ClipJob
    var body: some View { Text(job.id.uuidString) }
}

private struct PerformanceFailure: Error { let message: String }
private extension LibraryStore {
    func performanceReadCount() -> Int { memoryReadCache.reads }
}
@MainActor private final class PerformanceChecks {
    private var failures = 0
    private func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }
    private func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-Performance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try MyClipModel(root: root, preview: true)
        defer { model.stop() }
        await model.refresh()
        let directory = root.appendingPathComponent("Memory")
        for index in 0..<86 {
            let body = "# Topic\(index)\n\n" + String(repeating: "A sourced note about Topic\(index), with practical context.\n", count: 80)
            try body.write(to: directory.appendingPathComponent("Wiki/Topics/Topic\(index).md"), atomically: true, encoding: .utf8)
        }
        await model.refresh()
        try await Task.sleep(for: .seconds(1)) // Let startup filesystem notifications settle.
        await model.refreshIfNeeded()
        let reads = await model.store.performanceReadCount()
        let stamp = try await model.store.changeStamp()
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        let began = cpuTime()
        for _ in 0..<20 {
            model.refreshPermissions()
            await model.refreshIfNeeded()
        }
        let afterReads = await model.store.performanceReadCount()
        let afterStamp = try await model.store.changeStamp()
        check(publications == 0, "Twenty idle ticks publish no unchanged UI state (\(publications) publications)")
        check(reads == afterReads, "Idle ticks do not reread Markdown (\(afterReads - reads) reads)")
        check(stamp == afterStamp, "Idle ticks do not write SQLite or filesystem state")
        print(String(format: "METRIC twenty idle refreshes: %.4f CPU seconds", cpuTime() - began))
        observation.cancel()
        for thermal: ProcessInfo.ThermalState in [.nominal, .fair, .serious, .critical] {
            check(!BackgroundWorkBudget.maintenanceAllowed(lowPower: true, thermal: thermal), "Low-power mode defers automatic maintenance at thermal state \(thermal.rawValue)")
            check(BackgroundWorkBudget.ocrAllowed(thermal: thermal) == (thermal == .nominal || thermal == .fair), "Background OCR respects thermal state \(thermal.rawValue)")
        }

        let version = try await model.store.refreshVersions()
        _ = try await model.store.createWorkTask(title: "Board-only change", project: "Checks")
        let boardVersion = try await model.store.refreshVersions()
        check(boardVersion.tasks != version.tasks && boardVersion.library == version.library && boardVersion.tokens == version.tokens,
              "A board update invalidates only the task domain")
        await model.refreshIfNeeded()
        check(model.workTasks.contains { $0.title == "Board-only change" }, "Local task changes reach the independent board")
        let other = try LibraryStore(root: root)
        _ = try await other.createWorkTask(title: "External board connection", project: "Checks")
        await model.refreshIfNeeded()
        check(model.workTasks.contains { $0.title == "External board connection" }, "External SQLite writes invalidate cached domains")
        let duplicate = directory.appendingPathComponent("Wiki/Topics/Duplicate.md")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("Wiki/Topics/Topic2.md"), to: duplicate)
        _ = try await other.createWorkTask(title: "Board survives invalid Memory", project: "Checks")
        await model.refresh()
        check(model.workTasks.contains { $0.title == "Board survives invalid Memory" }, "Broken Memory does not prevent independent board refresh")
        check(model.notice != nil, "Invalid Memory remains visible as an error")
        try FileManager.default.removeItem(at: duplicate)
        model.notice = nil
        await model.refresh()

        let file = directory.appendingPathComponent("Wiki/Topics/Topic0.md")
        let original = try await model.store.readMemory(path: "Wiki/Topics/Topic0.md")
        var current = try String(contentsOf: file, encoding: .utf8)
        current = current.replacingOccurrences(of: "A sourced note", with: "An edited note")
        try current.write(to: file, atomically: true, encoding: .utf8)
        let edited = try await model.store.readMemory(path: original.relativePath)
        check(edited.id == original.id && edited.body.contains("An edited note"), "Explicit reads immediately see atomic external edits")
        let destination = directory.appendingPathComponent("Wiki/Topics/Renamed.md")
        try FileManager.default.moveItem(at: file, to: destination)
        let renamed = try await model.store.readMemory(edited.id)
        check(renamed.relativePath == "Wiki/Topics/Renamed.md", "Cached scans preserve identity after external renames")
        try FileManager.default.removeItem(at: destination)
        let removed = try await model.store.snapshot()
        check(!removed.entries.contains { $0.id == edited.id }, "Cached scans observe external deletion")
        // A real filesystem event, rather than an explicit refresh, must also wake the background path.
        try "# External watcher\n\nWatcherSentinel.".write(to: directory.appendingPathComponent("Wiki/Topics/Watcher.md"), atomically: true, encoding: .utf8)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            await model.refreshIfNeeded()
            if model.library.entries.contains(where: { $0.title == "External watcher" }) { break }
        }
        check(model.library.entries.contains { $0.title == "External watcher" }, "Filesystem notifications discover external notes without a full-refresh timer")

        let lintStart = cpuTime()
        let first = try await model.store.memoryLint()
        let coldLint = cpuTime() - lintStart
        let warmStart = cpuTime()
        let second = try await model.store.memoryLint()
        let warmLint = cpuTime() - warmStart
        check(first == second, "Warm incremental lint preserves every finding")
        print(String(format: "METRIC lint cold %.4fs / warm %.4fs CPU", coldLint, warmLint))
        let note = try await model.store.readMemory(path: "Wiki/Topics/Topic1.md")
        try await model.store.updateEntry(id: note.id, title: note.title, body: "收到验证码 482913。", expectedRevision: note.revision)
        let sensitive = try await model.store.memoryLint()
        check(sensitive.sensitive.contains { $0.hasPrefix(note.relativePath) }, "Changed-page caches never skip sensitive-data checks")
        check(!sensitive.lines.joined().contains("482913"), "Lint does not expose detected secrets")

        let beforeBytes = try await model.store.statistics().storageBytes
        let image = root.appendingPathComponent("Images/external.txt")
        try Data(repeating: 65, count: 4096).write(to: image)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if try await model.store.statistics().storageBytes >= beforeBytes + 4096 { break }
        }
        let externalBytes = try await model.store.statistics().storageBytes
        check(externalBytes >= beforeBytes + 4096, "External image-directory writes invalidate cached capacity")

        model.page = .agents
        model.library.jobs = (0..<50).map { index in
            ClipJob(id: UUID(), agent: .codex, state: index == 0 ? .running : .completed,
                    createdAt: Date().addingTimeInterval(-Double(index * 300)), sourceIDs: [UUID()], error: nil)
        }
        model.currentJob = model.library.jobs[0]
        model.currentJobStartedAt = Date()
        model.agents[.codex]?.sessionID = "performance-session"
        model.activityText = "Codex 正在生成结果…"
        var progressPublications = 0
        let progress = model.objectWillChange.sink { progressPublications += 1 }
        model.lastActivityAt = Date().addingTimeInterval(-120)
        let activityBefore = model.lastActivityAt
        for _ in 0..<1000 { model.handle(.message(sessionID: "performance-session", text: "delta"), agent: .codex) }
        check(progressPublications == 0, "A thousand same-status streaming deltas do not redraw the page")
        check(model.lastActivityAt > activityBefore, "Streaming liveness timestamps still advance")
        progress.cancel()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BackstageView(model: model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let scrolls = scrollViews(window.contentView!)
        let page = scrolls.first { $0.documentView.map { !scrollViews($0).isEmpty } == true }
        let rows = page?.documentView.flatMap { scrollViews($0).first }
        check(abs((rows?.documentView?.bounds.height ?? 0) - 50 * 59) <= 1, "Fifty history rows retain fixed geometry")
        window.setContentSize(NSSize(width: 840, height: 580))
        try await Task.sleep(for: .milliseconds(250))
        check(abs((rows?.documentView?.bounds.height ?? 0) - 50 * 59) <= 1, "Narrow Backstage does not trigger history height feedback")
        window.setContentSize(NSSize(width: 1120, height: 760))
        try await Task.sleep(for: .milliseconds(250))
        check(NSApp.isActive && window.isVisible, "Visible-window benchmark runs in an active AppKit host")
        let visibleStart = cpuTime()
        try await Task.sleep(for: .seconds(3))
        let visibleCPU = (cpuTime() - visibleStart) / 3 * 100
        print(String(format: "METRIC Backstage visible, 50 records: %.2f%% CPU", visibleCPU))
        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(200))
        let hiddenStart = cpuTime()
        try await Task.sleep(for: .seconds(3))
        let hiddenCPU = (cpuTime() - hiddenStart) / 3 * 100
        print(String(format: "METRIC Backstage hidden, 50 records: %.2f%% CPU", hiddenCPU))
        if ProcessInfo.processInfo.environment["MYCLIP_PERFORMANCE_BACKSTAGE_SOURCE"] == nil {
            check(visibleCPU < 20, "Visible Backstage stays below the synthetic 20% CPU regression budget")
            check(hiddenCPU < 5, "Hidden Backstage stays below the synthetic 5% CPU regression budget")
        }
        if failures > 0 { throw PerformanceFailure(message: "\(failures) performance regression(s)") }
    }
}

@MainActor private final class PerformanceAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await PerformanceChecks().run()
                print("Performance checks passed")
                exit(0)
            } catch {
                print("FAIL \(error)")
                exit(1)
            }
        }
    }
}

@main struct PerformanceCheckRunner {
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let delegate = PerformanceAppDelegate()
        NSApp.delegate = delegate
        withExtendedLifetime(delegate) { NSApp.run() }
    }
}
