import Foundation

public struct MemoryEventTime: Sendable {
    public let start: Date
    public let end: Date
    public let precision: String
    public let evidence: String
    public let timeZoneOffset: String

    init?(annotation: String) {
        struct Annotation: Decodable { let start: String; let end: String?; let precision: String; let evidence: String }
        guard let value = try? JSONDecoder().decode(Annotation.self, from: Data(annotation.utf8)),
              ["day", "instant", "range"].contains(value.precision), !value.evidence.isEmpty, value.evidence.count <= 512,
              let start = Self.date(value.start), let end = Self.date(value.end ?? value.start) else { return nil }
        if value.precision == "instant" {
            guard end == start else { return nil }
        } else {
            guard end > start else { return nil }
            if value.precision == "day" {
                guard value.start.contains("T00:00:00"),
                      (82_800...90_000).contains(end.timeIntervalSince(start)) else { return nil }
            }
        }
        self.start = start; self.end = end; precision = value.precision; evidence = value.evidence
        timeZoneOffset = value.start.hasSuffix("Z") ? "+00:00" : String(value.start.suffix(6))
    }

    private static func date(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let offset = value.hasSuffix("Z") ? "+00:00" : String(value.suffix(6))
        let parts = offset.dropFirst().split(separator: ":")
        guard let hours = Int(parts[0]), let minutes = Int(parts[1]), hours <= 23, minutes < 60,
              let zone = TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (offset.first == "-" ? -1 : 1)) else { return nil }
        let formatter = ISO8601DateFormatter()
        var parsed = formatter.date(from: value)
        if parsed == nil { formatter.formatOptions.insert(.withFractionalSeconds); parsed = formatter.date(from: value) }
        guard let date = parsed else { return nil }
        formatter.timeZone = zone
        // Foundation may normalize impossible dates; reject them instead of indexing another day.
        guard formatter.string(from: date).prefix(19) == value.prefix(19) else { return nil }
        return date
    }

}

public struct MemoryPassage: Sendable {
    public let ordinal: Int
    public let text: String
    public let startOffset: Int
    public var endOffset: Int { startOffset + text.count }
    public let sourceIDs: [UUID]
    public let eventTime: MemoryEventTime?

