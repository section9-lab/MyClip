import AppKit
import AVFAudio
import CoreGraphics
import Foundation

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
    static var microphoneStatus: MicrophonePermissionStatus {
        MicrophonePermissionStatus(AVAudioApplication.shared.recordPermission)
    }

    static var screenCaptureStatus: ScreenCapturePermissionStatus {
        ScreenCapturePermissionStatus(isGranted: CGPreflightScreenCaptureAccess())
    }

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
}
