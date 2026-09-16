import Foundation

public struct ClipAgentState: Sendable {
    public enum Phase: Sendable { case disconnected, connecting, ready, working, permission, failed, installing }
    public enum Expression: Sendable { case asleep, idle, working, happy, attention }

    public var phase: Phase = .disconnected
    public var detail = "尚未连接"
    public var authMethods: [ACPAuthMethod] = []
    public var lastCompleted: Date?
    public var available: Bool { phase == .ready || phase == .working || phase == .permission }
    public var busy: Bool { [.connecting, .working, .permission, .installing].contains(phase) }

    public init() {}

    public func expression(at date: Date) -> Expression {
        switch phase {
        case .permission, .failed: return .attention
        case .working: return .working
        case .disconnected: return .asleep
        case .connecting, .installing: return .idle
        case .ready:
            if let lastCompleted, (0..<2).contains(date.timeIntervalSince(lastCompleted)) { return .happy }
            return .idle
        }
    }
}
