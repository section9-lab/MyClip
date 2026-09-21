import Foundation

public enum MemorySearchTimeField: String, Sendable {
    case updated
    case captured
    case event
}

public struct MemorySearchResult: Sendable {
    public let memory: KnowledgeEntry
    public let matches: [MemoryPassage]
    /// Queries that ranked this memory; one entry for a single-query search.
    public let matchedQueries: [String]
}

/// Why a related memory was reached from a search hit.
public struct MemoryRelatedVia: Sendable {
    public let from: UUID
    /// `outgoing` when the hit links to the related memory, `backlink` when the related memory links to the hit.
    public let direction: String
    public let label: String
    public let fragment: String
    public let ordinal: Int?
    /// Passage that holds the link, taken from whichever document wrote it.
    public let passage: String
}

public struct MemoryRelatedResult: Sendable {
    public let memory: KnowledgeEntry
    public let score: Double
    public let via: [MemoryRelatedVia]
}

public struct MemorySearchPage: Sendable {
    public let results: [MemorySearchResult]
    public let related: [MemoryRelatedResult]
}

extension LibraryStore {
    static let archivePrefix = "Wiki/Archives/"
    static let relatedLimit = 8

    public func searchMemories(query: String, limit: Int = 20, offset: Int = 0, since: Date? = nil, app: String? = nil,
                               until: Date? = nil, timeField: MemorySearchTimeField = .updated, includeArchives: Bool = true) throws -> [KnowledgeEntry] {
        try synchronizeMemoryFiles()
        return try matchingMemories(query: query, limit: min(max(limit, 1), 50), offset: max(0, offset), since: since, until: until, timeField: timeField, app: app, includeArchives: includeArchives)
    }

    public func searchMemoryResults(query: String, limit: Int = 20, offset: Int = 0, since: Date? = nil, app: String? = nil,
                                    until: Date? = nil, timeField: MemorySearchTimeField = .updated) throws -> [MemorySearchResult] {
        try searchMemoryPage(queries: [query], limit: limit, offset: offset, since: since, app: app, until: until, timeField: timeField, includeArchives: true, expand: false).results
    }

    /// Ranks memories for one or more queries, then expands the page one hop along resolved Wikilinks.
    public func searchMemoryPage(queries rawQueries: [String], limit: Int = 20, offset: Int = 0, since: Date? = nil, app: String? = nil,
                                 until: Date? = nil, timeField: MemorySearchTimeField = .updated, includeArchives: Bool = false, expand: Bool = true) throws -> MemorySearchPage {
        try synchronizeMemoryFiles()
        let limit = min(max(limit, 1), 50), offset = max(0, offset)
        var queries: [String] = []
        for query in rawQueries.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !query.isEmpty && !queries.contains(query) { queries.append(query) }
        if queries.isEmpty { queries = [""] }
        var matched: [UUID: [String]] = [:]
        let entries: [KnowledgeEntry]
        if queries.count == 1 {
            entries = try matchingMemories(query: queries[0], limit: limit, offset: offset, since: since, until: until, timeField: timeField, app: app, includeArchives: includeArchives)
            for item in entries { matched[item.id] = queries }
        } else {
            // Reciprocal rank fusion: a memory ranked by several sub-questions outranks a single strong hit.
            var scores: [UUID: Double] = [:], found: [UUID: KnowledgeEntry] = [:]
            for query in queries {
                let list = try matchingMemories(query: query, limit: offset + limit, offset: 0, since: since, until: until, timeField: timeField, app: app, includeArchives: includeArchives)
                for (rank, item) in list.enumerated() {
                    scores[item.id, default: 0] += 1 / Double(60 + rank)
                    found[item.id] = item
                    matched[item.id, default: []].append(query)
                }
            }
            let ordered = found.values.sorted {
                let left = scores[$0.id] ?? 0, right = scores[$1.id] ?? 0
                return left == right ? $0.updatedAt > $1.updatedAt : left > right
            }
            entries = Array(ordered.dropFirst(offset).prefix(limit))
        }
        let results = try entries.map { item -> MemorySearchResult in
            let itemQueries = matched[item.id] ?? queries
            var best: [Int: (passage: MemoryPassage, score: (phrase: Int, coverage: Int), query: String)] = [:]
            var fallback: [MemoryPassage] = []
            for (index, query) in itemQueries.enumerated() {
                var ordinals: Set<Int>?
                if timeField == .event {
                    let predicate = Self.eventPassageFilter(query: query, since: since, until: until, app: app)
                    let rows = try database.run("SELECT p.ordinal FROM memory_passages p WHERE p.entry_id=? AND \(predicate.sql)", [item.id.uuidString] + predicate.args)
                    ordinals = Set(rows.compactMap { $0["ordinal"].flatMap(Int.init) })
                }
                let ranked = item.rankedPassages(query: query, ordinals: ordinals)
                if index == 0 { fallback = Array(ranked.prefix(1)).map { $0.excerpt(query: query, limit: 1600) } }
                for passage in ranked {
                    let score = passage.score(query: query)
                    guard score.coverage > 0 || score.phrase > 0 else { continue }
                    if let current = best[passage.ordinal], current.score >= score { continue }
                    best[passage.ordinal] = (passage, score, query)
                }
            }
            let hits = best.values.sorted { $0.score == $1.score ? $0.passage.ordinal < $1.passage.ordinal : $0.score > $1.score }
            let selected = hits.isEmpty ? fallback : hits.prefix(3).map { $0.passage.excerpt(query: $0.query, limit: 1600) }
            return MemorySearchResult(memory: item, matches: selected, matchedQueries: itemQueries)
        }
        let related = expand && queries != [""] ? try relatedMemories(for: results, includeArchives: includeArchives) : []
        return MemorySearchPage(results: results, related: related)
    }

