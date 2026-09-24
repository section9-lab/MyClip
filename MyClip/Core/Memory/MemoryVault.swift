import Foundation
import CryptoKit

extension LibraryStore {
    public func moveMemory(_ id: UUID, to path: String, expectedRevision: Int) throws {
        let memory = try readMemory(id)
        guard memory.revision == expectedRevision else { throw LibraryError.conflict }
        guard !memory.isRootDocument else { throw LibraryError.invalidResult(String(localized: "根文件需要保留在 Memory 根目录。")) }
        let destination = try MemoryLayout.url(path, in: root.appendingPathComponent("Memory"))
        if path == memory.relativePath { return }
        guard !FileManager.default.fileExists(atPath: destination.path),
              try database.run("SELECT id FROM memory_files WHERE path=?", [path]).isEmpty else { throw LibraryError.conflict }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: memory.fileURL, to: destination)
        do { try synchronizeMemoryFiles() }
        catch {
            try? FileManager.default.moveItem(at: destination, to: memory.fileURL)
            throw error
        }
    }

    /// True once anything beyond the three seeded root files (Memory.md/Profile.md/Now.md) exists.
    public func isMemoryEmpty() throws -> Bool {
        try MemoryLayout.markdownFiles(in: root.appendingPathComponent("Memory")).count <= MemoryLayout.rootFiles.count
    }

    public func memoryURL(_ id: UUID) throws -> URL {
        guard let path = try database.run("SELECT path FROM memory_files WHERE id=?", [id.uuidString]).first?["path"] else {
            throw LibraryError.invalidResult(String(localized: "Memory 不存在。"))
        }
        return try MemoryLayout.url(path, in: root.appendingPathComponent("Memory"))
    }

    static func memoryHash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    func publishMemoryFiles() throws { try database.transaction { try flushMemoryFiles() } }

    private func flushMemoryFiles() throws {
        for row in try database.run("SELECT e.*,f.path memory_path,f.published_hash FROM entries e JOIN memory_files f ON f.id=e.id WHERE f.pending=1") {
            guard let id = row["id"], let path = row["path"], let memoryPath = row["memory_path"] else { continue }
            let text = MemoryDocument.published(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), path: memoryPath)
            let url = try MemoryLayout.url(memoryPath, in: root.appendingPathComponent("Memory"))
            let external = try? String(contentsOf: url, encoding: .utf8)
            // A concurrent external edit or deletion wins; synchronization imports it.
            if let external, external != text, Self.memoryHash(external) != row["published_hash"] { continue }
            if external == nil && row["published_hash"] != nil { continue }
            if external != text {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            try database.run("UPDATE memory_files SET published_hash=?,pending=0 WHERE id=?", [Self.memoryHash(text), id])
        }
    }

    /// Files that fail validation are skipped and returned; their last good index stays until the file is repaired.
    @discardableResult
    public func synchronizeMemoryFiles() throws -> [MemoryLayout.InvalidFile] {
        try prepareMemoryLayout()
        var invalid: [MemoryLayout.InvalidFile] = []
        try database.transaction {
            if try !database.run("SELECT value FROM vault_meta WHERE key='search_rebuild'").isEmpty {
                try rebuildMemorySearchTables()
                try database.run("DELETE FROM vault_meta WHERE key='search_rebuild'")
            }
            if try !database.run("SELECT value FROM vault_meta WHERE key='source_repair'").isEmpty {
                try repairCitedSources()
                try database.run("DELETE FROM vault_meta WHERE key='source_repair'")
            }
            try flushMemoryFiles()
            try importPlainMarkdownFiles()
            let scan = try MemoryLayout.scan(in: root.appendingPathComponent("Memory"))
            let files = scan.documents
            invalid = scan.invalid
            let known = try database.run("SELECT * FROM memory_files")
            let paths = Dictionary(uniqueKeysWithValues: known.compactMap { row -> (String, String)? in
                guard let id = row["id"], let path = row["path"] else { return nil }; return (id, path)
            })
            var redirects: [String: String] = [:]
            // Free old paths before assigning new ones, including two files swapping names.
            for (path, _, _, document) in files {
                if let oldPath = paths[document.id.uuidString], oldPath != path {
                    redirects[oldPath.lowercased()] = path
                    redirects[String(oldPath.dropLast(3)).lowercased()] = String(path.dropLast(3))
                    try database.run("INSERT OR REPLACE INTO memory_aliases VALUES(?,?)", [oldPath, document.id.uuidString])
                    try database.run("UPDATE memory_files SET path=? WHERE id=?", [".moving-\(document.id.uuidString)", document.id.uuidString])
                }
            }
            for (path, _, text, document) in files {
                let row = try database.run("SELECT * FROM entries WHERE id=?", [document.id.uuidString]).first
                if let row {
                    let stored = try String(contentsOf: root.appendingPathComponent(row["path"]!), encoding: .utf8)
                    // Published files omit the evidence lists, so both sides are compared as published.
                    let edited = MemoryDocument.published(stored, path: path) != MemoryDocument.published(text, path: path)
                    if edited || paths[document.id.uuidString] != path {
                        let previous = try MemoryDocument(stored)
                        let revision = max(Int(row["revision"] ?? "1") ?? 1, document.revision) + 1
                        _ = try saveEntry(id: document.id, kind: .memory, title: document.title, body: document.body, revision: revision, agent: document.agent,
                            sourceIDs: document.hasSourceField ? document.sourceIDs : previous.sourceIDs, relativePath: path, extraMetadata: document.extraMetadata,
                            contextSourceIDs: document.hasContextField ? document.contextSourceIDs : previous.contextSourceIDs, observedAt: document.observedAt)
                        if edited { try database.run("INSERT OR IGNORE INTO protected_entries VALUES(?)", [document.id.uuidString]) }
                    }
                } else {
                    let directory = root.appendingPathComponent("Entries/\(document.id.uuidString)")
                    let history = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                    let lastRevision = history.compactMap { Int(($0 as NSString).deletingPathExtension) }.max() ?? 0
                    // A rebuilt index recovers the evidence a published file no longer carries from its newest revision;
                    // a vault copied without its history falls back to the citations written in the body.
                    let last = lastRevision > 0 ? try? MemoryDocument(String(contentsOf: directory.appendingPathComponent("\(lastRevision).md"), encoding: .utf8)) : nil
                    let sources = try document.hasSourceField ? document.sourceIDs : last?.sourceIDs ?? MemoryDocument.citedSourceIDs(in: document.body)
                    _ = try saveEntry(id: document.id, kind: .memory, title: document.title, body: document.body, revision: max(document.revision, lastRevision + 1), agent: document.agent,
                        sourceIDs: sources, relativePath: path, updatedAt: document.updatedAt, extraMetadata: document.extraMetadata,
                        contextSourceIDs: document.hasContextField ? document.contextSourceIDs : last?.contextSourceIDs ?? [], observedAt: document.observedAt)
                    try database.run("INSERT OR IGNORE INTO protected_entries VALUES(?)", [document.id.uuidString])
                }
                try database.run("UPDATE memory_files SET path=?,published_hash=? WHERE id=?", [path, Self.memoryHash(text), document.id.uuidString])
            }
            let found = Set(files.map { $0.3.id.uuidString })
            let invalidPaths = Set(invalid.map(\.path))
            for row in known where !found.contains(row["id"] ?? "") && !invalidPaths.contains(row["path"] ?? "") {
                try removeMemoryIndex(row["id"]!)
            }
            if !redirects.isEmpty { try rewriteMemoryLinks(redirects) }
            try flushMemoryFiles()
            // Links written before their target existed resolve once the file appears.
            try resolvePendingLinks()
            // Rebuild derived passage data for older libraries or edits made by an older app.
            for row in try database.run("SELECT e.* FROM entries e WHERE NOT EXISTS (SELECT 1 FROM memory_passages p WHERE p.entry_id=e.id AND p.revision=e.revision)") {
                let item = try entry(row)
                let searchBody = try indexMemoryPassages(id: item.id, title: item.title, body: item.body, revision: item.revision, sourceIDs: item.sourceIDs)
                try database.run("UPDATE entry_search SET body=?,terms=? WHERE id=?", [searchBody, Self.tokens(item.title + " " + searchBody), item.id.uuidString])
            }
        }
        return invalid
    }

    private func importPlainMarkdownFiles() throws {
        for (path, url) in try MemoryLayout.markdownFiles(in: root.appendingPathComponent("Memory")) {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.hasPrefix("---\n"), let boundary = text.range(of: "\n---\n"),
               text[..<boundary.lowerBound].split(separator: "\n").contains(where: { $0.hasPrefix("id:") }) { continue }
            let row = try database.run("SELECT e.path FROM entries e JOIN memory_files f ON f.id=e.id WHERE f.path=?", [path]).first
            let previous = try row?["path"].map { try MemoryDocument(String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) }
            let heading = text.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            let title = heading.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
            let normalized: String
            if text.hasPrefix("---\n") {
                // Ordinary front matter on a new note has no MyClip identity yet.
                // Existing identities must never be silently replaced or repaired.
                guard previous == nil else { continue }
                let encodedTitle = String(decoding: try JSONEncoder().encode(title), as: UTF8.self)
                let imported: MemoryDocument
                do { imported = try MemoryDocument.accepted("---\nid: \(UUID())\nrevision: 1\nagent: codex\ntitle: \(encodedTitle)\n" + text.dropFirst(4)) }
                catch LibraryError.invalidResult { continue }  // reported by the scan instead
                normalized = try MemoryDocument.encode(id: imported.id, title: imported.title, body: imported.body, revision: imported.revision,
                    agent: imported.agent, sourceIDs: imported.sourceIDs, path: path, extraMetadata: imported.extraMetadata,
                    contextSourceIDs: imported.contextSourceIDs, observedAt: imported.observedAt)
            } else {
                normalized = try MemoryDocument.encode(id: previous?.id ?? UUID(), title: title, body: text,
                revision: previous?.revision ?? 1, agent: previous?.agent ?? .codex, sourceIDs: previous?.sourceIDs ?? [],
                path: path, extraMetadata: previous?.extraMetadata ?? "", contextSourceIDs: previous?.contextSourceIDs ?? [], observedAt: previous?.observedAt)
            }
            guard (try? MemoryDocument.accepted(normalized)) != nil else { continue }  // reported by the scan instead
            try normalized.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Re-saves pages whose body cites recorded screenshots missing from their source list; saving merges them in.
    /// The edit time is kept: only the evidence list changes.
    func repairCitedSources() throws {
        for row in try database.run("SELECT * FROM entries") {
            let item = try entry(row)
            let missing = MemoryPassage.explicitSources(in: item.body).filter { !item.sourceIDs.contains($0) }
            guard try missing.contains(where: { try !database.run("SELECT id FROM captures WHERE id=?", [$0.uuidString]).isEmpty }) else { continue }
            _ = try saveEntry(id: item.id, kind: .memory, title: item.title, body: item.body, revision: item.revision + 1, agent: item.agent,
                              sourceIDs: item.sourceIDs, relativePath: item.relativePath, updatedAt: item.updatedAt)
        }
    }

    func removeMemoryIndex(_ id: String) throws {
        // Edges pointing at the removed memory become unresolved again instead of dangling.
        try database.run("UPDATE memory_links SET target_id=NULL WHERE target_id=?", [id])
        try database.run("DELETE FROM memory_passage_search WHERE entry_id=?", [id])
        try database.run("DELETE FROM entry_search WHERE id=?", [id])
        try database.run("DELETE FROM entries WHERE id=?", [id])
    }

    private func rewriteMemoryLinks(_ redirects: [String: String]) throws {
        for row in try database.run("SELECT * FROM entries") {
            let item = try entry(row)
            let body = Wikilink.replacingTargets(in: item.body, with: redirects)
            if body != item.body {
                _ = try saveEntry(id: item.id, kind: .memory, title: item.title, body: body, revision: item.revision + 1, agent: item.agent, sourceIDs: item.sourceIDs)
            }
        }
    }
}

public struct MemoryDocument {
    let id: UUID
    let revision: Int
    let title: String
    let body: String
    let sourceIDs: [UUID]
    let contextSourceIDs: [UUID]
    let agent: ClipAgent
    let updatedAt: Date?
    let observedAt: Date?
    let extraMetadata: String
    /// Search terms the author declared under `aliases:`; kept verbatim in `extraMetadata`.
    let aliases: [String]
    /// False when the file omits the field, as published files do: the stored revision then stays authoritative.
    let hasSourceField: Bool
    let hasContextField: Bool

    static let aliasLimit = 12

    init(_ text: String) throws {
        guard text.hasPrefix("---\n"), let boundary = text.range(of: "\n---\n") else { throw LibraryError.invalidResult(String(localized: "请保留 Memory 的 Markdown 元信息。")) }
        var fields: [String: String] = [:], sourceList: [String] = [], aliasList: [String] = [], extras: [String] = []
        var currentKey = ""
        let known = Set(["id", "revision", "title", "kind", "type", "agent", "updated", "updated_at", "sources", "source_ids", "context_source_ids", "observed_at"])
        for line in text[..<boundary.lowerBound].split(separator: "\n").dropFirst() {
            if !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") {
                currentKey = String(line[..<colon])
                fields[currentKey] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if ["sources", "source_ids"].contains(currentKey), line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") { sourceList.append(line.trimmingCharacters(in: .whitespaces).dropFirst(2).description) }
            if currentKey == "aliases", line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") { aliasList.append(line.trimmingCharacters(in: .whitespaces).dropFirst(2).description) }
            if !known.contains(currentKey) { extras.append(String(line)) }
        }
        func unquote(_ value: String) -> String { (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        guard let id = fields["id"].flatMap({ UUID(uuidString: unquote($0)) }), let revision = fields["revision"].flatMap(Int.init), revision > 0, revision < 1_000_000,
              let rawTitle = fields["title"], !rawTitle.isEmpty else { throw LibraryError.invalidResult(String(localized: "Memory 元信息不完整。")) }
        self.id = id
        self.revision = revision
        let inlineSources = (fields["sources"] ?? fields["source_ids"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map(String.init)
        sourceIDs = try (sourceList.isEmpty ? inlineSources : sourceList).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map {
            guard let id = UUID(uuidString: unquote($0.trimmingCharacters(in: .whitespaces))) else { throw LibraryError.invalidResult(String(localized: "Memory 来源 ID 无效。")) }; return id
        }
        contextSourceIDs = try (fields["context_source_ids"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map {
            guard let id = UUID(uuidString: unquote($0.trimmingCharacters(in: .whitespaces))) else { throw LibraryError.invalidResult(String(localized: "Memory 参考截图 ID 无效。")) }; return id
        }
        agent = ClipAgent(rawValue: unquote(fields["agent"] ?? "")) ?? .codex
        title = unquote(rawTitle)
        updatedAt = (fields["updated_at"] ?? fields["updated"]).flatMap { ISO8601DateFormatter().date(from: unquote($0)) }
        observedAt = fields["observed_at"].flatMap { ISO8601DateFormatter().date(from: unquote($0)) }
        extraMetadata = extras.isEmpty ? "" : extras.joined(separator: "\n") + "\n"
        hasSourceField = fields["sources"] != nil || fields["source_ids"] != nil
        hasContextField = fields["context_source_ids"] != nil
        let inlineAliases = (fields["aliases"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",").map(String.init)
        var seen = Set<String>()
        aliases = (aliasList.isEmpty ? inlineAliases : aliasList).map { unquote($0.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 80 && seen.insert($0.lowercased()).inserted }.prefix(Self.aliasLimit).map { $0 }
        body = String(text[boundary.upperBound...])
        // Parsing accepts any well-formed file, including one over today's size cap, so history and indexes written
        // under an older cap stay readable. The cap is enforced where new content is accepted (`validate`).
        try Self.validate(title: title, body: body, enforcingCap: false)
    }

    /// Hard cap on one file's Markdown body; the organizing prompt quotes it so the agent splits pages before hitting it.
    public static let maxBodyBytes = 128_000

    static func validate(title: String, body: String, enforcingCap: Bool = true) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidResult(String(localized: "Memory 正文为空。")) }
        guard title.count <= 240 else { throw LibraryError.invalidResult(String(localized: "Memory 标题过长。")) }
        guard !enforcingCap || body.utf8.count <= maxBodyBytes else {
            throw LibraryError.invalidResult(String(localized: "Memory 正文 \(body.utf8.count / 1000) KB，超过 \(maxBodyBytes / 1000) KB 上限。"))
        }
    }

    /// Parses a file and applies the size cap: what the vault accepts as a valid Memory file.
    static func accepted(_ text: String) throws -> MemoryDocument {
        let document = try MemoryDocument(text)
        try validate(title: document.title, body: document.body)
        return document
    }

    /// Reader view of a body: citation lines keep their evidence but show 8-character IDs without repeated timestamps.
    /// The file on disk is untouched; full IDs stay there for source resolution and the MCP tools.
    public static func displayMarkdown(_ body: String) -> String {
        let marker = try! NSRegularExpression(pattern: #"(?:来源(?:截图)?|截图来源)\s*[:：]"#)
        let citation = try! NSRegularExpression(pattern: #"`?([0-9A-Fa-f]{8})-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}`?\s*(?:（[^）\n]*）|\([^)\n]*\))?"#)
        var inFence = false
        return body.split(separator: "\n", omittingEmptySubsequences: false).map { slice -> String in
            let line = String(slice)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); return line }
            guard !inFence, marker.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { return line }
            return citation.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "`$1`")
        }.joined(separator: "\n")
    }

    static func citedSourceIDs(in body: String) throws -> [UUID] {
        var content = body
        for pattern in ["(?ms)^ {0,3}(`{3,}|~{3,})[^\\n]*\\n.*?(?:^ {0,3}\\1[ \\t]*(?:\\n|$)|\\z)", #"\[\[[^\]\n]+\]\]"#] {
            let code = try NSRegularExpression(pattern: pattern)
            content = code.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
        }
        let expression = try NSRegularExpression(pattern: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#)
        return Array(Set(expression.matches(in: content, range: NSRange(content.startIndex..., in: content)).compactMap {
            Range($0.range, in: content).flatMap { UUID(uuidString: String(content[$0])) }
        })).sorted { $0.uuidString < $1.uuidString }
    }

    /// The page type follows from the folder, so moving a file retypes it.
    static func kind(for path: String) -> String {
        if path == "Memory.md" { return "index" }
        if path == "Profile.md" { return "profile" }
        if path == "Now.md" { return "focus" }
        let folders: [(String, String)] = [("Wiki/Projects/", "project"), ("Wiki/Topics/", "topic"), ("Wiki/People/", "person"),
            ("Wiki/Reading/", "reading"), ("Wiki/Workflows/", "workflow"), ("Wiki/Archives/", "archive"), ("Daily/", "daily"), ("Inbox/", "inbox")]
        return folders.first { path.hasPrefix($0.0) }?.1 ?? "memory"
    }

    /// Fields kept only in the revision history. The batch context lists every screenshot a run saw and can outgrow the
    /// page itself; cited sources stay published so a copied Memory folder still carries its evidence.
    static let historyOnlyFields: Set<String> = ["context_source_ids"]

    /// What the Memory folder shows for a stored revision: the batch context stays in `Entries/`, where the index and
    /// the source views read it, so the reader and the organizing agent see the page instead of hundreds of IDs.
    static func published(_ text: String, path: String) -> String {
        guard text.hasPrefix("---\n"), let boundary = text.range(of: "\n---\n") else { return text }
        let start = text.index(text.startIndex, offsetBy: 4)
        guard start <= boundary.lowerBound else { return text }
        var lines: [String] = [], skipping = false
        for line in text[start..<boundary.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.hasPrefix(" "), !line.hasPrefix("-"), let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon])
                skipping = historyOnlyFields.contains(key)
                if key == "type" { lines.append("type: \(kind(for: path))"); continue }
            }
            if !skipping { lines.append(String(line)) }
        }
        return "---\n" + lines.joined(separator: "\n") + text[boundary.lowerBound...]
    }

    static func encode(id: UUID, title: String, body: String, revision: Int, agent: ClipAgent, sourceIDs: [UUID], path: String, updatedAt: Date = Date(), extraMetadata: String = "", contextSourceIDs: [UUID] = [], observedAt: Date? = nil) throws -> String {
        let encodedTitle = String(data: try JSONEncoder().encode(title), encoding: .utf8)!
        let kind = Self.kind(for: path)
        let observation = observedAt.map { "observed_at: \($0.ISO8601Format())\n" } ?? ""
        let context = contextSourceIDs.isEmpty ? "" : "context_source_ids: [\(contextSourceIDs.map(\.uuidString).joined(separator: ", "))]\n"
        return "---\nid: \(id.uuidString)\nkind: memory\ntype: \(kind)\ntitle: \(encodedTitle)\nrevision: \(revision)\nagent: \(agent.rawValue)\nupdated_at: \(updatedAt.ISO8601Format())\n\(observation)source_ids: [\(sourceIDs.map(\.uuidString).joined(separator: ", "))]\n\(context)\(extraMetadata)---\n\(body)"
    }
}
