import Foundation

public struct WindowCandidate: Sendable {
    public let id: UInt32
    public let processID: Int32
    public let frame: CGRect
    public let title: String
    public init(id: UInt32, processID: Int32, frame: CGRect, title: String) {
        self.id = id; self.processID = processID; self.frame = frame; self.title = title
    }
}

public enum FocusedWindowMatcher {
    public static func match(processID: Int32, frame: CGRect, title: String, candidates: [WindowCandidate]) -> UInt32? {
        guard frame.width > 1, frame.height > 1 else { return nil }
        let matches = candidates.filter {
            $0.processID == processID && abs($0.frame.minX - frame.minX) <= 2 &&
            abs($0.frame.minY - frame.minY) <= 2 && abs($0.frame.width - frame.width) <= 2 &&
            abs($0.frame.height - frame.height) <= 2 && (title.isEmpty || $0.title == title)
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}
