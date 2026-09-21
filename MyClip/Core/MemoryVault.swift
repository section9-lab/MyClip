import Foundation
import CryptoKit

extension LibraryStore {
    public func moveMemory(_ id: UUID, to path: String, expectedRevision: Int) throws {
        let memory = try readMemory(id)
        guard memory.revision == expectedRevision else { throw LibraryError.conflict }
        guard !memory.isRootDocument else { throw LibraryError.invalidResult("根文件需要保留在 Memory 根目录。") }
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

    public func memoryURL(_ id: UUID) throws -> URL {
        guard let path = try database.run("SELECT path FROM memory_files WHERE id=?", [id.uuidString]).first?["path"] else {
            throw LibraryError.invalidResult("Memory 不存在。")
        }
        return try MemoryLayout.url(path, in: root.appendingPathComponent("Memory"))
    }

    static func memoryHash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    func publishMemoryFiles() throws { try database.transaction { try flushMemoryFiles() } }

    private func flushMemoryFiles() throws {
        for row in try database.run("SELECT e.*,f.path memory_path,f.published_hash FROM entries e JOIN memory_files f ON f.id=e.id WHERE f.pending=1") {
            guard let id = row["id"], let path = row["path"], let memoryPath = row["memory_path"] else { continue }
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
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

    public func synchronizeMemoryFiles() throws {
        try prepareMemoryLayout()
        try database.transaction {
            try flushMemoryFiles()
            try importPlainMarkdownFiles()
            let files = try MemoryLayout.documents(in: root.appendingPathComponent("Memory"))
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
                    let previous = try String(contentsOf: root.appendingPathComponent(row["path"]!), encoding: .utf8)
                    if previous != text || paths[document.id.uuidString] != path {
                        let revision = max(Int(row["revision"] ?? "1") ?? 1, document.revision) + 1
                        _ = try saveEntry(id: document.id, kind: .memory, title: document.title, body: document.body, revision: revision, agent: document.agent, sourceIDs: document.sourceIDs, relativePath: path, extraMetadata: document.extraMetadata,
                            contextSourceIDs: document.contextSourceIDs, observedAt: document.observedAt)
                        if previous != text { try database.run("INSERT OR IGNORE INTO protected_entries VALUES(?)", [document.id.uuidString]) }
                    }
                } else {
                    let history = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Entries/\(document.id.uuidString)").path)) ?? []
                    let lastRevision = history.compactMap { Int(($0 as NSString).deletingPathExtension) }.max() ?? 0
                    _ = try saveEntry(id: document.id, kind: .memory, title: document.title, body: document.body, revision: max(document.revision, lastRevision + 1), agent: document.agent, sourceIDs: document.sourceIDs, relativePath: path, updatedAt: document.updatedAt, extraMetadata: document.extraMetadata,
                        contextSourceIDs: document.contextSourceIDs, observedAt: document.observedAt)
                    try database.run("INSERT OR IGNORE INTO protected_entries VALUES(?)", [document.id.uuidString])
                }
                try database.run("UPDATE memory_files SET path=?,published_hash=? WHERE id=?", [path, Self.memoryHash(text), document.id.uuidString])
            }
            let found = Set(files.map { $0.3.id.uuidString })
            for row in known where !found.contains(row["id"] ?? "") {
                try removeMemoryIndex(row["id"]!)
            }
            if !redirects.isEmpty { try rewriteMemoryLinks(redirects) }
            try flushMemoryFiles()
            // Rebuild derived passage data for older libraries or edits made by an older app.
            for row in try database.run("SELECT e.* FROM entries e WHERE NOT EXISTS (SELECT 1 FROM memory_passages p WHERE p.entry_id=e.id AND p.revision=e.revision)") {
                let item = try entry(row)
                let searchBody = try indexMemoryPassages(id: item.id, title: item.title, body: item.body, revision: item.revision, sourceIDs: item.sourceIDs)
                try database.run("UPDATE entry_search SET body=?,terms=? WHERE id=?", [searchBody, Self.tokens(item.title + " " + searchBody), item.id.uuidString])
            }
        }
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
                let imported = try MemoryDocument("---\nid: \(UUID())\nrevision: 1\nagent: codex\ntitle: \(encodedTitle)\n" + text.dropFirst(4))
                normalized = try MemoryDocument.encode(id: imported.id, title: imported.title, body: imported.body, revision: imported.revision,
                    agent: imported.agent, sourceIDs: imported.sourceIDs, path: path, extraMetadata: imported.extraMetadata,
                    contextSourceIDs: imported.contextSourceIDs, observedAt: imported.observedAt)
            } else {
                normalized = try MemoryDocument.encode(id: previous?.id ?? UUID(), title: title, body: text,
                revision: previous?.revision ?? 1, agent: previous?.agent ?? .codex, sourceIDs: previous?.sourceIDs ?? [],
                path: path, extraMetadata: previous?.extraMetadata ?? "", contextSourceIDs: previous?.contextSourceIDs ?? [], observedAt: previous?.observedAt)
            }
            _ = try MemoryDocument(normalized)
            try normalized.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func removeMemoryIndex(_ id: String) throws {
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

struct MemoryDocument {
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

    init(_ text: String) throws {
        guard text.hasPrefix("---\n"), let boundary = text.range(of: "\n---\n") else { throw LibraryError.invalidResult("请保留 Memory 的 Markdown 元信息。") }
        var fields: [String: String] = [:], sourceList: [String] = [], extras: [String] = []
        var currentKey = ""
        let known = Set(["id", "revision", "title", "kind", "type", "agent", "updated", "updated_at", "sources", "source_ids", "context_source_ids", "observed_at"])
        for line in text[..<boundary.lowerBound].split(separator: "\n").dropFirst() {
            if !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") {
                currentKey = String(line[..<colon])
                fields[currentKey] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if ["sources", "source_ids"].contains(currentKey), line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") { sourceList.append(line.trimmingCharacters(in: .whitespaces).dropFirst(2).description) }
            if !known.contains(currentKey) { extras.append(String(line)) }
        }
        func unquote(_ value: String) -> String { (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        guard let id = fields["id"].flatMap({ UUID(uuidString: unquote($0)) }), let revision = fields["revision"].flatMap(Int.init), revision > 0, revision < 1_000_000,
              let rawTitle = fields["title"], !rawTitle.isEmpty else { throw LibraryError.invalidResult("Memory 元信息不完整。") }
        self.id = id
        self.revision = revision
        let inlineSources = (fields["sources"] ?? fields["source_ids"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map(String.init)
        sourceIDs = try (sourceList.isEmpty ? inlineSources : sourceList).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map {
            guard let id = UUID(uuidString: unquote($0.trimmingCharacters(in: .whitespaces))) else { throw LibraryError.invalidResult("Memory 来源 ID 无效。") }; return id
        }
        contextSourceIDs = try (fields["context_source_ids"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map {
            guard let id = UUID(uuidString: unquote($0.trimmingCharacters(in: .whitespaces))) else { throw LibraryError.invalidResult("Memory 参考截图 ID 无效。") }; return id
        }
        agent = ClipAgent(rawValue: unquote(fields["agent"] ?? "")) ?? .codex
        title = unquote(rawTitle)
        updatedAt = (fields["updated_at"] ?? fields["updated"]).flatMap { ISO8601DateFormatter().date(from: unquote($0)) }
        observedAt = fields["observed_at"].flatMap { ISO8601DateFormatter().date(from: unquote($0)) }
        extraMetadata = extras.isEmpty ? "" : extras.joined(separator: "\n") + "\n"
        body = String(text[boundary.upperBound...])
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 240, body.utf8.count <= 128_000 else { throw LibraryError.invalidResult("Memory 正文为空或过长。") }
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

    static func encode(id: UUID, title: String, body: String, revision: Int, agent: ClipAgent, sourceIDs: [UUID], path: String, updatedAt: Date = Date(), extraMetadata: String = "", contextSourceIDs: [UUID] = [], observedAt: Date? = nil) throws -> String {
        let encodedTitle = String(data: try JSONEncoder().encode(title), encoding: .utf8)!
        let kind: String
        if path == "Memory.md" { kind = "index" }
        else if path == "Profile.md" { kind = "profile" }
        else if path == "Now.md" { kind = "focus" }
        else if path.hasPrefix("Wiki/Projects/") { kind = "project" }
        else if path.hasPrefix("Wiki/Topics/") { kind = "topic" }
        else if path.hasPrefix("Wiki/Workflows/") { kind = "workflow" }
        else if path.hasPrefix("Daily/") { kind = "daily" }
        else if path.hasPrefix("Inbox/") { kind = "inbox" }
        else { kind = "memory" }
        let observation = observedAt.map { "observed_at: \($0.ISO8601Format())\n" } ?? ""
        let context = contextSourceIDs.isEmpty ? "" : "context_source_ids: [\(contextSourceIDs.map(\.uuidString).joined(separator: ", "))]\n"
        return "---\nid: \(id.uuidString)\nkind: memory\ntype: \(kind)\ntitle: \(encodedTitle)\nrevision: \(revision)\nagent: \(agent.rawValue)\nupdated_at: \(updatedAt.ISO8601Format())\n\(observation)source_ids: [\(sourceIDs.map(\.uuidString).joined(separator: ", "))]\n\(context)\(extraMetadata)---\n\(body)"
    }
}
