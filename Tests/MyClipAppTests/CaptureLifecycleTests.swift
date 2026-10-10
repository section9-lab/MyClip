import AppKit
import MyClipCore

// Replace only the OS capture boundary; the model, preferences, and store are real.
@MainActor
final class FocusedCaptureService {
    static var latest: FocusedCaptureService?
    static var initialScreenPermission = true
    static var initialAccessibilityPermission = true
    var hasScreenPermission = true
    var hasAccessibilityPermission = true
    var onCapture: ((CapturedImage, CaptureContext) async -> Void)?
    var onStatus: ((String) -> Void)?
    var startCount = 0
    var running = false
    var isRunning: Bool { running }
    var canStart = true
    var configured = false
    var configuredSettings: CaptureSettings?

    init() {
        hasScreenPermission = Self.initialScreenPermission
        hasAccessibilityPermission = Self.initialAccessibilityPermission
        Self.latest = self
    }
    func configure(settings: CaptureSettings, excludedBundleIDs: Set<String>) { configured = true; configuredSettings = settings }
    func requestScreenPermission() { hasScreenPermission = true }
    func requestAccessibilityPermission() { hasAccessibilityPermission = true }
    func start() -> Bool {
        startCount += 1
        running = canStart && hasScreenPermission && hasAccessibilityPermission
        onStatus?(running ? "采集已开启" : "无法启动输入监听")
        return running
    }
    func stop() { running = false; onStatus?("采集已暂停") }
}

