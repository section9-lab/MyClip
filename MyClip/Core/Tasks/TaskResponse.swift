import Foundation

public enum TaskResponse {
    private struct Response: Decodable { let tasks: [WorkTaskDraft] }

    public static func parse(_ text: String) throws -> [WorkTaskDraft] {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !json.isEmpty, json.utf8.count <= 256_000 else { throw LibraryError.invalidResult("任务识别结果为空或过长。") }
        if json.hasSuffix("```") { json = String(json.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let expression = try NSRegularExpression(pattern: #"\{\s*"tasks"\s*:"#)
        for match in expression.matches(in: json, range: NSRange(json.startIndex..., in: json)).suffix(20).reversed() {
            guard let range = Range(match.range, in: json),
                  let response = try? JSONDecoder().decode(Response.self, from: Data(json[range.lowerBound...].utf8)) else { continue }
            guard response.tasks.count <= 40 else { throw LibraryError.invalidResult("一次最多识别 40 项任务。") }
            return response.tasks
        }
        throw LibraryError.invalidResult("Agent 未返回任务线索，可从 Memory 重新识别。")
    }
}
