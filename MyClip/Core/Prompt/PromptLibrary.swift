import Foundation

/// Prompt bodies live as Markdown in `Resources/Prompts`. This type only loads and renders them, so the Swift sources
/// contain no prompt prose.
enum PromptLibrary {
    /// SwiftPM lays a resource bundle out as `Contents/Resources/Resources` on macOS and as `Resources/Resources`
    /// (or a flat `Resources`) in other build layouts, so pick the first candidate that holds a known prompt file.
    private static let directory: URL = {
        let root = Bundle.module.resourceURL ?? Bundle.module.bundleURL
        let bundle = Bundle.module.bundleURL
        let candidates = [
            root.appendingPathComponent("Resources/Prompts", isDirectory: true),
            root.appendingPathComponent("Prompts", isDirectory: true),
            bundle.appendingPathComponent("Contents/Resources/Resources/Prompts", isDirectory: true),
            bundle.appendingPathComponent("Contents/Resources/Prompts", isDirectory: true),
            bundle.appendingPathComponent("Resources/Resources/Prompts", isDirectory: true),
            bundle.appendingPathComponent("Resources/Prompts", isDirectory: true),
            bundle.appendingPathComponent("Prompts", isDirectory: true)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("shared/sandbox.md").path) } ?? candidates[0]
    }()

    static func text(_ name: String) -> String {
        let url = directory.appendingPathComponent(name.hasSuffix(".md") ? name : name + ".md")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing prompt file: \(name) in \(directory.path); exists=\(FileManager.default.fileExists(atPath: url.path))")
        }
        return strippingFrontMatter(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func render(_ name: String, _ values: [String: String]) -> String {
        var result = text(name)
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        if let range = result.range(of: #"\{\{[A-Za-z0-9_]+\}\}"#, options: .regularExpression) {
            preconditionFailure("Unfilled placeholder \(result[range]) in \(name)")
        }
        return result
    }

    static func json(_ name: String) -> [[String: Any]] {
        let file = name.hasSuffix(".json") ? name : name + ".json"
        let url = directory.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            preconditionFailure("Missing or invalid prompt JSON: \(name)")
        }
        return rows
    }

    private static func strippingFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---\n"),
              let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return text
        }
        return String(text[end.upperBound...])
    }
}
