import AppKit
import Sparkle
@testable import MyClip

@main struct AppUpdaterTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }

        let updater = AppUpdater()
        updater.start()
        updater.start()
        updater.checkForUpdates(nil)
        updater.setAutomaticallyChecksForUpdates(true)
        check(!updater.canCheckForUpdates, "Standalone tests never initialize Sparkle or access the update feed")
        check(!updater.automaticallyChecksForUpdates, "Disabled updaters do not change automatic-check preferences")
        check(updater.lastUpdateCheckDate == nil, "Disabled updaters do not record a network check")
        check(!updater.validateMenuItem(NSMenuItem()), "Check for Updates is disabled before the updater starts")
        let feed = AppUpdater.feedURL
        check(feed.scheme == "https" && feed.host == "github.com", "Updates use the repository's HTTPS release feed")
        #if arch(arm64)
            check(feed.lastPathComponent == "appcast-arm64.xml", "Apple Silicon uses its own update feed")
        #else
            check(feed.lastPathComponent == "appcast-x86_64.xml", "Intel uses its own update feed")
        #endif
        check(feed.path.hasPrefix("/section9-lab/MyClip/releases/latest/download/"), "Checks follow the latest published stable release")
        print("App updater checks: \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}
