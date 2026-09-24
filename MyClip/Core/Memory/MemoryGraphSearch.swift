import Foundation

/// One hop of the path that brought a graph-reached memory into the results: the fact line that holds the link,
/// the page it is written on, that page's heading, and the edge date when known.
public struct MemoryHop: Sendable {
    public let page: String
    public let section: String
    public let fact: String
    public let date: Date?
}

public struct MemoryHit: Sendable {
    public let memory: KnowledgeEntry
    /// At most two short excerpts: the passages that match the query, or the passage holding the link for a graph-only hit.
    public let passages: [MemoryPassage]
    public let score: Double
    /// Empty for direct matches; one or two hops for memories reached through Wikilinks.
    public let via: [MemoryHop]
    /// Pages linked from the lines the snippet shows (`path` or `path#heading`), since snippets show links by their labels only.
    public let links: [String]
}

/// A link seen from one memory: the page at the other end, the fact line, its heading and date.
public struct MemoryEdgeView: Sendable {
    public let page: String
    public let title: String
    public let section: String
    public let fact: String
    public let date: Date?
}

/// Fixed constants of the Wikilink graph search, chosen on the organized LoCoMo development split (conversations 00–04).
enum GraphConstants {
    /// Lexical results used as graph seeds.
    static let seedCount = 20
    /// Share of the final score that comes from graph activation; the rest is lexical relevance.
    static let graphWeight = 0.4
    /// Transition weight an edge keeps when its fact line does not match the question. Kept small so that on a page
    /// with hundreds of links the few matching lines carry the activation.
    static let edgeFloor = 0.05
    /// Second-hop activation relative to the first.
    static let secondHop = 0.5
    /// Seed mass an endpoint of a matching fact line receives, relative to the best line.
    static let edgeSeed = 0.5
    /// Snippet budget per result: passages, and characters per passage. Larger budgets scored higher only because more
    /// linked lines reached the reader by chance; on the strict evidence metric 2 × 300 matches 3 × 360 with a third less text.
    static let passagesPerHit = 2
    static let excerptLimit = 300
}

extension LibraryStore {
    private enum NodeKind { case entity, episode, hub }

    private struct GraphEdge {
        let rowid: String
        let source: String
        let target: String
        let fact: String
        let section: String
        let ordinal: Int?
        let date: Double?
    }

    private static func kind(of path: String) -> NodeKind {
        if MemoryLayout.rootFiles.contains(path) || path.contains("/Weekly/") || path.hasPrefix(archivePrefix) { return .hub }
        return path.hasPrefix("Daily/") || path.hasPrefix("Inbox/") ? .episode : .entity
    }

