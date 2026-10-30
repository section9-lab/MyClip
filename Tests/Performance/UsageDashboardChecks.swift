import AppKit
import SwiftUI
import MyClipCore
#if MYCLIP_APP_TESTS
@testable import MyClip
#endif

/// Numerical fixtures only: no live account, screenshots or personal Memory data.
@MainActor private func usageFixture(agents: [ClipAgent], tokens: Int? = 12_345, dayCount: Int = 8) -> TokenUsageStatistics {
    var result = TokenUsageStatistics()
    for offset in 0..<dayCount {
        let date = Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: Date()))!
        var day = TokenUsageDay(day: date)
        for agent in agents {
            let usage = tokens.map { TokenUsage(totalTokens: $0, inputTokens: $0 / 2, outputTokens: $0 / 4,
                                                cachedReadTokens: $0 / 4, cachedWriteTokens: 0) }
            result.total.add(usage)
            result.agents[agent, default: TokenUsageSummary()].add(usage)
            day.total.add(usage)
            day.agents[agent, default: TokenUsageSummary()].add(usage)
        }
        result.history.append(day)
    }
    result.history.reverse()
    return result
}

/// Mount/unmount the usage destination and drive the production presentation binding.
/// AppKit renders the real Charts view; this does not substitute a screenshot or a fake renderer.
@MainActor private final class UsageFixtureState: ObservableObject {
    @Published var statistics: TokenUsageStatistics
    @Published var days: Int? = 30
    @Published var expanded = false
    @Published var asTable = false
    init(_ statistics: TokenUsageStatistics) { self.statistics = statistics }
}

private struct UsageFixtureView: View {
    @ObservedObject var state: UsageFixtureState
    var body: some View {
        if state.expanded {
            UsageDashboard(statistics: state.statistics, days: state.days, asTable: $state.asTable).padding(20)
        } else { Color.clear.frame(height: 1) }
    }
}

