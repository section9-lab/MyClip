import Foundation

/// Prompt bodies live as Markdown in `Resources/Prompts`. This type only loads and renders them, so the Swift sources
/// contain no prompt prose.
enum PromptLibrary {
    private static let directory = Bundle.module.resourceURL!.appendingPathComponent("Resources/Prompts", isDirectory: true)

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
