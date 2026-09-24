import Foundation

public enum CaptureReason: String, Codable, Sendable {
    // Retained for screenshots recorded before click and scroll triggers were separated.
    case pointerIdle
    case clickIdle // Earlier captures waited two seconds after the click.
    case clickAfterIdle
    case scrollIdle
    case enter
    case manual

    public var systemImage: String {
        switch self {
        case .pointerIdle, .clickIdle, .clickAfterIdle, .scrollIdle: "computermouse"
        case .enter: "keyboard"
        case .manual: "camera"
        }
    }

    public var label: String {
        switch self {
        case .pointerIdle: String(localized: "鼠标活动停止 2 秒")
        case .clickIdle: String(localized: "移动后点击，停顿 2 秒")
        case .clickAfterIdle: String(localized: "移动并静止后点击")
        case .scrollIdle: String(localized: "上下滚动停止 2 秒")
        case .enter: String(localized: "回车触发")
        case .manual: String(localized: "手动截图")
        }
    }
}

public struct CaptureTrigger: Sendable {
    public var settings: CaptureSettings {
        didSet { if settings != oldValue { reset() } }
    }
    private var lastMovement: TimeInterval?
    private var pressedClick = false
    private var pending: (deadline: TimeInterval, reason: CaptureReason)?
    private var hasTypedLetter = false
    private static let letterKeys: Set<UInt16> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46]

    public init(settings: CaptureSettings = CaptureSettings()) { self.settings = settings }

    public mutating func activity(at time: TimeInterval) {
        guard settings.mouseTriggers.contains(.click) else { return }
        lastMovement = time
        pressedClick = false
    }

    @discardableResult
    public mutating func press(at time: TimeInterval, clickCount: Int = 1) -> Bool {
        guard settings.mouseTriggers.contains(.click) else { return false }
        let continuingClick = clickCount > 1 && pending?.reason == .clickAfterIdle && time <= (pending?.deadline ?? 0)
        pressedClick = continuingClick || lastMovement.map { time >= $0 + 1 } == true
        if pressedClick {
            lastMovement = nil
            if continuingClick { pending = nil }
        }
        return pressedClick
    }

    @discardableResult
    public mutating func click(at time: TimeInterval, doubleClickInterval: TimeInterval = 0.5) -> Bool {
        guard settings.mouseTriggers.contains(.click), pressedClick else { return false }
        pressedClick = false
        pending = (time + doubleClickInterval, .clickAfterIdle)
        return true
    }

    public mutating func scroll(at time: TimeInterval) {
        guard settings.mouseTriggers.contains(.scroll) else { return }
        pending = (time + 2, .scrollIdle)
    }

    public mutating func poll(at time: TimeInterval) -> CaptureReason? {
        guard let pending, time >= pending.deadline else { return nil }
        self.pending = nil
        if pending.reason != .clickAfterIdle { resetMouse() }
        return pending.reason
    }

    public mutating func keyDown(keyCode: UInt16, isRepeat: Bool = false, isShortcut: Bool = false) -> CaptureReason? {
        if keyCode == 36 || keyCode == 76 { return enter(isRepeat: isRepeat) }
        if !isShortcut && Self.letterKeys.contains(keyCode) { hasTypedLetter = true }
        return nil
    }

    public mutating func enter(isRepeat: Bool) -> CaptureReason? {
        guard !isRepeat else { return nil }
        guard settings.keyboard == .returnKey || hasTypedLetter else { return nil }
        reset()
        return .enter
    }

    public mutating func resetKeyboard() { hasTypedLetter = false }

    public mutating func reset() {
        resetKeyboard()
        resetMouse()
    }

    private mutating func resetMouse() {
        lastMovement = nil
        pressedClick = false
        pending = nil
    }
}
