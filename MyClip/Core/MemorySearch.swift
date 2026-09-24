import Foundation

public enum MemorySearchTimeField: String, Sendable {
    /// The file edit time; used by the app's own list.
    case updated
    /// When the content happened: an annotated event on a passage, else a cited screenshot, else the file edit time.
    case observed
}

/// Fixed ranking constants, chosen on the LoCoMo development split (conversations 00–04).
enum RankingConstants {
    /// Share of lexical relevance from a page's best passages; the rest is whole-page BM25.
    static let passageWeight = 0.5
    /// Passages that count toward a page, each weighted half as much as the one before.
    static let passageDepth = 3
    static let passageDecay = 0.5
}

extension LibraryStore {
    static let archivePrefix = "Wiki/Archives/"

    public func searchMemories(query: String, limit: Int = 20, offset: Int = 0, since: Date? = nil, app: String? = nil,
                               until: Date? = nil, timeField: MemorySearchTimeField = .updated, includeArchives: Bool = true) throws -> [KnowledgeEntry] {
        try synchronizeMemoryFiles()
        return try matchingMemories(query: query, limit: min(max(limit, 1), 50), offset: max(0, offset), since: since, until: until, timeField: timeField, app: app, includeArchives: includeArchives)
    }

    static func matchExpression(_ term: String, phrase: Bool = false) -> String {
        let tokens = Self.tokens(term).split(separator: " ").map(String.init)
        func quoted(_ text: String) -> String { "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        if phrase { return quoted(tokens.isEmpty ? term : tokens.joined(separator: " ")) }
        return tokens.isEmpty ? quoted(term) : tokens.map(quoted).joined(separator: " OR ")
    }

    /// A page matches a time range and app by when its content happened. Pages with annotated events match when one of
    /// those passages overlaps the range and, if an app is given, cites a screenshot from it. Pages without events match
    /// when one cited screenshot satisfies both the range and the app. Pages with neither fall back to the edit time and
    /// never match an app.
    private static func observedFilter(since: Date?, until: Date?, app: String?) -> (sql: String, args: [String?]) {
        let app = app.flatMap { $0.isEmpty ? nil : $0 }
        guard since != nil || until != nil || app != nil else { return ("", []) }
        var event = ["p.event_start IS NOT NULL"], capture: [String] = [], update: [String] = []
        var eventArgs: [String?] = [], captureArgs: [String?] = [], updateArgs: [String?] = []
        if let since {
            let value = String(since.timeIntervalSince1970)
            event.append("(p.event_end>? OR (p.event_start=p.event_end AND p.event_start>=?))"); eventArgs += [value, value]
            capture.append("c.captured_at>=?"); captureArgs.append(value)
            update.append("e.updated_at>=?"); updateArgs.append(value)
        }
        if let until {
            let value = String(until.timeIntervalSince1970)
            event.append("p.event_start<?"); eventArgs.append(value)
            capture.append("c.captured_at<?"); captureArgs.append(value)
            update.append("e.updated_at<?"); updateArgs.append(value)
        }
        if let app {
            event.append("EXISTS (SELECT 1 FROM json_each(p.source_ids) j JOIN captures c ON c.id=j.value WHERE c.app_name=? OR c.bundle_id=?)"); eventArgs += [app, app]
            capture.append("(c.app_name=? OR c.bundle_id=?)"); captureArgs += [app, app]
            update.append("0")
        }
        let hasEvents = "EXISTS (SELECT 1 FROM memory_passages p WHERE p.entry_id=e.id AND p.event_start IS NOT NULL)"
        let hasSources = "EXISTS (SELECT 1 FROM entry_sources s WHERE s.entry_id=e.id)"
        let sql = """
            (EXISTS (SELECT 1 FROM memory_passages p WHERE p.entry_id=e.id AND \(event.joined(separator: " AND ")))
             OR (NOT \(hasEvents) AND EXISTS (SELECT 1 FROM entry_sources s JOIN captures c ON c.id=s.capture_id WHERE s.entry_id=e.id\(capture.map { " AND " + $0 }.joined())))
             OR (NOT \(hasEvents) AND NOT \(hasSources) AND \(update.joined(separator: " AND "))))
            """
        return (sql, eventArgs + captureArgs + updateArgs)
    }

    // The app lists all matches; MCP applies its page limit to the same ranking and filters.
    /// `candidateSink` receives the unranked full-text candidate rows (with `tier` and `entry_score`) instead of a ranked list.
    func matchingMemories(query: String, limit: Int? = nil, offset: Int = 0, since: Date? = nil, until: Date? = nil,
                          timeField: MemorySearchTimeField = .updated, app: String? = nil, includeArchives: Bool = true,
                          candidateSink: (([[String: String]], String) -> Void)? = nil) throws -> [KnowledgeEntry] {
        if let since, let until, since >= until { throw LibraryError.invalidResult(String(localized: "since 必须早于 until。")) }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sql = "SELECT e.* FROM entries e", filters: [String] = [], args: [String?] = []
        let order = "e.updated_at DESC,e.id"
        var tier = ""
        if !term.isEmpty {
            // Materialize before joining so FTS5 evaluates BM25 in the MATCH context.
            // Column weights: title 5, body 1, segmented terms 1, anchor text from other memories 3, declared aliases 4.
            sql = """
                WITH matches AS MATERIALIZED (
                    SELECT id,bm25(entry_search,0,5,1,1,3,4) AS score FROM entry_search WHERE entry_search MATCH ?
                )
                SELECT e.* FROM entries e LEFT JOIN matches m ON m.id=e.id
                """
            args.append(Self.matchExpression(term))
            filters.append("(m.id IS NOT NULL OR e.id IN (SELECT id FROM entry_search WHERE instr(lower(title),?)>0 OR instr(lower(body),?)>0 OR instr(aliases,?)>0))")
            args += [term, term, term]
            // An exact alias ranks right after an exact title: the author declared that name for this page.
            tier = """
                CASE WHEN lower(e.title)=? THEN 0
                    WHEN e.id IN (SELECT id FROM entry_search WHERE instr(aliases,?)>0) THEN 1
                    WHEN instr(lower(e.title),?)>0 THEN 2
                    WHEN e.id IN (SELECT id FROM entry_search WHERE entry_search MATCH ?)
                      OR e.id IN (SELECT id FROM entry_search WHERE instr(lower(body),?)>0) THEN 3 ELSE 4 END
                """
            sql = sql.replacingOccurrences(of: "SELECT e.* FROM entries e LEFT JOIN", with: "SELECT e.*, \(tier) AS tier, coalesce(m.score,0) AS entry_score FROM entries e LEFT JOIN")
        }
        if !includeArchives {
            filters.append("NOT EXISTS (SELECT 1 FROM memory_files f WHERE f.id=e.id AND f.path LIKE ?)")
            args.append(Self.archivePrefix + "%")
        }
        switch timeField {
        case .updated:
            if let since { filters.append("e.updated_at>=?"); args.append(String(since.timeIntervalSince1970)) }
            if let until { filters.append("e.updated_at<?"); args.append(String(until.timeIntervalSince1970)) }
            if let app, !app.isEmpty {
                filters.append("EXISTS (SELECT 1 FROM entry_sources s JOIN captures c ON c.id=s.capture_id WHERE s.entry_id=e.id AND (c.app_name=? OR c.bundle_id=?))")
                args += [app, app]
            }
        case .observed:
            let filter = Self.observedFilter(since: since, until: until, app: app)
            if !filter.sql.isEmpty { filters.append(filter.sql); args += filter.args }
        }
        if !filters.isEmpty { sql += " WHERE " + filters.joined(separator: " AND ") }
        guard !term.isEmpty else {
            sql += " ORDER BY " + order
            if let limit {
                sql += " LIMIT ? OFFSET ?"
                args += [String(limit), String(offset)]
            }
            return try database.run(sql, args).map(entry)
        }
        // The tier expression is spliced into the SELECT list, so its arguments come before the WHERE arguments.
        args = [args[0], term, "\n" + term + "\n", term, Self.matchExpression(term, phrase: true), term] + args.dropFirst()
        let rows = try database.run(sql + " ORDER BY " + order, args)
        if let candidateSink { candidateSink(rows, term); return [] }
        let ranked = try rankLexically(rows: rows, term: term)
        let page = ranked.dropFirst(offset)
        return Array(limit.map { page.prefix($0) } ?? page)
    }

    /// Orders full-text candidates: exact title and alias matches first, then lexical relevance.
    private func rankLexically(rows: [[String: String]], term: String) throws -> [KnowledgeEntry] {
        try lexicalCandidates(rows: rows, term: term).sorted(by: RankedMemory.precedes).map(\.entry)
    }

    /// Scores full-text candidates by a mix of each page's best passages and its whole-page BM25, both normalized to 0...1.
    /// Passage scores let a long page rank by the paragraphs that answer the question instead of by its overall word counts.
    func lexicalCandidates(rows: [[String: String]], term: String) throws -> [RankedMemory] {
        let passageBM25 = try database.run("""
            SELECT entry_id, bm25(memory_passage_search,0,0,5,1,1) AS score FROM memory_passage_search WHERE memory_passage_search MATCH ?
            """, [Self.matchExpression(term)])
        var passages: [String: [Double]] = [:]
        for row in passageBM25 { if let id = row["entry_id"], let score = row["score"].flatMap(Double.init) { passages[id, default: []].append(-score) } }
        let passageScores = rows.map { row -> Double in
            let best = (passages[row["id"] ?? ""] ?? []).sorted(by: >).prefix(RankingConstants.passageDepth)
            return best.enumerated().reduce(0) { $0 + $1.element * pow(RankingConstants.passageDecay, Double($1.offset)) }
        }
        let entryScores = rows.map { -(($0["entry_score"]).flatMap(Double.init) ?? 0) }
        let passageMax = passageScores.max() ?? 0, entryMax = entryScores.max() ?? 0
        return try rows.indices.map { index in
            let passage = passageMax > 0 ? passageScores[index] / passageMax : 0
            let page = entryMax > 0 ? entryScores[index] / entryMax : 0
            return RankedMemory(entry: try entry(rows[index]), tier: rows[index]["tier"].flatMap(Int.init) ?? 4,
                                score: RankingConstants.passageWeight * passage + (1 - RankingConstants.passageWeight) * page)
        }
    }
}

/// A memory with its ranking tier (exact title, exact alias, title contains, whole phrase, other) and relevance in 0...1.
struct RankedMemory {
    let entry: KnowledgeEntry
    var tier: Int
    var score: Double

    static func precedes(_ left: RankedMemory, _ right: RankedMemory) -> Bool {
        left.tier != right.tier ? left.tier < right.tier : left.score != right.score ? left.score > right.score : left.entry.updatedAt > right.entry.updatedAt
    }
}

extension KnowledgeEntry {
    /// Returns an unmodified body slice around the best match and its character offset in the body.
    public func searchExcerpt(query: String) -> (text: String, offset: Int) {
        guard let best = rankedPassages(query: query).first?.excerpt(query: query, limit: 360) else { return ("", 0) }
        return (best.text, best.startOffset)
    }
}
