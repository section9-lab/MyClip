import Foundation

public struct Wikilink: Sendable, Hashable {
    public let target: String
    public let label: String
    let range: NSRange

    public static func parse(_ text: String) -> [Wikilink] {
        // Mask code without changing UTF-16 offsets used for replacements.
        let masked = NSMutableString(string: text)
        for pattern in ["(?ms)^ {0,3}(`{3,}|~{3,})[^\\n]*\\n.*?(?:^ {0,3}\\1[ \\t]*(?:\\n|$)|\\z)", "`+[^`\\n]*`+"] {
            let expression = try! NSRegularExpression(pattern: pattern)
            for match in expression.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)).reversed() {
                masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
            }
        }
        let expression = try! NSRegularExpression(pattern: #"(?<!\\)\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]"#)
        return expression.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)).compactMap { match in
            let target = masked.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            let label = match.range(at: 2).location == NSNotFound ? target : masked.substring(with: match.range(at: 2))
            return Wikilink(target: target, label: label, range: match.range)
        }
    }

    public static func markdown(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for link in parse(text).reversed() {
            guard let target = link.target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "%?#"))) else { continue }
            let label = link.label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            result.replaceCharacters(in: link.range, with: "[\(label)](myclip-memory:///\(target))")
        }
        return result as String
    }

    static func replacingTargets(in text: String, with targets: [String: String]) -> String {
        let result = NSMutableString(string: text)
        for link in parse(text).reversed() {
            guard let target = targets[link.target.lowercased()] else { continue }
            result.replaceCharacters(in: link.range, with: link.label == link.target ? "[[\(target)]]" : "[[\(target)|\(link.label)]]")
        }
        return result as String
    }
}

public struct MemoryRelations: Sendable {
    public let outgoing: [KnowledgeEntry]
    public let incoming: [KnowledgeEntry]
    public let unresolved: [String]
}

extension LibraryStore {
    func resolveMemory(_ target: String) throws -> KnowledgeEntry? {
        let name = target.hasSuffix(".md") ? String(target.dropLast(3)) : target
        let rows: [[String: String]]
        if let id = UUID(uuidString: name) { rows = try database.run("SELECT * FROM entries WHERE id=?", [id.uuidString]) }
        else {
            let path = name + ".md"
            _ = try MemoryLayout.url(path, in: root.appendingPathComponent("Memory"))
            let exact = try database.run("SELECT e.* FROM entries e JOIN memory_files f ON f.id=e.id WHERE f.path=?", [path])
            if !exact.isEmpty { rows = exact }
            else {
                let alias = try database.run("SELECT e.* FROM entries e JOIN memory_aliases a ON a.id=e.id WHERE a.target=?", [path])
                rows = alias.isEmpty ? try database.run("SELECT * FROM entries WHERE title=? LIMIT 2", [name]) : alias
            }
        }
        return rows.count == 1 ? try entry(rows[0]) : nil
    }

    public func readMemory(_ id: UUID) throws -> KnowledgeEntry {
        try synchronizeMemoryFiles()
        guard let memory = try resolveMemory(id.uuidString) else { throw LibraryError.invalidResult("Memory 不存在。") }
        return memory
    }

    public func readMemory(path: String) throws -> KnowledgeEntry {
        try synchronizeMemoryFiles()
        _ = try MemoryLayout.url(path, in: root.appendingPathComponent("Memory"))
        guard let memory = try resolveMemory(path) else { throw LibraryError.invalidResult("Memory 不存在。") }
        return memory
    }

    public func resolveMemoryLink(_ target: String) throws -> KnowledgeEntry {
        try synchronizeMemoryFiles()
        guard let memory = try resolveMemory(target) else { throw LibraryError.invalidResult("此链接未找到唯一的 Memory。") }
        return memory
    }

    public func relations(_ id: UUID) throws -> MemoryRelations {
        let memory = try readMemory(id)
        var outgoing: [KnowledgeEntry] = [], unresolved: [String] = []
        for link in Wikilink.parse(memory.body) {
            if let target = try resolveMemory(link.target) {
                if !outgoing.contains(where: { $0.id == target.id }) { outgoing.append(target) }
            } else { unresolved.append(link.target) }
        }
        let targets = [id.uuidString, id.uuidString + ".md", memory.title, memory.title + ".md", memory.relativePath, String(memory.relativePath.dropLast(3))]
        let aliases = try database.run("SELECT target FROM memory_aliases WHERE id=?", [id.uuidString]).compactMap { $0["target"] }
        let names = targets + aliases + aliases.map { String($0.dropLast(3)) }
        let candidates = try database.run("SELECT DISTINCT entries.* FROM entries JOIN memory_links ON entries.id=memory_links.source WHERE memory_links.target COLLATE NOCASE IN (\(names.map { _ in "?" }.joined(separator: ",")))", names)
        let incoming = try candidates.map(entry).filter { candidate in
            try Wikilink.parse(candidate.body).contains { try resolveMemory($0.target)?.id == id }
        }
        return MemoryRelations(outgoing: outgoing, incoming: incoming, unresolved: unresolved)
    }

    public func searchMemories(query: String, limit: Int = 20, offset: Int = 0, since: Date? = nil, app: String? = nil) throws -> [KnowledgeEntry] {
        try synchronizeMemoryFiles()
        var filters: [String] = [], args: [String?] = []
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !term.isEmpty {
            let words = Self.tokens(term).split(separator: " ").map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND ")
            filters.append("id IN (SELECT id FROM entry_search WHERE entry_search MATCH ? UNION SELECT id FROM entry_search WHERE instr(lower(title),?)>0 OR instr(lower(body),?)>0)")
            args += [words.isEmpty ? "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\"" : words, term, term]
        }
        if let since { filters.append("updated_at>=?"); args.append(String(since.timeIntervalSince1970)) }
        if let app, !app.isEmpty {
            filters.append("id IN (SELECT s.entry_id FROM entry_sources s JOIN captures c ON c.id=s.capture_id WHERE c.app_name=? OR c.bundle_id=?)")
            args += [app, app]
        }
        let clause = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
        args += [String(min(max(limit, 1), 50)), String(max(0, offset))]
        return try database.run("SELECT * FROM entries \(clause) ORDER BY updated_at DESC,id LIMIT ? OFFSET ?", args).map(entry)
    }

    func indexLinks(id: UUID, body: String) throws {
        try database.run("DELETE FROM memory_links WHERE source=?", [id.uuidString])
        for link in Wikilink.parse(body) {
            let target = UUID(uuidString: link.target)?.uuidString ?? link.target
            try database.run("INSERT OR IGNORE INTO memory_links VALUES(?,?,?)", [id.uuidString, target, link.label])
        }
    }
}
