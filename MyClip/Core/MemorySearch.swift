import Foundation

public enum MemorySearchTimeField: String, Sendable {
    case updated
    case captured
    case event
}

public struct MemorySearchResult: Sendable {
    public let memory: KnowledgeEntry
    public let matches: [MemoryPassage]
}

extension LibraryStore {
    public func searchMemories(query: String, limit: Int = 20, offset: Int = 0, since: Date? = nil, app: String? = nil,
                               until: Date? = nil, timeField: MemorySearchTimeField = .updated) throws -> [KnowledgeEntry] {
        try synchronizeMemoryFiles()
        return try matchingMemories(query: query, limit: min(max(limit, 1), 50), offset: max(0, offset), since: since, until: until, timeField: timeField, app: app)
    }

    public func searchMemoryResults(query: String, limit: Int = 20, offset: Int = 0, since: Date? = nil, app: String? = nil,
                                   until: Date? = nil, timeField: MemorySearchTimeField = .updated) throws -> [MemorySearchResult] {
        let entries = try searchMemories(query: query, limit: limit, offset: offset, since: since, app: app, until: until, timeField: timeField)
        return try entries.map { entry in
            var ordinals: Set<Int>?
            if timeField == .event {
                let predicate = Self.eventPassageFilter(query: query, since: since, until: until, app: app)
                let rows = try database.run("SELECT p.ordinal FROM memory_passages p WHERE p.entry_id=? AND \(predicate.sql)", [entry.id.uuidString] + predicate.args)
                ordinals = Set(rows.compactMap { $0["ordinal"].flatMap(Int.init) })
            }
            let ranked = entry.rankedPassages(query: query, ordinals: ordinals)
            let hits = ranked.filter { $0.score(query: query).coverage > 0 || $0.score(query: query).phrase > 0 }
            let selected = hits.isEmpty ? Array(ranked.prefix(1)) : Array(hits.prefix(3))
            return MemorySearchResult(memory: entry, matches: selected.map { $0.excerpt(query: query, limit: 1600) })
        }
    }

    private static func matchExpression(_ term: String, phrase: Bool = false) -> String {
        let tokens = Self.tokens(term).split(separator: " ").map(String.init)
        func quoted(_ text: String) -> String { "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        if phrase { return quoted(tokens.isEmpty ? term : tokens.joined(separator: " ")) }
        return tokens.isEmpty ? quoted(term) : tokens.map(quoted).joined(separator: " OR ")
    }

    private static func eventPassageFilter(query: String, since: Date?, until: Date?, app: String?) -> (sql: String, args: [String?]) {
        var filters = ["p.event_start IS NOT NULL"], args: [String?] = []
        if let since {
            filters.append("(p.event_end>? OR (p.event_start=p.event_end AND p.event_start>=?))")
            args += [String(since.timeIntervalSince1970), String(since.timeIntervalSince1970)]
        }
        if let until { filters.append("p.event_start<?"); args.append(String(until.timeIntervalSince1970)) }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !term.isEmpty {
            filters.append("""
                p.ordinal IN (SELECT ordinal FROM memory_passage_search WHERE entry_id=p.entry_id AND memory_passage_search MATCH ?
                    UNION SELECT ordinal FROM memory_passage_search WHERE entry_id=p.entry_id AND (instr(lower(title),?)>0 OR instr(lower(body),?)>0))
                """)
            args += [matchExpression(term), term, term]
        }
        if let app, !app.isEmpty {
            filters.append("EXISTS (SELECT 1 FROM json_each(p.source_ids) s JOIN captures c ON c.id=s.value WHERE c.app_name=? OR c.bundle_id=?)")
            args += [app, app]
        }
        return (filters.joined(separator: " AND "), args)
    }

    // The app lists all matches; MCP applies its page limit to the same ranking and filters.
    func matchingMemories(query: String, limit: Int? = nil, offset: Int = 0, since: Date? = nil, until: Date? = nil,
                          timeField: MemorySearchTimeField = .updated, app: String? = nil) throws -> [KnowledgeEntry] {
        if let since, let until, since >= until { throw LibraryError.invalidResult("since 必须早于 until。") }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sql = "SELECT e.* FROM entries e", filters: [String] = [], args: [String?] = []
        var order = "e.updated_at DESC,e.id"
        if !term.isEmpty {
            // Materialize before joining so FTS5 evaluates BM25 in the MATCH context.
            sql = """
                WITH matches AS MATERIALIZED (
                    SELECT id,bm25(entry_search,0,5,1,1) AS score FROM entry_search WHERE entry_search MATCH ?
                )
                SELECT e.* FROM entries e LEFT JOIN matches m ON m.id=e.id
                """
            args.append(Self.matchExpression(term))
            filters.append("(m.id IS NOT NULL OR e.id IN (SELECT id FROM entry_search WHERE instr(lower(title),?)>0 OR instr(lower(body),?)>0))")
            args += [term, term]
            order = """
                CASE WHEN lower(e.title)=? THEN 0 WHEN instr(lower(e.title),?)>0 THEN 1
                    WHEN e.id IN (SELECT id FROM entry_search WHERE entry_search MATCH ?)
                      OR e.id IN (SELECT id FROM entry_search WHERE instr(lower(body),?)>0) THEN 2 ELSE 3 END,
                coalesce(m.score,0),
                """ + order
        }
        if timeField == .event {
            let predicate = Self.eventPassageFilter(query: query, since: since, until: until, app: app)
            filters.append("EXISTS (SELECT 1 FROM memory_passages p WHERE p.entry_id=e.id AND \(predicate.sql))")
            args += predicate.args
        }
        var sourceFilters: [String] = []
        if let since, timeField != .event {
            if timeField == .updated { filters.append("e.updated_at>=?") }
            else { sourceFilters.append("c.captured_at>=?") }
            args.append(String(since.timeIntervalSince1970))
        }
        if let until, timeField != .event {
            if timeField == .updated { filters.append("e.updated_at<?") }
            else { sourceFilters.append("c.captured_at<?") }
            args.append(String(until.timeIntervalSince1970))
        }
        if let app, !app.isEmpty, timeField != .event {
            sourceFilters.append("(c.app_name=? OR c.bundle_id=?)")
            args += [app, app]
        }
        if !sourceFilters.isEmpty {
            filters.append("EXISTS (SELECT 1 FROM entry_sources s JOIN captures c ON c.id=s.capture_id WHERE s.entry_id=e.id AND \(sourceFilters.joined(separator: " AND ")))")
        }
        if !filters.isEmpty { sql += " WHERE " + filters.joined(separator: " AND ") }
        sql += " ORDER BY " + order
        if !term.isEmpty { args += [term, term, Self.matchExpression(term, phrase: true), term] }
        if let limit {
            sql += " LIMIT ? OFFSET ?"
            args += [String(limit), String(offset)]
        }
        return try database.run(sql, args).map(entry)
    }
}

extension KnowledgeEntry {
    /// Returns an unmodified body slice; its character offset can be passed to read_memory.
    public func searchExcerpt(query: String) -> (text: String, offset: Int) {
        guard let best = rankedPassages(query: query).first?.excerpt(query: query, limit: 360) else { return ("", 0) }
        return (best.text, best.startOffset)
    }
}