    /// One-hop neighbours of the page. Each seed contributes once per neighbour, scaled by the seed's rank;
    /// a link inside a matching passage counts double. Root files are hubs and never expand.
    func relatedMemories(for results: [MemorySearchResult], includeArchives: Bool, limit: Int = relatedLimit) throws -> [MemoryRelatedResult] {
        let seeds = Set(results.map(\.memory.id))
        var scores: [UUID: Double] = [:], via: [UUID: [MemoryRelatedVia]] = [:]
        for (rank, result) in results.enumerated() where !result.memory.isRootDocument {
            let seed = result.memory, weight = 0.5 / Double(1 + rank)
            let matchedOrdinals = Set(result.matches.map(\.ordinal))
            var contribution: [UUID: Double] = [:]
            func record(_ edge: MemoryRelatedVia, to neighbour: UUID, boost: Double) {
                contribution[neighbour] = max(contribution[neighbour] ?? 0, weight * boost)
                let existing = via[neighbour] ?? []
                guard existing.count < 3, !existing.contains(where: { $0.from == edge.from && $0.direction == edge.direction && $0.label == edge.label && $0.fragment == edge.fragment }) else { return }
                via[neighbour] = existing + [edge]
            }
            for row in try database.run("SELECT * FROM memory_links WHERE source=? AND target_id IS NOT NULL ORDER BY ordinal, rowid", [seed.id.uuidString]) {
                guard let target = row["target_id"].flatMap(UUID.init(uuidString:)), !seeds.contains(target) else { continue }
                let ordinal = row["ordinal"].flatMap(Int.init)
                record(MemoryRelatedVia(from: seed.id, direction: "outgoing", label: row["label"] ?? "", fragment: row["fragment"] ?? "", ordinal: ordinal, passage: Self.passageText(seed.body, ordinal: ordinal)),
                       to: target, boost: ordinal.map(matchedOrdinals.contains) == true ? 2 : 1)
            }
            for row in try database.run("SELECT * FROM memory_links WHERE target_id=? ORDER BY source, ordinal, rowid", [seed.id.uuidString]) {
                guard let source = row["source"].flatMap(UUID.init(uuidString:)), !seeds.contains(source) else { continue }
                record(MemoryRelatedVia(from: seed.id, direction: "backlink", label: row["label"] ?? "", fragment: row["fragment"] ?? "", ordinal: row["ordinal"].flatMap(Int.init), passage: ""), to: source, boost: 1)
            }
            for (neighbour, value) in contribution { scores[neighbour, default: 0] += value }
        }
        var output: [MemoryRelatedResult] = []
        for (id, score) in scores.sorted(by: { $0.value == $1.value ? $0.key.uuidString < $1.key.uuidString : $0.value > $1.value }) {
            guard output.count < limit, let row = try database.run("SELECT * FROM entries WHERE id=?", [id.uuidString]).first else { continue }
            let item = try entry(row)
            // Root files are navigation hubs and archives are history; neither is a useful neighbour.
            if item.isRootDocument || (!includeArchives && item.relativePath.hasPrefix(Self.archivePrefix)) { continue }
            let edges = (via[id] ?? []).map { edge in
                edge.direction == "backlink"
                    ? MemoryRelatedVia(from: edge.from, direction: edge.direction, label: edge.label, fragment: edge.fragment, ordinal: edge.ordinal, passage: Self.passageText(item.body, ordinal: edge.ordinal))
                    : edge
            }
            output.append(MemoryRelatedResult(memory: item, score: score, via: edges))
        }
        return output
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
                          timeField: MemorySearchTimeField = .updated, app: String? = nil, includeArchives: Bool = true) throws -> [KnowledgeEntry] {
        if let since, let until, since >= until { throw LibraryError.invalidResult("since 必须早于 until。") }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sql = "SELECT e.* FROM entries e", filters: [String] = [], args: [String?] = []
        var order = "e.updated_at DESC,e.id"
        if !term.isEmpty {
            // Materialize before joining so FTS5 evaluates BM25 in the MATCH context.
            // Column weights: title 5, body 1, segmented terms 1, anchor text from other memories 3.
            sql = """
                WITH matches AS MATERIALIZED (
                    SELECT id,bm25(entry_search,0,5,1,1,3) AS score FROM entry_search WHERE entry_search MATCH ?
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
        if !includeArchives {
            filters.append("NOT EXISTS (SELECT 1 FROM memory_files f WHERE f.id=e.id AND f.path LIKE ?)")
            args.append(Self.archivePrefix + "%")
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