    /// Searches memories and follows Wikilinks from the strongest matches.
    ///
    /// Seeds are the lexical results plus both ends of links whose fact line matches the question. Activation then spreads
    /// one hop from every seed and a second hop only through entity pages (episode → entity → episode), with each edge
    /// weighted by how well its fact line matches the question and damped by the degree of the page it enters. The final
    /// score mixes lexical relevance with graph activation.
    public func memorySearch(query: String, limit: Int = 10, since: Date? = nil, until: Date? = nil, app: String? = nil) throws -> [MemoryHit] {
        try synchronizeMemoryFiles()
        let limit = min(max(limit, 1), 50)
        var rows: [[String: String]] = [], term = ""
        let recent = try matchingMemories(query: query, limit: limit, since: since, until: until, timeField: .observed, app: app, includeArchives: false,
                                          candidateSink: { rows = $0; term = $1 })
        guard !term.isEmpty else {
            return try recent.map { memory in
                let passages = Array(memory.rankedPassages(query: "").prefix(1)).map { KnowledgeEntry.displayed($0).excerpt(query: "", limit: GraphConstants.excerptLimit) }
                return MemoryHit(memory: memory, passages: passages, score: 0, via: [], links: try shownLinks(of: memory, passages: passages))
            }
        }
        let lexical = try lexicalCandidates(rows: rows, term: term)
        let allowed = Set(rows.compactMap { $0["id"] })
        // Tier boosts keep exact title and alias matches on top after fusion.
        var lexicalScore: [String: Double] = [:], ranked: [String: RankedMemory] = [:]
        for candidate in lexical {
            let id = candidate.entry.id.uuidString
            let tierBoost: [Double] = [1.0, 0.8, 0.4]
            lexicalScore[id] = candidate.score + (candidate.tier < tierBoost.count ? tierBoost[candidate.tier] : 0)
            ranked[id] = candidate
        }
        let lexicalMax = lexicalScore.values.max() ?? 0
        if lexicalMax > 0 { lexicalScore = lexicalScore.mapValues { $0 / lexicalMax } }

        // The whole resolved link graph; personal libraries hold thousands of edges at most.
        var paths: [String: String] = [:]
        for row in try database.run("SELECT id,path FROM memory_files") { if let id = row["id"], let path = row["path"] { paths[id] = path } }
        var edges: [GraphEdge] = []
        for row in try database.run("SELECT rowid,source,target_id,fact,section,ordinal,date FROM memory_links WHERE target_id IS NOT NULL AND target_id<>source") {
            guard let rowid = row["rowid"], let source = row["source"], let target = row["target_id"],
                  let sourcePath = paths[source], let targetPath = paths[target],
                  Self.kind(of: sourcePath) != .hub, Self.kind(of: targetPath) != .hub else { continue }
            edges.append(GraphEdge(rowid: rowid, source: source, target: target, fact: row["fact"] ?? "", section: row["section"] ?? "",
                                   ordinal: row["ordinal"].flatMap(Int.init), date: row["date"].flatMap(Double.init)))
        }
        var relevance: [String: Double] = [:]
        if !edges.isEmpty {
            for row in try database.run("SELECT rowid,bm25(memory_edge_search,1,0.5,1) AS score FROM memory_edge_search WHERE memory_edge_search MATCH ?", [Self.matchExpression(term)]) {
                if let rowid = row["rowid"], let score = row["score"].flatMap(Double.init) { relevance[rowid] = -score }
            }
            let best = relevance.values.max() ?? 0
            if best > 0 { relevance = relevance.mapValues { $0 / best } }
        }
        var incident: [String: [(edge: GraphEdge, other: String)]] = [:]
        for edge in edges {
            incident[edge.source, default: []].append((edge, edge.target))
            incident[edge.target, default: []].append((edge, edge.source))
        }
        func transitions(from node: String) -> [(edge: GraphEdge, other: String, weight: Double)] {
            let kind = Self.kind(of: paths[node] ?? "")
            let options = (incident[node] ?? []).compactMap { item -> (edge: GraphEdge, other: String, weight: Double)? in
                let otherKind = Self.kind(of: paths[item.other] ?? "")
                let pair: Double = kind == .episode && otherKind == .episode ? 0.3 : kind == .entity && otherKind == .entity ? 0.7 : 1
                let degree = Double(incident[item.other]?.count ?? 1)
                return (item.edge, item.other, pair * (GraphConstants.edgeFloor + (relevance[item.edge.rowid] ?? 0)) / log(2 + degree))
            }
            let total = options.reduce(0) { $0 + $1.weight }
            return total > 0 ? options.map { ($0.edge, $0.other, $0.weight / total) } : []
        }

        // Seeds: top lexical results, plus both ends of matching fact lines.
        var seed: [String: Double] = [:]
        for candidate in lexical.sorted(by: RankedMemory.precedes).prefix(GraphConstants.seedCount) {
            let id = candidate.entry.id.uuidString
            seed[id] = lexicalScore[id] ?? 0
        }
        for edge in edges { if let value = relevance[edge.rowid] {
            for end in [edge.source, edge.target] { seed[end] = max(seed[end] ?? 0, GraphConstants.edgeSeed * value) }
        } }
        // The path shown for a result follows its strongest edge; among equal edges, a fact line written on an entity page wins.
        func pathWeight(_ flow: Double, _ edge: GraphEdge) -> Double { Self.kind(of: paths[edge.source] ?? "") == .entity ? flow * 1.01 : flow }
        var first: [String: Double] = [:], firstVia: [String: (from: String, edge: GraphEdge, mass: Double)] = [:]
        for (node, mass) in seed.sorted(by: { $0.key < $1.key }) where mass > 0 {
            for step in transitions(from: node) {
                let flow = mass * step.weight
                first[step.other, default: 0] += flow
                if pathWeight(flow, step.edge) > firstVia[step.other]?.mass ?? 0 { firstVia[step.other] = (node, step.edge, pathWeight(flow, step.edge)) }
            }
        }
        var second: [String: Double] = [:], secondVia: [String: (from: String, edge: GraphEdge, mass: Double)] = [:]
        for (node, mass) in first.sorted(by: { $0.key < $1.key }) where seed[node] == nil && Self.kind(of: paths[node] ?? "") == .entity {
            for step in transitions(from: node) where step.other != firstVia[node]?.from {
                let flow = mass * step.weight * GraphConstants.secondHop
                second[step.other, default: 0] += flow
                if pathWeight(flow, step.edge) > secondVia[step.other]?.mass ?? 0 { secondVia[step.other] = (node, step.edge, pathWeight(flow, step.edge)) }
            }
        }
        var activation = first.merging(second, uniquingKeysWith: +)
        activation = activation.filter { allowed.contains($0.key) || ranked[$0.key] == nil && Self.kind(of: paths[$0.key] ?? "") != .hub }
        let activationMax = activation.values.max() ?? 0

        // Graph-only pages must still pass the time and app filters.
        let unfiltered = since == nil && until == nil && (app ?? "").isEmpty
        var nodes = Set(lexicalScore.keys)
        for node in activation.keys where ranked[node] == nil && unfiltered { nodes.insert(node) }
        var fused: [RankedMemory] = []
        for node in nodes {
            let graph = activationMax > 0 ? (activation[node] ?? 0) / activationMax : 0
            let score = (1 - GraphConstants.graphWeight) * (lexicalScore[node] ?? 0) + GraphConstants.graphWeight * graph
            if let candidate = ranked[node] {
                fused.append(RankedMemory(entry: candidate.entry, tier: min(candidate.tier, 3), score: score))
            } else if let row = try database.run("SELECT * FROM entries WHERE id=?", [node]).first {
                fused.append(RankedMemory(entry: try entry(row), tier: 3, score: score))
            }
        }
        let ordered = fused.sorted(by: RankedMemory.precedes).prefix(limit)
        let weights = try snippetWeights(term)
        return try ordered.map { item in
            let id = item.entry.id.uuidString
            var via: [MemoryHop] = []
            let graphShare = activationMax > 0 ? GraphConstants.graphWeight * (activation[id] ?? 0) / activationMax : 0
            if graphShare > (1 - GraphConstants.graphWeight) * (lexicalScore[id] ?? 0) {
                if let step = secondVia[id], (second[id] ?? 0) >= (first[id] ?? 0), let previous = firstVia[step.from] {
                    via = [hop(previous.edge, paths: paths), hop(step.edge, paths: paths)]
                } else if let step = firstVia[id] {
                    via = [hop(step.edge, paths: paths)]
                }
            }
            var passages = item.entry.snippets(weights: weights, count: GraphConstants.passagesPerHit, limit: GraphConstants.excerptLimit)
            if passages.isEmpty, let edge = via.isEmpty ? nil : (secondVia[id]?.edge ?? firstVia[id]?.edge), edge.source == id, let ordinal = edge.ordinal {
                passages = MemoryPassage.parse(item.entry.body, sourceIDs: item.entry.sourceIDs).filter { $0.ordinal == ordinal }
                    .map { KnowledgeEntry.displayed($0).excerpt(query: term, limit: GraphConstants.excerptLimit) }
            }
            if passages.isEmpty {
                passages = Array(item.entry.rankedPassages(query: term).prefix(1)).map { KnowledgeEntry.displayed($0).excerpt(query: term, limit: GraphConstants.excerptLimit) }
            }
            return MemoryHit(memory: item.entry, passages: passages, score: (item.score * 1000).rounded() / 1000, via: via,
                             links: try shownLinks(of: item.entry, passages: passages))
        }
    }