@MainActor func runOrganizationNavigationChecks(window: NSWindow, model: MyClipModel,
                                               check: (Bool, String) -> Void) async throws {
    let originalContent = window.contentView
    let originalPage = model.page
    let originalSection = model.organizationSection
    let originalLibrary = model.library
    let originalJob = model.currentJob
    let originalAgent = model.preferences.enabledAgent
    let originalAgents = model.agents
    let originalSize = window.contentView?.frame.size
    let originalAppearance = window.appearance
    let originalLevel = window.level
    let originalBehavior = window.collectionBehavior
    // These checks exercise real occlusion. Keep their temporary fixture window visible even
    // when the coding harness is foregrounded or the desktop uses multiple Spaces.
    window.level = .floating
    window.collectionBehavior.insert(.canJoinAllSpaces)
    window.orderFrontRegardless()
    defer {
        window.contentView = originalContent
        model.page = originalPage
        model.organizationSection = originalSection
        model.library = originalLibrary
        model.currentJob = originalJob
        model.preferences.enabledAgent = originalAgent
        model.agents = originalAgents
        window.appearance = originalAppearance
        window.level = originalLevel
        window.collectionBehavior = originalBehavior
        if let originalSize { window.setContentSize(originalSize) }
    }
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
    func settle() async throws { try await Task.sleep(for: .milliseconds(200)); window.contentView?.layoutSubtreeIfNeeded() }
    func snapshot(_ name: String) throws {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/organization-layout")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }
    let graphics = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let capture = CaptureContext(appName: "Layout fixture", bundleID: "test.organization.layout", windowTitle: "Synthetic capture",
                                 windowID: 1, reason: .manual)
    try await model.store.record(image: CapturedImage(image: graphics.makeImage()!), context: capture, agent: .workbuddy,
                                 organize: false, extractedText: "Synthetic layout fixture")
    for index in 0..<105 {
        let agent: ClipAgent = index.isMultiple(of: 2) ? .workbuddy : .qwenwork
        let id = try await model.store.enqueue(sourceIDs: [capture.id], agent: agent)
        _ = try await model.store.claimNextJob(immediately: true, jobID: id)
        if index.isMultiple(of: 3) { try await model.store.commit(jobID: id, drafts: []) }
        else { try await model.store.finishJob(id: id, state: index % 3 == 1 ? .failed : .cancelled, error: index % 3 == 1 ? "Synthetic connection failure" : nil) }
    }
    try await model.store.setOrganizationPaused(false)
    for agent in ClipAgent.allCases {
        try await model.store.recordTokenUsage(agent: agent, usage: TokenUsage(totalTokens: 12000, inputTokens: 6000, outputTokens: 3000, cachedReadTokens: 3000))
    }
    model.page = .agents
    model.organizationSection = .status
    model.currentJob = nil
    model.preferences.enabledAgent = .workbuddy
    model.agents[.workbuddy]?.phase = .ready
    await model.refresh()
    check(!model.tokenUsageLoaded, "Runtime/background refresh does not load token statistics")
    let host = NSHostingView(rootView: BackstageView(model: model).background(Color(nsColor: .windowBackgroundColor)))
    window.contentView = host
    window.setContentSize(NSSize(width: 1120, height: 760))
    window.appearance = NSAppearance(named: .aqua)
    try await settle()
    check(scrollViews(host).count == 1, "Runtime mounts one status scroller, not the history list or chart")
    try snapshot("status-light")
    model.organizationSection = .history
    try await settle()
    check(!model.tokenUsageLoaded, "Opening history does not load token statistics")
    let historyScrolls = scrollViews(host)
    check(historyScrolls.count == 1, "History uses a single native scrolling list")
    check(!historyScrolls.contains { $0.documentView.map { !scrollViews($0).isEmpty } == true }, "History has no nested scrolling viewport")
    try snapshot("history-light")

    let state = OrganizationHistoryState()
    await state.load(store: model.store, recent: model.library.jobs)
    check(state.rows.count == 50 && state.hasMore, "History initially loads one 50-record page")
    state.nextPage()
    await state.load(store: model.store, recent: model.library.jobs)
    check(state.rows.count == 100 && state.hasMore, "History loads a second page without truncating to the library snapshot")
    state.nextPage()
    await state.load(store: model.store, recent: model.library.jobs)
    check(state.rows.count == 105 && !state.hasMore && Set(state.rows.map(\.id)).count == 105, "Pagination reaches older records without duplicates")
    let older = state.rows.last { $0.state == .failed }!
    try await model.store.retryJob(id: older.id)
    let retried = try await model.store.organizationJob(id: older.id)
    let changedVersion = try await model.store.refreshVersions().library
    await state.load(store: model.store, recent: model.library.jobs, version: changedVersion)
    check(retried?.state == .queued && state.rows.first { $0.id == older.id }?.state == .queued,
          "Changes to older jobs refresh even when the recent-job snapshot is unchanged")
    check(state.rows.count == 105, "Live history refresh preserves already loaded older pages")
    state.filter = .done
    await state.load(store: model.store, recent: model.library.jobs)
    check(!state.rows.isEmpty && state.rows.allSatisfy { $0.state == .completed }, "History state filters reset pagination correctly")
    state.agent = .workbuddy
    state.period = .today
    await state.load(store: model.store, recent: model.library.jobs)
    check(!state.rows.isEmpty && state.rows.allSatisfy { $0.agent == .workbuddy && $0.state == .completed }, "Agent, state and local-date filters combine")
    let future = try await model.store.organizationHistory(since: Date().addingTimeInterval(60))
    check(future.isEmpty, "History date filtering does not return records outside the requested range")

    let detail = NSHostingView(rootView: ExecutionDetailView(model: model, job: state.rows.first!)
        .background(Color(nsColor: .windowBackgroundColor)))
    window.contentView = detail
    window.setContentSize(NSSize(width: 520, height: 640))
    try await settle()
    check(detail.fittingSize.height.isFinite && scrollViews(detail).count == 1, "Real execution details render results and sources without nested scrolling")
    check(!model.tokenUsageLoaded, "Execution details do not depend on loading the global token dashboard")
    try snapshot("execution-detail-light")
    window.contentView = host
    window.setContentSize(NSSize(width: 1120, height: 760))
    try await settle()
    model.organizationSection = .usage
    for _ in 0..<30 {
        try await settle()
        if model.tokenUsageLoaded { break }
    }
    check(model.tokenUsageLoaded && model.tokenUsage.total.calls == 6, "Entering usage loads actual statistics on demand")
    check(scrollViews(host).count == 1, "Usage mounts its own page without the history list")
    try snapshot("usage-light")
    model.organizationSection = .status
    try await settle()
    let previousCalls = model.tokenUsage.total.calls
    try await model.store.recordTokenUsage(agent: .workbuddy, usage: TokenUsage(totalTokens: 100, inputTokens: 60, outputTokens: 40))
    await model.refreshIfNeeded()
    check(model.tokenUsage.total.calls == previousCalls, "Leaving usage stops background token aggregation")
    model.organizationSection = .usage
    for _ in 0..<30 {
        try await settle()
        if model.tokenUsage.total.calls > previousCalls { break }
    }
    check(model.tokenUsage.total.calls == previousCalls + 1, "Reopening usage immediately catches up with new usage")
    let visibleCalls = model.tokenUsage.total.calls
    window.orderOut(nil)
    try await settle()
    check(!model.organizationUIVisible, "Window occlusion stops organization page work")
    try await model.store.recordTokenUsage(agent: .qwenwork, usage: TokenUsage(totalTokens: 10, inputTokens: 6, outputTokens: 4))
    await model.refreshIfNeeded()
    check(model.tokenUsage.total.calls == visibleCalls, "Hidden windows do not aggregate token statistics")
    if NSApp.activationPolicy() != .prohibited { NSApp.activate(ignoringOtherApps: true) }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    for _ in 0..<30 {
        try await settle()
        if model.tokenUsage.total.calls > visibleCalls { break }
    }
    check(model.tokenUsage.total.calls == visibleCalls + 1,
          "Showing the window catches up without a background timer (visible: \(model.organizationUIVisible), window: \(window.isVisible), occlusion: \(window.occlusionState.rawValue), calls: \(model.tokenUsage.total.calls)/\(visibleCalls + 1))")
    let beforeConcurrent = model.tokenUsage.total.calls
    try await model.store.recordTokenUsage(agent: .workbuddy, usage: TokenUsage(totalTokens: 20, inputTokens: 12, outputTokens: 8))
    let interrupted = Task { await model.refreshTokenUsageIfNeeded() }
    await Task.yield()
    interrupted.cancel()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 { group.addTask { await model.refreshTokenUsageIfNeeded() } }
    }
    await interrupted.value
    check(model.tokenUsage.total.calls == beforeConcurrent + 1, "Concurrent refreshes catch up after a cancelled usage request")
    window.appearance = NSAppearance(named: .darkAqua)
    try await settle()
    try snapshot("usage-dark")
    window.setContentSize(NSSize(width: 620, height: 580))
    for section in OrganizationSection.allCases {
        model.organizationSection = section
        try await settle()
        check(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite, "\(section.rawValue) stays bounded at the minimum window's content width")
        try snapshot(section.rawValue + "-narrow-dark")
    }
}

