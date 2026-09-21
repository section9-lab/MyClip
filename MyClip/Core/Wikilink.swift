import Foundation

public struct Wikilink: Sendable, Hashable {
    /// Link target without any `#heading` fragment.
    public let target: String
    /// Heading text after `#`, or an empty string.
    public let fragment: String
    /// Display label; equals the raw link text when no `|label` was written.
    public let label: String
    /// True when the author wrote an explicit `|label`.
    public let hasLabel: Bool
    let range: NSRange

    /// The target as written, including any fragment.
    public var rawTarget: String { fragment.isEmpty ? target : target + "#" + fragment }

    private static func maskingCode(_ text: String) -> NSMutableString {
        // Mask code without changing UTF-16 offsets used for replacements.
        let masked = NSMutableString(string: text)
        for pattern in ["(?ms)^ {0,3}(`{3,}|~{3,})[^\\n]*\\n.*?(?:^ {0,3}\\1[ \\t]*(?:\\n|$)|\\z)", "`+[^`\\n]*`+"] {
            let expression = try! NSRegularExpression(pattern: pattern)
            for match in expression.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)).reversed() {
                masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
            }
        }
        return masked
    }

    public static func parse(_ text: String) -> [Wikilink] {
        let masked = maskingCode(text)
        let expression = try! NSRegularExpression(pattern: #"(?<!\\)\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]"#)
        return expression.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)).compactMap { match in
            let raw = masked.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            var target = raw, fragment = ""
            if let hash = raw.firstIndex(of: "#") {
                target = raw[..<hash].trimmingCharacters(in: .whitespaces)
                fragment = raw[raw.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            }
            guard !target.isEmpty else { return nil }
            let hasLabel = match.range(at: 2).location != NSNotFound
            let label = hasLabel ? masked.substring(with: match.range(at: 2)) : raw
            return Wikilink(target: target, fragment: fragment, label: label, hasLabel: hasLabel, range: match.range)
        }
    }

    public static func markdown(_ text: String) -> String {
        let result = NSMutableString(string: text)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "%?#"))
        for link in parse(text).reversed() {
            guard let target = link.target.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
            let fragment = link.fragment.isEmpty ? "" : "#" + (link.fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "%#"))) ?? "")
            let label = link.label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            result.replaceCharacters(in: link.range, with: "[\(label)](myclip-memory:///\(target)\(fragment))")
        }
        let masked = maskingCode(result as String)
        let annotations = try! NSRegularExpression(pattern: #"(?m)^<!-- myclip-event [^\r\n]* -->[ \t]*(?:\r?\n|$)"#)
        for match in annotations.matches(in: result as String, range: NSRange(location: 0, length: result.length)).reversed()
            where masked.substring(with: match.range).hasPrefix("<!-- myclip-event ") {
            result.replaceCharacters(in: match.range, with: "")
        }
        return result as String
    }

    static func replacingTargets(in text: String, with targets: [String: String]) -> String {
        let result = NSMutableString(string: text)
        for link in parse(text).reversed() {
            guard let target = targets[link.target.lowercased()] else { continue }
            let fragment = link.fragment.isEmpty ? "" : "#" + link.fragment
            result.replaceCharacters(in: link.range, with: link.hasLabel ? "[[\(target)\(fragment)|\(link.label)]]" : "[[\(target)\(fragment)]]")
        }
        return result as String
    }
}

/// One resolved Wikilink occurrence between two memories.
public struct MemoryLinkEdge: Sendable, Hashable {
    public let source: UUID
    public let target: UUID
    /// Heading fragment written in the link, or empty.
    public let fragment: String
    /// Explicit label written in the link, or empty.
    public let label: String
    /// Passage ordinal in the source document that holds the link.
    public let ordinal: Int?
    /// Text of the source passage holding the link, truncated for display.
    public let passage: String
}

public struct MemoryRelations: Sendable {
    public let outgoing: [KnowledgeEntry]
    public let incoming: [KnowledgeEntry]
    public let unresolved: [String]
    public let outgoingEdges: [MemoryLinkEdge]
    public let incomingEdges: [MemoryLinkEdge]
}

extension LibraryStore {
    static let linkPassageLimit = 400

    /// Finds the single entry row a link target refers to. Nil when missing or ambiguous.
    func resolveMemoryRow(_ target: String) throws -> [String: String]? {
        let stripped = target.firstIndex(of: "#").map { String(target[..<$0]) } ?? target
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let name = trimmed.hasSuffix(".md") ? String(trimmed.dropLast(3)) : trimmed
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
        return rows.count == 1 ? rows[0] : nil
    }

