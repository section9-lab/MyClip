import Foundation

public enum CaptureScope: String, CaseIterable, Sendable, Identifiable {
    case focusedWindow, focusedDisplay
    public var id: String { rawValue }
    public var label: String { self == .focusedWindow ? String(localized: "焦点应用窗口") : String(localized: "焦点显示器全屏") }
}

public enum MouseCaptureTrigger: String, CaseIterable, Sendable, Identifiable {
    case click, scroll
    public var id: String { rawValue }
    public var label: String { self == .click ? String(localized: "鼠标移动后5秒内点击") : String(localized: "scroll向下滚动后静止5秒") }
    public var shortLabel: String { self == .click ? String(localized: "移动后点击") : String(localized: "向下滚动") }
}

public enum KeyboardCaptureMode: String, CaseIterable, Sendable, Identifiable {
    case returnKey, afterLetters
    public var id: String { rawValue }
    public var label: String { self == .returnKey ? String(localized: "回车后截图") : String(localized: "字母键后再回车") }
}

public enum CaptureFilterStrategy: String, CaseIterable, Sendable, Identifiable {
    case similarImages, nearUniformImages
    public static let defaults: Set<Self> = [.similarImages, .nearUniformImages]
    public var id: String { rawValue }
    public var label: String { self == .similarImages ? String(localized: "相似画面去重") : String(localized: "近纯色画面过滤（≥98%）") }
    public var shortLabel: String { self == .similarImages ? String(localized: "相似画面") : String(localized: "近纯色画面") }
}

public struct CaptureSettings: Equatable, Sendable, CustomStringConvertible {
    public var scope: CaptureScope
    public var mouseTriggers: Set<MouseCaptureTrigger>
    public var keyboard: KeyboardCaptureMode
    public var filterStrategies: Set<CaptureFilterStrategy>
    public var mouseSummary: String {
        mouseTriggers.isEmpty ? String(localized: "已关闭") : MouseCaptureTrigger.allCases.filter { mouseTriggers.contains($0) }.map(\.shortLabel).joined(separator: "、")
    }
    public var filterSummary: String {
        filterStrategies.isEmpty ? String(localized: "已关闭") : CaptureFilterStrategy.allCases.filter { filterStrategies.contains($0) }.map(\.shortLabel).joined(separator: "、")
    }
    public var description: String {
        let scopeText = scope == .focusedWindow ? String(localized: "只记录前台焦点窗口。") : String(localized: "记录焦点窗口所在的显示器全屏。")
        let triggers = MouseCaptureTrigger.allCases.filter { mouseTriggers.contains($0) }.map(\.label)
            + [keyboard == .returnKey ? String(localized: "每次按下回车") : String(localized: "字母键后再回车")]
        return scopeText + String(localized: "触发方式：") + triggers.joined(separator: "；") + "。"
    }

    public init(scope: CaptureScope = .focusedWindow, mouseTriggers: Set<MouseCaptureTrigger> = [.click, .scroll], keyboard: KeyboardCaptureMode = .afterLetters,
                filterStrategies: Set<CaptureFilterStrategy> = CaptureFilterStrategy.defaults) {
        self.scope = scope
        self.mouseTriggers = mouseTriggers
        self.keyboard = keyboard
        self.filterStrategies = filterStrategies
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
                               keyboard: KeyboardCaptureMode(rawValue: defaults.string(forKey: "myclip.keyboardTrigger") ?? "") ?? .afterLetters,
                               filterStrategies: defaults.stringArray(forKey: "myclip.captureFilterStrategies").map {
                                   Set($0.compactMap(CaptureFilterStrategy.init(rawValue:)))
                               } ?? CaptureFilterStrategy.defaults)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(scope.rawValue, forKey: "myclip.captureScope")
        defaults.set(mouseTriggers.map(\.rawValue).sorted(), forKey: "myclip.mouseTriggers")
        defaults.set(keyboard.rawValue, forKey: "myclip.keyboardTrigger")
        defaults.set(filterStrategies.map(\.rawValue).sorted(), forKey: "myclip.captureFilterStrategies")
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