@main
struct CaptureLifecycleTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-CaptureTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        func makeModel(_ name: String, previousCapture: Bool? = nil, preview: Bool = false,
                       screen: Bool = true, accessibility: Bool = true) throws -> MyClipModel {
            FocusedCaptureService.initialScreenPermission = screen
            FocusedCaptureService.initialAccessibilityPermission = accessibility
            var defaults: [String: Any] = ["myclip.autoOrganize": false]
            if let previousCapture { defaults["myclip.captureWasEnabled"] = previousCapture }
            UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
            return try MyClipModel(root: root.appendingPathComponent(name), preview: preview)
        }

        for previous in [nil, false, true] as [Bool?] {
            let model = try makeModel("launch-\(String(describing: previous))", previousCapture: previous)
            let capture = FocusedCaptureService.latest!
            check(!capture.running, "Constructing the model does not start capture before app startup")
            check(!model.showPermissions, "Existing grants allow opening the library without onboarding")
            model.start()
            try await Task.sleep(for: .milliseconds(250))
            check(model.capturing && capture.running, "Startup captures automatically with previous state \(String(describing: previous))")
            check(capture.configured, "Capture settings are applied before automatic startup")
            let starts = capture.startCount
            model.refreshPermissions()
            model.refreshPermissions()
            check(capture.startCount == starts, "Permission refresh does not restart active capture")
            model.stop()
            check(!model.capturing && !capture.running, "App shutdown stops capture and clears its state")
            model.refreshPermissions()
            check(!capture.running, "Permission refresh after shutdown does not restart capture")
        }

        for (screen, accessibility) in [(false, false), (false, true), (true, false)] {
            let model = try makeModel("permissions-\(screen)-\(accessibility)", screen: screen, accessibility: accessibility)
            let capture = FocusedCaptureService.latest!
            check(model.showPermissions, "Missing permissions require onboarding before the first window opens")
            model.start()
            try await Task.sleep(for: .milliseconds(250))
            check(!capture.running, "Capture waits when either required permission is missing")
            check(model.showPermissions && model.captureStatus.contains("权限"), "Startup explains the missing permission")
            model.open(.settings)
            check(model.showPermissions, "Opening settings cannot bypass permission onboarding")
            model.requestAccessibilityPermission()
            check(model.showPermissions == !screen, "Granting one permission cannot bypass the other requirement")
            model.requestScreenPermission()
            check(model.capturing && capture.running, "Granting permissions starts capture without a switch")
            check(!model.showPermissions, "Granting both permissions automatically opens the library")
            for revokeScreen in [true, false] {
                capture.hasScreenPermission = !revokeScreen
                capture.hasAccessibilityPermission = revokeScreen
                model.refreshPermissions()
                check(!model.capturing && !capture.running, "Revoking permission stops capture")
                check(model.showPermissions, "Revoking either permission returns to onboarding")
                model.open(.captures)
                check(model.showPermissions, "Reopening the library cannot bypass a revoked permission")
                model.requestScreenPermission()
                model.requestAccessibilityPermission()
                check(model.capturing && capture.running, "Restoring permission automatically resumes capture")
                check(!model.showPermissions, "Restoring both permissions returns to the library")
            }
            model.stop()
        }

        let retry = try makeModel("startup-retry")
        let retryCapture = FocusedCaptureService.latest!
        retryCapture.canStart = false
        retry.start()
        try await Task.sleep(for: .milliseconds(250))
        check(!retry.capturing && retry.captureStatus == "无法启动输入监听", "A failed capture start preserves the service error")
        retryCapture.canStart = true
        retry.refreshPermissions()
        check(retry.capturing, "A later refresh retries a failed capture start automatically")
        retryCapture.stop()
        retry.refreshPermissions()
        check(retry.capturing && retryCapture.running, "Capture resumes if the service stopped between permission checks")
        retry.stop()

        func frame(cursor: Bool) throws -> CapturedImage {
            let canvas = CGContext(data: nil, width: 320, height: 320, bitsPerComponent: 8, bytesPerRow: 1280,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.setFillColor(CGColor(gray: 0.95, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
            canvas.setFillColor(CGColor(gray: 0.15, alpha: 1))
            for y in stride(from: 40, to: 280, by: 20) { canvas.fill(CGRect(x: 20, y: y, width: 200, height: 8)) }
            if cursor { canvas.fill(CGRect(x: 240, y: 150, width: 2, height: 12)) }
            return try CapturedImage(image: canvas.makeImage()!)
        }
        let original = try frame(cursor: false), withCursor = try frame(cursor: true)
        for (strategies, images, pending) in [([], 2, 3), (["mouseCooldown"], 2, 3), (["similarImages"], 1, 1)] {
            UserDefaults.standard.setVolatileDomain(["myclip.autoOrganize": true, "myclip.captureFilterStrategies": strategies], forName: UserDefaults.argumentDomain)
            let filtering = try MyClipModel(root: root.appendingPathComponent("filtering-\(strategies.joined())"), preview: false)
            let service = FocusedCaptureService.latest!
            filtering.applyCaptureSettings()
            check(service.configuredSettings?.filterStrategies == Set(strategies.compactMap(CaptureFilterStrategy.init(rawValue:))), "Capture receives the selected filtering strategies")
            for (index, image) in [original, withCursor, withCursor].enumerated() {
                let context = CaptureContext(appName: "Notes", bundleID: "test.notes", windowTitle: "Document", windowID: 7,
                                             reason: .enter, date: Date(timeIntervalSince1970: 100 + Double(index) * 30))
                await service.onCapture?(image, context)
            }
            let snapshot = try await filtering.store.snapshot()
            check(snapshot.captureCount == 3, "Filtering preserves every capture occurrence")
            check(snapshot.imageCount == images, "The capture callback applies image filtering selection \(strategies)")
            check(snapshot.queue.pendingCount == pending, "The capture callback applies duplicate queue filtering selection \(strategies)")
            if strategies == ["similarImages"] {
                filtering.preferences.captureSettings.filterStrategies = []
                filtering.applyCaptureSettings()
                check(service.configuredSettings?.filterStrategies.isEmpty == true, "Capture receives filtering changes without restarting")
                let context = CaptureContext(appName: "Notes", bundleID: "test.notes", windowTitle: "Document", windowID: 7,
                                             reason: .enter, date: Date(timeIntervalSince1970: 200))
                await service.onCapture?(withCursor, context)
                let updated = try await filtering.store.snapshot()
                check(updated.imageCount == 2 && updated.queue.pendingCount == 2, "The next capture uses changed filtering preferences")
                check(Set(updated.captures.map(\.sceneID)).count == 1, "Disabling image filtering keeps timeline grouping")
            }
            filtering.stop()
        }

        let preview = try makeModel("preview", preview: true, screen: false, accessibility: false)
        let previewCapture = FocusedCaptureService.latest!
        preview.start()
        try await Task.sleep(for: .milliseconds(250))
        preview.refreshPermissions()
        check(!preview.capturing && previewCapture.startCount == 0, "Preview never starts real capture")
        check(!preview.showPermissions, "Isolated previews do not require system permissions")
        preview.stop()

        print("Capture lifecycle checks: \(failures) failure(s)")
        try? FileManager.default.removeItem(at: root)
        exit(failures == 0 ? 0 : 1)
    }
}
