import Foundation
import CoreGraphics

/// Push-to-talk global trigger: hold Option to record, release to stop.
@MainActor
final class AIHotkeyController {
    private var modifierPollTimer: Timer?

    private var onStart: (() -> Void)?
    private var onStop: (() -> Void)?
    private var isOptionDown = false

    func install(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onStart = onStart
        self.onStop = onStop

        startModifierPolling()
    }

    func uninstall() {
        modifierPollTimer?.invalidate()
        modifierPollTimer = nil

        if isOptionDown {
            onStop?()
        }

        isOptionDown = false
        onStart = nil
        onStop = nil
    }

    private func startModifierPolling() {
        modifierPollTimer?.invalidate()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollOptionState()
            }
        }

        modifierPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollOptionState() {
        let optionDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        guard optionDown != isOptionDown else { return }

        isOptionDown = optionDown

        if optionDown {
            onStart?()
        } else {
            onStop?()
        }
    }
}
