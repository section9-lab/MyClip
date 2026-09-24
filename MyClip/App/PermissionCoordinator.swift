import AppKit
import AVFAudio
import CoreGraphics
import Foundation

@available(macOS 14.0, *)
enum MicrophonePermissionStatus: Sendable {
    case undetermined
    case denied
    case granted

    init(_ permission: AVAudioApplication.recordPermission) {
        switch permission {
        case .undetermined:
            self = .undetermined
        case .denied:
            self = .denied
        case .granted:
            self = .granted
        @unknown default:
            self = .denied
        }
    }
}

enum ScreenCapturePermissionStatus: Sendable {
    case denied
    case granted

    init(isGranted: Bool) {
        self = isGranted ? .granted : .denied
    }
}

enum PermissionCoordinator {
    @available(macOS 14.0, *)
    static var microphoneStatus: MicrophonePermissionStatus {
        MicrophonePermissionStatus(AVAudioApplication.shared.recordPermission)
    }

    static var screenCaptureStatus: ScreenCapturePermissionStatus {
        ScreenCapturePermissionStatus(isGranted: CGPreflightScreenCaptureAccess())
    }

    @available(macOS 14.0, *)
    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func openScreenCaptureSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording"
        ].compactMap(URL.init(string:))

        for url in urls where NSWorkspace.shared.open(url) {
            return
        }
    }

    private static let folderAccessRequestedKey = "folderAccessRequested"

    /// macOS has no Preflight API for folder access; the only way to know is to attempt a read, and that read shows the
    /// system prompt while the user has not answered it. So nothing is read until the user asks for access in onboarding;
    /// permissions are polled every few seconds and would otherwise raise the prompt unasked.
    static func hasFolderAccess(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: folderAccessRequestedKey) else { return false }
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        return ["Desktop", "Documents"].allSatisfy {
            (try? manager.contentsOfDirectory(at: home.appendingPathComponent($0), includingPropertiesForKeys: nil)) != nil
        }
    }

    static func markFolderAccessRequested(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: folderAccessRequestedKey)
    }

    @MainActor
    static func openFilesAndFoldersSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_DesktopFolder",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_DocumentsFolder"
        ].compactMap(URL.init(string:))

        for url in urls where NSWorkspace.shared.open(url) {
            return
        }
    }
}
