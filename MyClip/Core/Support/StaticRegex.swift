import Foundation

extension NSRegularExpression {
    /// Compiles a pattern that is part of the source code. A bad pattern is a programming error, so the failure names
    /// the pattern instead of escaping as a crash without context.
    static func staticPattern(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid static regular expression \(pattern.debugDescription): \(error)")
        }
    }
}