    /// Query words weighted by how rare they are among passages (BM25 IDF); words most passages contain weigh nothing.
    func snippetWeights(_ term: String) throws -> [String: Double] {
        let total = Double(try database.run("SELECT count(*) AS n FROM memory_passage_search")[0]["n"].flatMap(Int.init) ?? 0)
        var result: [String: Double] = [:]
        for word in MemoryPassage.queryWords(term) {
            let count = Double(try database.run("SELECT count(*) AS n FROM memory_passage_search WHERE memory_passage_search MATCH ?", [Self.matchExpression(word)])[0]["n"].flatMap(Int.init) ?? 0)
            let weight = log((total - count + 0.5) / (count + 0.5))
            if weight > 0, count > 0 { result[word] = weight }
        }
        return result
    }

    /// Resolved targets of the links on the lines a hit shows, in reading order, at most ten. Links on lines of the same
    /// passage that the snippet leaves out are not listed: the reader has not seen why they matter.
    private func shownLinks(of entry: KnowledgeEntry, passages: [MemoryPassage]) throws -> [String] {
        var links: [String] = []
        for link in passages.flatMap({ entry.shownLines(of: $0) }).flatMap({ Wikilink.parse(String($0)) }) {
            guard let row = try resolveMemoryRow(link.target), let id = row["id"], id != entry.id.uuidString,
                  let path = try database.run("SELECT path FROM memory_files WHERE id=?", [id]).first?["path"] else { continue }
            let target = link.fragment.isEmpty ? path : path + "#" + link.fragment
            if !links.contains(target) { links.append(target) }
            if links.count == 10 { break }
        }
        return links
    }

