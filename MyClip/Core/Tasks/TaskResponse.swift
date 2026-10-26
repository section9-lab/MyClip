import Foundation

public enum TaskResponse {
    public static func parse(_ text: String) throws -> [WorkTaskDraft] {
        try items(text).map { data in
            do { return try JSONDecoder().decode(WorkTaskDraft.self, from: data) }
            catch { throw LibraryError.invalidResult("任务字段格式错误，请按任务结构重新返回。") }
        }
    }

    /// Extract a complete object rather than decoding through trailing chat text. Keep each item separate so a
    /// malformed candidate can be quarantined without losing its siblings. Never guess between two envelopes.
    static func items(_ text: String) throws -> [Data] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 256_000 else {
            throw LibraryError.invalidResult("任务识别结果为空或过长。")
        }
        let expression = try NSRegularExpression(pattern: #"\{\s*"tasks"\s*:"#)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { throw LibraryError.invalidResult("回复中缺少 tasks JSON，任务阶段将单独重试。") }
        guard matches.count <= 20 else { throw LibraryError.invalidResult("任务 JSON 对象过多，无法确定最终结果。") }
        var envelopes: [[Data]] = []
        for match in matches {
            guard let range = Range(match.range, in: text), let object = object(in: text, from: range.lowerBound),
                  let value = try? JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any],
                  let tasks = value["tasks"] as? [Any] else { continue }
            guard tasks.count <= 40 else { throw LibraryError.invalidResult("一次最多识别 40 项任务。") }
            envelopes.append(try tasks.map { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) })
        }
        guard envelopes.count == 1, let items = envelopes.first else {
            throw LibraryError.invalidResult(envelopes.isEmpty ? "tasks JSON 不完整或格式错误。" : "回复包含多个任务 JSON，无法确定最终结果。")
        }
        return items
    }

    private static func object(in text: String, from start: String.Index) -> Substring? {
        var depth = 0, quoted = false, escaped = false
        for index in text[start...].indices {
            let character = text[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return text[start...index] }
            }
        }
        return nil
    }
}
