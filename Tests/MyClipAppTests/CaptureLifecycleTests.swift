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

    init() {
        hasScreenPermission = Self.initialScreenPermission
        hasAccessibilityPermission = Self.initialAccessibilityPermission
        Self.latest = self
    }
    func configure(settings: CaptureSettings, excludedBundleIDs: Set<String>) { configured = true }
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
