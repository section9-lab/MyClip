import Foundation

public struct CaptureFilter: Equatable, Sendable {
    public enum Event: String, CaseIterable, Sendable {
        case all, mouse, keyboard

        public var label: String {
            switch self {
            case .all: String(localized: "全部事件")
            case .mouse: String(localized: "鼠标")
            case .keyboard: String(localized: "键盘")
            }
        }
    }

    public var appName: String?
    public var dateRange: ClosedRange<Date>?
    public var event: Event
    public var isActive: Bool { appName != nil || dateRange != nil || event != .all }

    public init(appName: String? = nil, dateRange: ClosedRange<Date>? = nil, event: Event = .all) {
        self.appName = appName
        self.dateRange = dateRange
        self.event = event
    }
}
