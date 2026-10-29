import AppKit
import Combine
import Sparkle

/// Sparkle owns update discovery, progress, errors, signature verification and installation.
/// This adapter shares its observable settings between the application menu and Settings.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, NSMenuItemValidation {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?

    private var controller: SPUStandardUpdaterController?

    static var feedURL: URL {
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "x86_64"
        #endif
        return URL(string: "https://github.com/section9-lab/MyClip/releases/latest/download/appcast-\(architecture).xml")!
    }

    func start() {
        guard controller == nil,
            Bundle.main.bundleURL.pathExtension == "app",
            !CommandLine.arguments.contains("--preview"),
            ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastUpdateCheckDate)
        controller.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(sender)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }

    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL.absoluteString }
}