    private func hop(_ edge: GraphEdge, paths: [String: String]) -> MemoryHop {
        MemoryHop(page: paths[edge.source] ?? "", section: edge.section, fact: edge.fact, date: edge.date.map(Date.init(timeIntervalSince1970:)))
    }

    /// Links from and to one memory with their fact lines. Outgoing links keep document order; backlinks are newest first.
    public func memoryNeighborhood(_ id: UUID, limit: Int = 50) throws -> (links: [MemoryEdgeView], backlinks: [MemoryEdgeView]) {
        try synchronizeMemoryFiles()
        func views(_ sql: String, other: String) throws -> [MemoryEdgeView] {
            try database.run(sql, [id.uuidString, String(limit)]).compactMap { row in
                guard let page = row["path"] else { return nil }
                return MemoryEdgeView(page: page, title: row["title"] ?? "", section: row["section"] ?? "", fact: row["fact"] ?? "",
                                      date: row["date"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
            }
        }
        let links = try views("""
            SELECT f.path, e.title, l.section, l.fact, l.date FROM memory_links l JOIN memory_files f ON f.id=l.target_id JOIN entries e ON e.id=l.target_id
            WHERE l.source=? AND l.target_id<>l.source ORDER BY l.ordinal, l.rowid LIMIT ?
            """, other: "target_id")
        let backlinks = try views("""
            SELECT f.path, e.title, l.section, l.fact, l.date FROM memory_links l JOIN memory_files f ON f.id=l.source JOIN entries e ON e.id=l.source
            WHERE l.target_id=? AND l.target_id<>l.source AND f.path NOT LIKE 'Wiki/Archives/%' ORDER BY l.date IS NULL, l.date DESC, f.path LIMIT ?
            """, other: "source")
        return (links, backlinks)
    }
}

/// Where a memory's evidence came from, aggregated over its cited screenshots.
public struct MemorySourceSummary: Sendable {
    public let count: Int
    public let earliest: Date?
    public let latest: Date?
    /// Application names with the number of cited screenshots from each, most frequent first.
    public let apps: [(name: String, count: Int)]
}

extension LibraryStore {
    public func sourceSummary(_ id: UUID) throws -> MemorySourceSummary {
        let rows = try database.run("""
            SELECT c.app_name AS app, count(*) AS n, min(c.captured_at) AS earliest, max(c.captured_at) AS latest
            FROM entry_sources s JOIN captures c ON c.id=s.capture_id WHERE s.entry_id=? GROUP BY c.app_name ORDER BY n DESC, app
            """, [id.uuidString])
        let apps = rows.compactMap { row in row["app"].flatMap { app in row["n"].flatMap(Int.init).map { (name: app, count: $0) } } }
        return MemorySourceSummary(count: apps.reduce(0) { $0 + $1.count },
                                   earliest: rows.compactMap { $0["earliest"].flatMap(Double.init) }.min().map(Date.init(timeIntervalSince1970:)),
                                   latest: rows.compactMap { $0["latest"].flatMap(Double.init) }.max().map(Date.init(timeIntervalSince1970:)),
                                   apps: apps)
    }

    /// Application names of the given screenshots, in first-seen order.
    public func sourceApps(_ ids: [UUID]) throws -> [String] {
        var names: [String] = []
        for id in ids.prefix(50) {
            if let name = try database.run("SELECT app_name FROM captures WHERE id=?", [id.uuidString]).first?["app_name"], !names.contains(name) { names.append(name) }
        }
        return names
    }
}

extension KnowledgeEntry {
    /// The body under a heading, up to the next heading of the same or a higher level. Nil when no heading matches.
    public func section(_ heading: String) -> String? {
        let wanted = heading.trimmingCharacters(in: .whitespaces).lowercased()
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        func level(_ line: Substring) -> Int? {
            let hashes = line.prefix { $0 == "#" }.count
            return (1...6).contains(hashes) && line.dropFirst(hashes).first == " " ? hashes : nil
        }
        guard let start = lines.firstIndex(where: { line in
            level(line) != nil && line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }), let depth = level(lines[start]) else { return nil }
        let end = lines[(start + 1)...].firstIndex { level($0).map { $0 <= depth } ?? false } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }
}

extension KnowledgeEntry {
    /// What a reader sees of a line: citations dropped (their IDs travel in `sourceIDs`) and links shown as their labels
    /// (their targets travel in `links`). Scoring still reads the original line, so link targets and names keep matching.
    static func displayed(_ line: Substring) -> String {
        var text = String(line)
        text = text.replacingOccurrences(of: #"\s*[（(]?\s*(?:来源|截图来源|sources?|sourceIDs?)\s*[：:]\s*(?:(?:截图)?\s*`[0-9A-Fa-f-]{8,}`\s*(?:[（(][^（()）\n]*[）)])?[、,，;；\s]*)+[）)]?"#,
                                         with: "", options: [.regularExpression, .caseInsensitive])
        // The full stop that closed the citation would now follow the fact's own punctuation.
        text = text.replacingOccurrences(of: #"(?<=[。.！？!?；;])\s*。"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[，,、]\s*。"#, with: "。", options: .regularExpression)
        for link in Wikilink.parse(text).reversed() {
            guard let range = Range(link.range, in: text) else { continue }
            text.replaceSubrange(range, with: link.hasLabel ? link.label : ((link.target as NSString).lastPathComponent))
        }
        return text
    }

    /// The original lines behind a displayed passage, matched by their displayed text. A snippet or excerpt that starts or
    /// ends inside a line still shows that line.
    func shownLines(of shown: MemoryPassage) -> [Substring] {
        guard let passage = MemoryPassage.parse(body, sourceIDs: sourceIDs).first(where: { $0.ordinal == shown.ordinal }) else { return [] }
        let visible = shown.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return passage.text.split(separator: "\n").filter { line in
            let text = Self.displayed(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return false }
            let probe = min(text.count, 24)
            return visible.contains(text) || text.contains(visible) || visible.contains(text.prefix(probe)) || visible.contains(text.suffix(probe))
        }
    }

    static func displayed(_ passage: MemoryPassage) -> MemoryPassage {
        MemoryPassage(ordinal: passage.ordinal, text: passage.text.split(separator: "\n", omittingEmptySubsequences: false).map(displayed).joined(separator: "\n"),
                      startOffset: passage.startOffset, sourceIDs: passage.sourceIDs, eventTime: passage.eventTime)
    }

    /// The lines that best answer a query, grouped by passage. Each line scores the IDF weight of the query words it
    /// contains (matching simple English inflections); passages rank by their best line, and within a long passage the
    /// highest-scoring lines are kept, in document order, up to `limit` characters. Empty when no line matches.
    func snippets(weights: [String: Double], count: Int, limit: Int) -> [MemoryPassage] {
        guard !weights.isEmpty else { return [] }
        // A fixed order keeps floating-point sums, and so ties between lines, identical from run to run.
        let stems = weights.keys.sorted().map { ($0, MemoryPassage.stem($0)) }
        func score(_ line: Substring) -> Double {
            let text = line.lowercased()
            return stems.reduce(0) { total, item in text.contains(item.1) ? total + weights[item.0]! : total }
        }
        let passages = MemoryPassage.parse(body, sourceIDs: sourceIDs).filter { $0.text.range(of: #"^\s*#{1,6}\s"#, options: .regularExpression) == nil }
        let scored = passages.compactMap { passage -> (passage: MemoryPassage, best: Double, lines: [(text: Substring, score: Double, offset: Int)])? in
            var offset = 0, lines: [(text: Substring, score: Double, offset: Int)] = []
            for line in passage.text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append((Substring(Self.displayed(line)), score(line), offset))
                offset += line.count + 1
            }
            let best = lines.map(\.score).max() ?? 0
            return best > 0 ? (passage, best, lines) : nil
        }
        return scored.sorted { $0.best != $1.best ? $0.best > $1.best : $0.passage.ordinal < $1.passage.ordinal }.prefix(count).map { item in
            let display = item.lines.map { String($0.text) }.joined(separator: "\n")
            guard display.count > limit else {
                return MemoryPassage(ordinal: item.passage.ordinal, text: display, startOffset: item.passage.startOffset,
                                     sourceIDs: item.passage.sourceIDs, eventTime: item.passage.eventTime)
            }
            var kept: [(text: Substring, score: Double, offset: Int)] = [], used = 0
            for line in item.lines.filter({ $0.score > 0 }).sorted(by: { $0.score > $1.score }) where kept.isEmpty || used + line.text.count + 1 <= limit {
                kept.append(line)
                used += line.text.count + 1
            }
            kept.sort { $0.offset < $1.offset }
            if kept.count == 1, kept[0].text.count > limit {
                // One long line: keep the window around its first matching word.
                let line = MemoryPassage(ordinal: item.passage.ordinal, text: String(kept[0].text), startOffset: item.passage.startOffset + kept[0].offset,
                                         sourceIDs: item.passage.sourceIDs, eventTime: item.passage.eventTime)
                return line.excerpt(query: weights.keys.sorted().joined(separator: " "), limit: limit)
            }
            return MemoryPassage(ordinal: item.passage.ordinal, text: kept.map { String($0.text) }.joined(separator: "\n"),
                                 startOffset: item.passage.startOffset + (kept.first?.offset ?? 0), sourceIDs: item.passage.sourceIDs, eventTime: item.passage.eventTime)
        }
    }
}
