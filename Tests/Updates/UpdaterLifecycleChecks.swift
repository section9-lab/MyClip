import AppKit
import Foundation

@main struct UpdaterLifecycleChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        func settle() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        let domain = Bundle.main.bundleIdentifier!
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let updater = AppUpdater()
        updater.start()
        settle()
        check(updater.canCheckForUpdates, "A real app bundle starts Sparkle with the architecture-specific delegate feed")
        check(!updater.automaticallyChecksForUpdates, "Initial automatic-check preference comes from Info.plist")
        check(updater.lastUpdateCheckDate == nil, "Starting with automatic checks off performs no network check")
        updater.setAutomaticallyChecksForUpdates(true)
        updater.setAutomaticallyChecksForUpdates(false)
        settle()
        check(!updater.automaticallyChecksForUpdates, "Automatic checks can be turned off immediately")
        check(!UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks"), "Sparkle persists the user's automatic-check setting")
        updater.start()
        settle()
        check(!updater.automaticallyChecksForUpdates, "Repeated startup preserves the disabled user preference")
        check(updater.validateMenuItem(NSMenuItem()), "The app menu enables checking when Sparkle is ready")
        #if arch(arm64)
            check(AppUpdater.feedURL.lastPathComponent == "appcast-arm64.xml", "Apple Silicon uses its own update feed")
        #else
            check(AppUpdater.feedURL.lastPathComponent == "appcast-x86_64.xml", "Intel uses its own update feed")
        #endif
        print("Updater lifecycle checks: \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}
