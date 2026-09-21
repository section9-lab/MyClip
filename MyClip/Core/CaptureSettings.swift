import Foundation

public enum CaptureScope: String, CaseIterable, Sendable, Identifiable {
    case focusedWindow, focusedDisplay
    public var id: String { rawValue }
    public var label: String { self == .focusedWindow ? "前台焦点应用窗口" : "焦点显示器全屏" }
}

public enum MouseCaptureTrigger: String, CaseIterable, Sendable, Identifiable {
    case click, scroll
    public var id: String { rawValue }
    public var label: String { self == .click ? "移动后静止 1 秒，再点击或双击" : "上下滚动停止 2 秒" }
    public var shortLabel: String { self == .click ? "静止后点击" : "停止滚动" }
}

public enum KeyboardCaptureMode: String, CaseIterable, Sendable, Identifiable {
    case returnKey, afterLetters
    public var id: String { rawValue }
    public var label: String { self == .returnKey ? "回车后截图" : "字母键后再回车" }
}

public struct CaptureSettings: Equatable, Sendable, CustomStringConvertible {
    public var scope: CaptureScope
    public var mouseTriggers: Set<MouseCaptureTrigger>
    public var keyboard: KeyboardCaptureMode
    public var mouseSummary: String {
        mouseTriggers.isEmpty ? "已关闭" : MouseCaptureTrigger.allCases.filter { mouseTriggers.contains($0) }.map(\.shortLabel).joined(separator: "、")
    }
    public var description: String {
        let scopeText = scope == .focusedWindow ? "只记录前台焦点窗口。" : "记录焦点窗口所在的显示器全屏。"
        let triggers = MouseCaptureTrigger.allCases.filter { mouseTriggers.contains($0) }.map(\.label)
            + [keyboard == .returnKey ? "每次按下回车" : "字母键后再回车"]
        return scopeText + "触发方式：" + triggers.joined(separator: "；") + "。"
    }

    public init(scope: CaptureScope = .focusedWindow, mouseTriggers: Set<MouseCaptureTrigger> = [.click, .scroll], keyboard: KeyboardCaptureMode = .afterLetters) {
        self.scope = scope
        self.mouseTriggers = mouseTriggers
        self.keyboard = keyboard
    }

    public static func load(from defaults: UserDefaults) -> CaptureSettings {
        let mouse: Set<MouseCaptureTrigger>
        if let values = defaults.stringArray(forKey: "myclip.mouseTriggers") {
            mouse = Set(values.compactMap(MouseCaptureTrigger.init(rawValue:)))
        } else {
            switch defaults.string(forKey: "myclip.mouseActivity") {
            case "pointer": mouse = [.click]
            case "scroll": mouse = [.scroll]
            default: mouse = [.click, .scroll]
            }
        }
        return CaptureSettings(scope: CaptureScope(rawValue: defaults.string(forKey: "myclip.captureScope") ?? "") ?? .focusedWindow,
                               mouseTriggers: mouse,
                               keyboard: KeyboardCaptureMode(rawValue: defaults.string(forKey: "myclip.keyboardTrigger") ?? "") ?? .afterLetters)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(scope.rawValue, forKey: "myclip.captureScope")
        defaults.set(mouseTriggers.map(\.rawValue).sorted(), forKey: "myclip.mouseTriggers")
        defaults.set(keyboard.rawValue, forKey: "myclip.keyboardTrigger")
    }
}

public struct DisplayCandidate: Sendable {
    public let id: UInt32
    public let frame: CGRect
    public init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }
}

public enum FocusedDisplayMatcher {
    public static func match(frame: CGRect, displays: [DisplayCandidate]) -> UInt32? {
        guard !frame.isNull, !frame.isInfinite, frame.width > 1, frame.height > 1 else { return nil }
        var best: UInt32?
        var largestArea: CGFloat = 0
        for display in displays.sorted(by: { $0.id < $1.id }) {
            let overlap = frame.intersection(display.frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > largestArea { largestArea = area; best = display.id }
        }
        return best
    }
}