    func resolveMemory(_ target: String) throws -> KnowledgeEntry? {
        try resolveMemoryRow(target).map(entry)
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

    static func passageText(_ body: String, ordinal: Int?) -> String {
        guard let ordinal, let passage = MemoryPassage.parse(body, sourceIDs: []).first(where: { $0.ordinal == ordinal }) else { return "" }
        return String(passage.text.prefix(linkPassageLimit))
    }

    private func edges(_ rows: [[String: String]], bodies: [UUID: String]) -> [MemoryLinkEdge] {
        rows.compactMap { row in
            guard let source = row["source"].flatMap(UUID.init(uuidString:)), let target = row["target_id"].flatMap(UUID.init(uuidString:)) else { return nil }
            let ordinal = row["ordinal"].flatMap(Int.init)
            return MemoryLinkEdge(source: source, target: target, fragment: row["fragment"] ?? "", label: row["label"] ?? "",
                                  ordinal: ordinal, passage: bodies[source].map { Self.passageText($0, ordinal: ordinal) } ?? "")
        }
    }

    /// Links between distinct memories. Links a page makes to its own sections are navigation, not relations.
    public func relations(_ id: UUID, includeArchives: Bool = true) throws -> MemoryRelations {
        let memory = try readMemory(id)
        let outgoingRows = try database.run("SELECT * FROM memory_links WHERE source=? AND (target_id IS NULL OR target_id<>source) ORDER BY ordinal, rowid", [id.uuidString])
        var outgoing: [KnowledgeEntry] = [], unresolved: [String] = []
        for row in outgoingRows {
            if let target = row["target_id"] {
                if !outgoing.contains(where: { $0.id.uuidString == target }), let entryRow = try database.run("SELECT * FROM entries WHERE id=?", [target]).first {
                    outgoing.append(try entry(entryRow))
                }
            } else if let target = row["target"] {
                let written = (row["fragment"] ?? "").isEmpty ? target : target + "#" + row["fragment"]!
                if !unresolved.contains(written) { unresolved.append(written) }
            }
        }
        var incomingRows = try database.run("SELECT * FROM memory_links WHERE target_id=? AND source<>target_id ORDER BY source, ordinal, rowid", [id.uuidString])
        var incoming: [KnowledgeEntry] = [], bodies: [UUID: String] = [id: memory.body], skipped = Set<String>()
        for row in incomingRows {
            guard let source = row["source"], !incoming.contains(where: { $0.id.uuidString == source }), !skipped.contains(source),
                  let entryRow = try database.run("SELECT * FROM entries WHERE id=?", [source]).first else { continue }
            let item = try entry(entryRow)
            if !includeArchives && item.relativePath.hasPrefix(Self.archivePrefix) { skipped.insert(source); continue }
            incoming.append(item)
            bodies[item.id] = item.body
        }
        incomingRows.removeAll { skipped.contains($0["source"] ?? "") }
        incoming.sort { $0.updatedAt > $1.updatedAt }
        return MemoryRelations(outgoing: outgoing, incoming: incoming, unresolved: unresolved,
                               outgoingEdges: edges(outgoingRows.filter { $0["target_id"] != nil }, bodies: bodies),
                               incomingEdges: edges(incomingRows, bodies: bodies))
    }

    /// Rebuilds the outgoing edges of one memory and refreshes anchor text on every affected target.
    func indexLinks(id: UUID, body: String) throws {
        var affected = Set(try database.run("SELECT DISTINCT target_id FROM memory_links WHERE source=? AND target_id IS NOT NULL", [id.uuidString]).compactMap { $0["target_id"] })
        try database.run("DELETE FROM memory_links WHERE source=?", [id.uuidString])
        let passages = MemoryPassage.parse(body, sourceIDs: [])
        for link in Wikilink.parse(body) {
            let target = UUID(uuidString: link.target)?.uuidString ?? link.target
            let resolved = ((try? resolveMemoryRow(link.target)) ?? nil)?["id"]
            let offset = Range(link.range, in: body).map { body.distance(from: body.startIndex, to: $0.lowerBound) }
            let ordinal = offset.flatMap { position in passages.first { $0.startOffset <= position && position < $0.endOffset }?.ordinal }
            try database.run("INSERT INTO memory_links(source,target,target_id,fragment,ordinal,label) VALUES(?,?,?,?,?,?)",
                             [id.uuidString, target, resolved, link.fragment, ordinal.map(String.init), link.hasLabel ? link.label : ""])
            if let resolved { affected.insert(resolved) }
        }
        try refreshAnchors(affected)
    }

    /// Tokens of every explicit label other memories use when linking to this target.
    func anchorTerms(_ target: String) throws -> String {
        let labels = try database.run("SELECT DISTINCT label FROM memory_links WHERE target_id=? AND label<>''", [target]).compactMap { $0["label"] }
        return Self.tokens(labels.joined(separator: " "))
    }

    /// Anchor text written in other memories becomes a searchable alias of the target.
    func refreshAnchors(_ targets: Set<String>) throws {
        for target in targets where target != "" {
            try database.run("UPDATE entry_search SET anchors=? WHERE id=?", [try anchorTerms(target), target])
        }
    }

    /// Resolves edges whose target did not exist when they were written.
    func resolvePendingLinks() throws {
        var affected = Set<String>()
        for row in try database.run("SELECT rowid,target FROM memory_links WHERE target_id IS NULL") {
            guard let rowid = row["rowid"], let target = row["target"], let resolved = ((try? resolveMemoryRow(target)) ?? nil)?["id"] else { continue }
            try database.run("UPDATE memory_links SET target_id=? WHERE rowid=?", [resolved, rowid])
            affected.insert(resolved)
        }
        try refreshAnchors(affected)
    }
}