    static func parse(_ body: String, sourceIDs: [UUID]) -> [MemoryPassage] {
        var passages: [MemoryPassage] = []
        var start: String.Index?, end: String.Index?, event: MemoryEventTime?
        var annotationSeen = false
        var fence: String?
        let allowed = Set(sourceIDs)
        func flush() {
            defer { start = nil; end = nil; event = nil; annotationSeen = false }
            guard let start, let end, start < end else { return }
            let text = String(body[start..<end])
            let sources = Self.explicitSources(in: text).filter { allowed.contains($0) }
            let supportedEvent = event.flatMap { !sources.isEmpty && text.contains($0.evidence) ? $0 : nil }
            passages.append(MemoryPassage(ordinal: passages.count, text: text, startOffset: body.distance(from: body.startIndex, to: start), sourceIDs: sources, eventTime: supportedEvent))
        }
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                end = line.endIndex
                if trimmed.hasPrefix(marker), trimmed.allSatisfy({ $0 == marker.first! }) { fence = nil; flush() }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                fence = String(trimmed.prefix { $0 == trimmed.first! })
                start = line.startIndex; end = line.endIndex
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            if line.hasPrefix("<!-- myclip-event "), trimmed.hasSuffix(" -->") {
                let ambiguous = annotationSeen && start == nil
                if start != nil { flush() }
                annotationSeen = true
                event = ambiguous ? nil : MemoryEventTime(annotation: String(trimmed.dropFirst("<!-- myclip-event ".count).dropLast(" -->".count)))
                continue
            }
            if trimmed.hasPrefix("#") { flush() }
            if start == nil { start = line.startIndex }
            end = line.endIndex
            if trimmed.hasPrefix("#") { flush() }
        }
        flush()
        if passages.isEmpty && !body.isEmpty {
            passages = [MemoryPassage(ordinal: 0, text: body, startOffset: 0, sourceIDs: [], eventTime: nil)]
        }
        return passages
    }

    /// Screenshot IDs written after a citation label ("来源：截图 `ID`", "sources: ID"), outside code and links.
    static func explicitSources(in text: String) -> [UUID] {
        var content = text
        for pattern in ["(?ms)^ {0,3}(`{3,}|~{3,})[^\\n]*\\n.*?(?:^ {0,3}\\1[ \\t]*(?:\\n|$)|\\z)", #"\[\[[^\]\n]+\]\]"#] {
            let code = try! NSRegularExpression(pattern: pattern)
            content = code.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
        }
        // Inline code holding a colon is a field or command, not a citation. Spans pair up from the left, so the text between
        // two quoted IDs, such as a time in brackets, is never mistaken for one.
        let spans = try! NSRegularExpression(pattern: #"(`+)[^`\n]*?\1"#)
        for match in spans.matches(in: content, range: NSRange(content.startIndex..., in: content)).reversed() {
            guard let range = Range(match.range, in: content), content[range].contains(where: { $0 == ":" || $0 == "：" }) else { continue }
            content.replaceSubrange(range, with: "")
        }
        let expression = try! NSRegularExpression(pattern: #"(?i)(?:来源(?:截图)?|截图来源|sources?|sourceIDs?)\s*[:：][^\n。；;]*"#)
        let ids = expression.matches(in: content, range: NSRange(content.startIndex..., in: content)).flatMap { match -> [UUID] in
            guard let range = Range(match.range, in: content) else { return [] }
            return (try? MemoryDocument.citedSourceIDs(in: String(content[range]))) ?? []
        }
        return Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }

    /// A word without common English inflections, so "turtles", "walked" and "running" match "turtle", "walk" and "run".
    static func stem(_ word: String) -> String {
        let lower = word.lowercased()
        for suffix in ["ing", "ies", "es", "ed", "s"] where lower.count - suffix.count >= 3 && lower.hasSuffix(suffix) {
            return String(lower.dropLast(suffix.count))
        }
        return lower
    }

    static func queryWords(_ query: String) -> [String] {
        Array(Set(LibraryStore.tokens(query).split(separator: " ").map(String.init))).sorted()
    }

    private func contains(_ term: String) -> Bool {
        !term.isEmpty && text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    func score(query: String) -> (phrase: Int, coverage: Int) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (contains(term) ? 1 : 0, Self.queryWords(term).filter(contains).count)
    }

    func excerpt(query: String, limit: Int) -> MemoryPassage {
        guard text.count > limit else { return self }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = [term] + Self.queryWords(term)
        let positions = words.filter { !$0.isEmpty }.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound }
        var best: MemoryPassage?
        for position in positions.isEmpty ? [text.startIndex] : positions {
            let context = text.index(position, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let start = text[context..<position].lastIndex(where: { $0.isNewline }).map { text.index(after: $0) } ?? context
            let candidate = MemoryPassage(ordinal: ordinal, text: String(text[start...].prefix(limit)), startOffset: startOffset + text.distance(from: text.startIndex, to: start), sourceIDs: sourceIDs, eventTime: eventTime)
            if best == nil || candidate.score(query: query) > best!.score(query: query) { best = candidate }
        }
        return best!
    }
}

extension KnowledgeEntry {
    func rankedPassages(query: String, ordinals: Set<Int>? = nil) -> [MemoryPassage] {
        let passages = MemoryPassage.parse(body, sourceIDs: sourceIDs).filter { ordinals?.contains($0.ordinal) ?? true }
        let paragraphs = passages.filter { $0.text.range(of: #"^\s*#{1,6}\s"#, options: .regularExpression) == nil }
        let scored = (paragraphs.isEmpty ? passages : paragraphs).map { (passage: $0, score: $0.score(query: query)) }
        let sorted = scored.sorted {
            $0.score == $1.score ? $0.passage.ordinal < $1.passage.ordinal : $0.score > $1.score
        }
        return sorted.map { $0.passage }
    }
}

extension LibraryStore {
    func indexMemoryPassages(id: UUID, title: String, body: String, revision: Int, sourceIDs: [UUID]) throws -> String {
        try database.run("DELETE FROM memory_passage_search WHERE entry_id=?", [id.uuidString])
        try database.run("DELETE FROM memory_passages WHERE entry_id=?", [id.uuidString])
        let passages = MemoryPassage.parse(body, sourceIDs: sourceIDs)
        for passage in passages {
            let sourceJSON = String(decoding: try JSONEncoder().encode(passage.sourceIDs.map(\.uuidString)), as: UTF8.self)
            try database.run("INSERT INTO memory_passages VALUES(?,?,?,?,?,?,?,?)", [id.uuidString, String(passage.ordinal), String(revision), sourceJSON,
                passage.eventTime.map { String($0.start.timeIntervalSince1970) }, passage.eventTime.map { String($0.end.timeIntervalSince1970) },
                String(passage.startOffset), String(passage.endOffset)])
            try database.run("INSERT INTO memory_passage_search VALUES(?,?,?,?,?)", [id.uuidString, String(passage.ordinal), title, passage.text, Self.tokens(title + " " + passage.text)])
        }
        return passages.map(\.text).joined(separator: "\n\n")
    }
}
