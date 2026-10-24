import AppKit
import SwiftUI
import MyClipCore

@MainActor
func runCloudSyncAppChecks() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-CloudAppChecks-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LibraryStore(root: root)
    _ = try await store.snapshot()
    let profile = try await store.readMemory(path: "Profile.md")
    try await store.updateEntry(id: profile.id, title: profile.title, body: "# 关于我\n\n偏好简短、清楚的中文回复。", expectedRevision: profile.revision)
    let transport = CloudTestTransport(), credentials = CloudTestCredentials()
    let engine = CloudSyncEngine(store: store, credentials: credentials, transport: transport, notionDelay: .zero)
    _ = try await engine.connectNotion(token: "fixture-token", page: "12345678-1234-1234-1234-123456789012")
    let controller = CloudSyncController(store: store, preview: false, engine: engine)
    defer { controller.stop() }
    controller.observe(try await store.cloudMemoryEntries())
    controller.start()

    try await waitForCloud { controller.target(.notion)?.lastSyncedAt != nil && controller.operations[.notion] == nil }
    try cloudEqual(controller.pending(.notion), 0)
    print("PASS automatic sync publishes existing memory after launch")
    let firstDate = try cloudUnwrap(controller.target(.notion)?.lastSyncedAt)
    let current = try await store.readMemory(path: "Profile.md")
    try await store.updateEntry(id: current.id, title: current.title, body: "# 关于我\n\n工作日使用中文回复，周末练习英文。", expectedRevision: current.revision)
    controller.observe(try await store.cloudMemoryEntries())
    try await waitForCloud { controller.target(.notion)?.lastSyncedAt.map { $0 > firstDate } == true && controller.pending(.notion) == 0 && controller.operations[.notion] == nil }
    print("PASS automatic sync follows local edits")

    var options = try cloudUnwrap(controller.target(.notion)?.options)
    options.automatic = false
    controller.setOptions(options, for: .notion)
    try await waitForCloud { controller.target(.notion)?.options.automatic == false && controller.operations[.notion] == nil }
    let before = await transport.allRequests().count
    let next = try await store.readMemory(path: "Profile.md")
    try await store.updateEntry(id: next.id, title: next.title, body: "# 关于我\n\n新的已确认偏好。", expectedRevision: next.revision)
    controller.observe(try await store.cloudMemoryEntries())
    try await Task.sleep(for: .milliseconds(2400))
    let paused = await transport.allRequests().count
    try cloudEqual(before, paused, "Disabled automatic sync must not make requests")
    try cloudCheck(controller.pending(.notion) > 0)
    controller.sync(.notion)
    try await waitForCloud { controller.pending(.notion) == 0 && controller.operations[.notion] == nil }
    print("PASS immediate sync works with automatic sync disabled")

    let preview = CloudSyncController(store: store, preview: true, engine: engine)
    defer { preview.stop() }
    preview.observe(try await store.cloudMemoryEntries()); preview.start()
    try await waitForCloud { preview.loaded }
    let previewBefore = await transport.allRequests().count
    preview.syncAll()
    try cloudFalse(preview.canSync(.notion))
    let previewAfter = await transport.allRequests().count
    try cloudEqual(previewBefore, previewAfter)
    print("PASS preview does not read credentials or contact cloud services")

    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/cloud-sync-verification")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = NSHostingView(rootView: MemoryCloudSyncView(sync: controller).environment(\.colorScheme, .light))
    window.orderFrontRegardless()
    try await captureCloudPanel(window, at: output.appendingPathComponent("cloud-sync-connected.png"))
    window.setContentSize(NSSize(width: 540, height: 440))
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = NSHostingView(rootView: MemoryCloudSyncView(sync: controller).environment(\.colorScheme, .dark))
    try await captureCloudPanel(window, at: output.appendingPathComponent("cloud-sync-compact-dark.png"))
    print("PASS cloud panel renders at standard and compact sizes in light and dark appearance")

    let lastSuccessfulSync = controller.target(.notion)?.lastSyncedAt
    await transport.rejectRequests(true)
    controller.sync(.notion)
    try await waitForCloud { controller.errors[.notion] != nil && controller.operations[.notion] == nil }
    try cloudCheck(controller.errors[.notion]?.contains("权限") == true)
    try cloudEqual(controller.target(.notion)?.lastSyncedAt, lastSuccessfulSync)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = NSHostingView(rootView: MemoryCloudSyncView(sync: controller).environment(\.colorScheme, .light))
    window.setContentSize(NSSize(width: 620, height: 640))
    try await captureCloudPanel(window, at: output.appendingPathComponent("cloud-sync-error.png"))
    print("PASS connection failure remains visible and preserves last successful sync")

    var authorizationURL: URL?
    let oauth = GoogleCloudOAuth(openBrowser: { authorizationURL = $0; return true }, transport: transport)
    await transport.rejectRequests(false)
    var finished = false
    let authorization = Task { @MainActor in
        defer { finished = true }
        return try await oauth.authorize(GoogleDesktopClient(clientID: "fixture.apps.googleusercontent.com"))
    }
    try await waitForCloud { authorizationURL != nil }
    let query = try cloudUnwrap(URLComponents(url: try cloudUnwrap(authorizationURL), resolvingAgainstBaseURL: false)?.queryItems)
    var callback = try cloudUnwrap(URLComponents(string: try cloudUnwrap(query.first { $0.name == "redirect_uri" }?.value)))
    callback.queryItems = [URLQueryItem(name: "state", value: "invalid"), URLQueryItem(name: "code", value: "fixture-code")]
    let (_, rejectedResponse) = try await URLSession.shared.data(from: try cloudUnwrap(callback.url))
    try cloudEqual((rejectedResponse as? HTTPURLResponse)?.statusCode, 400)
    try cloudFalse(finished, "Invalid state must not complete OAuth")
    callback.queryItems = [URLQueryItem(name: "state", value: query.first { $0.name == "state" }?.value), URLQueryItem(name: "code", value: "fixture-code")]
    let (_, acceptedResponse) = try await URLSession.shared.data(from: try cloudUnwrap(callback.url))
    try cloudEqual((acceptedResponse as? HTTPURLResponse)?.statusCode, 200)
    let authorized = try await authorization.value
    try cloudEqual(authorized.accessToken, "refreshed-test-token")
    print("PASS desktop OAuth loopback rejects invalid state and exchanges the valid code")

    authorizationURL = nil
    let cancelled = Task { try await oauth.authorize(GoogleDesktopClient(clientID: "fixture.apps.googleusercontent.com")) }
    try await waitForCloud { authorizationURL != nil }
    cancelled.cancel()
    _ = try await expectCloudError { _ = try await cancelled.value }
    print("PASS cancelling OAuth closes the listener")
}

@MainActor
private func waitForCloud(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(12)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
    try cloudCheck(condition(), "Timed out waiting for cloud state")
}

@MainActor
private func captureCloudPanel(_ window: NSWindow, at url: URL) async throws {
    for _ in 0..<12 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    let view = try cloudUnwrap(window.contentView)
    try cloudCheck(view.bounds.width >= 540 && view.bounds.height >= 420)
    let image = try cloudUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: image)
    try cloudUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
}