/// Used by both the CLT performance runner and full native-app Backstage tests in release CI.
@MainActor func runUsageDashboardChecks(window: NSWindow, check: (Bool, String) -> Void) async throws {
    let originalContent = window.contentView
    let originalSize = window.contentView?.frame.size
    defer {
        window.contentView = originalContent
        if let originalSize { window.setContentSize(originalSize) }
    }
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
    for agents in [[ClipAgent.workbuddy], [.qwenwork], ClipAgent.allCases] {
        let state = UsageFixtureState(usageFixture(agents: agents))
        let host = NSHostingView(rootView: UsageFixtureView(state: state))
        window.contentView = host
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let collapsedHeight = host.fittingSize.height
        let name = agents.map(\.rawValue).joined(separator: ",")
        state.expanded = true
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        check(host.fittingSize.height > collapsedHeight, "\(name): entering usage renders the chart without crashing")
        check(scrollViews(host).isEmpty, "\(name): chart presentation is active")
        state.asTable = true
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        check(!scrollViews(host).isEmpty, "\(name): presentation binding switches to the real table")
        state.asTable = false
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        check(scrollViews(host).isEmpty, "\(name): switching back renders the chart")
        state.statistics = usageFixture(agents: ClipAgent.allCases, dayCount: 40)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        check(host.fittingSize.height.isFinite, "\(name): incoming agents update the visible usage chart")
        state.expanded = false
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        check(abs(host.fittingSize.height - collapsedHeight) <= 1, "\(name): leaving usage unmounts its chart")
    }

    let fixtures: [(String, TokenUsageStatistics)] = [
        ("all six agents", usageFixture(agents: ClipAgent.allCases, dayCount: 40)),
        ("WorkBuddy only", usageFixture(agents: [.workbuddy], dayCount: 1)),
        ("Qwen Work only", usageFixture(agents: [.qwenwork], dayCount: 1)),
        ("zero tokens", usageFixture(agents: ClipAgent.allCases, tokens: 0)),
        ("unreported tokens", usageFixture(agents: ClipAgent.allCases, tokens: nil)),
        ("empty history", TokenUsageStatistics())
    ]
    for (label, statistics) in fixtures {
        let state = UsageFixtureState(statistics)
        state.expanded = true
        let host = NSHostingView(rootView: UsageFixtureView(state: state))
        window.contentView = host
        for days: Int? in [7, 30, nil] {
            state.days = days
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            check(size.width.isFinite && size.height.isFinite, "Expanded usage: \(label), \(days.map(String.init) ?? "all") days has finite layout")
        }
        window.setContentSize(NSSize(width: 580, height: 580))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        check(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite, "\(label): narrow expanded layout stays finite")
        window.setContentSize(NSSize(width: 1120, height: 760))
    }
}
