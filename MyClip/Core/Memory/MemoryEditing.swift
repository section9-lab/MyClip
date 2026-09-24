import Foundation

extension LibraryStore {
    public func beginMemoryEditing(jobID: UUID) throws -> [UUID: Int] {
        guard try database.run("SELECT id FROM jobs WHERE id=? AND state='running'", [jobID.uuidString]).first != nil else {
            throw LibraryError.invalidResult(String(localized: "整理任务未在执行。"))
        }
        return Dictionary(uniqueKeysWithValues: try snapshot().entries.map { ($0.id, $0.revision) })
    }

    /// A file the agent left empty, oversized or with broken metadata goes back to its last good revision,
    /// so one bad write never blocks the vault. The caller decides whether the run is retried with the reason.
    /// New files without history stay on disk unindexed and are named in the handoff lint.
    func restoreRejectedMemoryFiles() throws -> [String] {
        let directory = root.appendingPathComponent("Memory")
        var rejected: [String] = []
        for file in try synchronizeMemoryFiles() {
            guard let history = try database.run("SELECT e.path FROM entries e JOIN memory_files f ON f.id=e.id WHERE f.path=?", [file.path]).first?["path"] else { continue }
            let stored = try String(contentsOf: root.appendingPathComponent(history), encoding: .utf8)
            let text = MemoryDocument.published(stored, path: file.path)
            let url = try MemoryLayout.url(file.path, in: directory)
            // A file the agent did not touch that only fails today's rules (for example a lowered cap) is not a bad
            // write: it stays as it is and the handoff tells the next run to trim it.
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current == text || current == stored { continue }
            try text.write(to: url, atomically: true, encoding: .utf8)
            rejected.append(file.description)
        }
        return rejected
    }

    public func finishMemoryEditing(jobID: UUID, previousRevisions: [UUID: Int]) throws -> Int {
        guard let row = try database.run("SELECT * FROM jobs WHERE id=? AND state='running'", [jobID.uuidString]).first else {
            throw LibraryError.invalidResult(String(localized: "整理任务未在执行。"))
        }
        let task = try job(row)
        let directory = root.appendingPathComponent("Memory")
        for path in MemoryLayout.rootFiles where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) {
            throw LibraryError.invalidResult(String(localized: "Agent 删除了必须保留的根文件：\(path)"))
        }
        let rejected = try restoreRejectedMemoryFiles()
        let entries = try snapshot().entries
        let changed = entries.filter { previousRevisions[$0.id] != $0.revision }
        let deleted = Set(previousRevisions.keys).subtracting(entries.map(\.id)).count
        let batchCaptures = try availableCaptures(ids: task.sourceIDs)
        let batchDate = batchCaptures.map(\.date).max()
        var restored = 0
        var changedPaths: [String] = []
        try database.transaction {
            for entry in changed {
                let previous = try previousRevisions[entry.id].map {
                    try MemoryDocument(String(contentsOf: root.appendingPathComponent("Entries/\(entry.id)/\($0).md"), encoding: .utf8))
                }
                let context = Array(Set((previous?.contextSourceIDs ?? []) + (previous?.sourceIDs ?? []) + task.sourceIDs)).sorted { $0.uuidString < $1.uuidString }
                let allowed = Set(context)
                let sources = try MemoryDocument.citedSourceIDs(in: entry.body).filter {
                    try allowed.contains($0) || !database.run("SELECT id FROM captures WHERE id=?", [$0.uuidString]).isEmpty
                }
                let observed = try availableCaptures(ids: sources).map(\.date).max()
                if entry.relativePath == "Now.md", let previous {
                    let previousDate = try previous.observedAt ?? availableCaptures(ids: previous.sourceIDs).map(\.date).max()
                    if let previousDate, let contentDate = observed ?? batchDate, contentDate < previousDate {
                        _ = try saveEntry(id: entry.id, kind: .memory, title: previous.title, body: previous.body,
                            revision: entry.revision + 1, agent: previous.agent, sourceIDs: previous.sourceIDs, relativePath: entry.relativePath,
                            extraMetadata: previous.extraMetadata, contextSourceIDs: previous.contextSourceIDs, observedAt: previousDate)
                        restored += 1
                        continue
                    }
                }
                _ = try saveEntry(id: entry.id, kind: .memory, title: entry.title, body: entry.body,
                    revision: entry.revision + 1, agent: task.agent, sourceIDs: sources, relativePath: entry.relativePath,
                    contextSourceIDs: context, observedAt: observed)
                changedPaths.append(entry.relativePath)
            }
        }
        try publishMemoryFiles()
        // A rolled-back file re-runs the batch with the reason in the agent's prompt. Once retries are used up the batch
        // still completes: the instruction moves into the handoff for the next run, and the user is never asked to act.
        if !rejected.isEmpty, RetryPolicy.canRetry(afterAttempt: task.attempts) {
            throw LibraryError.rolledBack(rejected.joined(separator: "；"))
        }
        let completedAt = Date()
        let handoff = HandoffPrompt.make(job: task, captures: batchCaptures, changedPaths: changedPaths,
            deletedCount: deleted, completedAt: completedAt, lint: try memoryLint(), rolledBack: rejected)
        try database.transaction {
            try database.run("UPDATE jobs SET state='completed',error=NULL WHERE id=?", [jobID.uuidString])
            try database.run("UPDATE job_times SET finished_at=? WHERE id=?", [String(completedAt.timeIntervalSince1970), jobID.uuidString])
            try database.run("INSERT INTO vault_meta(key,value) VALUES('organization_handoff',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [handoff])
        }
        return changed.count + deleted - restored
    }

    public func commit(jobID: UUID, drafts: [KnowledgeDraft]) throws {
        try synchronizeMemoryFiles()
        guard let row = try database.run("SELECT * FROM jobs WHERE id=?", [jobID.uuidString]).first else {
            throw LibraryError.invalidResult(String(localized: "任务不存在"))
        }
        if row["state"] == "completed" { return }
        guard row["state"] == "running", drafts.count <= 20 else { throw LibraryError.invalidResult(String(localized: "任务状态或条目数量不正确")) }
        let sourceIDs = Set(try job(row).sourceIDs)
        let agent = ClipAgent(rawValue: row["agent"] ?? "") ?? .codex
        var written: [URL] = []
        do {
            try database.transaction {
                for draft in drafts {
                    guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          draft.title.count <= 240, draft.body.utf8.count <= MemoryDocument.maxBodyBytes,
                          !draft.sourceIDs.isEmpty, Set(draft.sourceIDs).isSubset(of: sourceIDs)
                    else { throw LibraryError.invalidResult(String(localized: "标题、正文或来源不正确")) }
                    for link in Wikilink.parse(draft.body) {
                        guard try resolveMemory(link.target) != nil else { throw LibraryError.invalidResult(String(localized: "Wikilink 目标不存在或不唯一：\(link.target)")) }
                    }
                    let id = draft.entryID ?? UUID()
                    let old = try database.run("SELECT * FROM entries WHERE id=?", [id.uuidString]).first
                    let current = try old.map(entry)
                    let path = try draftPath(draft, current: current)
                    let revision = Int(old?["revision"] ?? "0") ?? 0
                    let protected = try !database.run("SELECT id FROM protected_entries WHERE id=?", [id.uuidString]).isEmpty
                    if draft.entryID != nil && (old == nil || draft.expectedRevision != revision || protected) {
                        throw LibraryError.conflict
                    }
                    let sources = Array(Set((current?.sourceIDs ?? []) + draft.sourceIDs)).sorted { $0.uuidString < $1.uuidString }
                    let url = try saveEntry(id: id, kind: draft.kind, title: draft.title, body: draft.body,
                                            revision: revision + 1, agent: agent, sourceIDs: sources, relativePath: path)
                    written.append(url)
                }
                try database.run("UPDATE jobs SET state='completed',error=NULL WHERE id=?", [jobID.uuidString])
                try database.run("UPDATE job_times SET finished_at=? WHERE id=?", [String(Date().timeIntervalSince1970), jobID.uuidString])
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            if case LibraryError.conflict = error {
                try JSONEncoder().encode(drafts).write(to: root.appendingPathComponent("Proposals/\(jobID.uuidString).json"), options: .atomic)
            }
            throw error
        }
        try publishMemoryFiles()
    }

    public func updateEntry(id: UUID, title: String, body: String, expectedRevision: Int) throws {
        try synchronizeMemoryFiles()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidResult(String(localized: "标题和正文不能为空")) }
        try MemoryDocument.validate(title: title, body: body)
        try database.transaction {
            guard let row = try database.run("SELECT * FROM entries WHERE id=?", [id.uuidString]).first else { throw LibraryError.conflict }
            let existing = try entry(row)
            guard existing.revision == expectedRevision else { throw LibraryError.conflict }
            _ = try saveEntry(id: id, kind: existing.kind, title: title, body: body, revision: expectedRevision + 1,
                              agent: existing.agent, sourceIDs: existing.sourceIDs)
            try database.run("INSERT OR IGNORE INTO protected_entries VALUES(?)", [id.uuidString])
        }
        try publishMemoryFiles()
    }

    public func deleteEntry(id: UUID) throws {
        try synchronizeMemoryFiles()
        let memory = try memoryURL(id)
        guard !MemoryLayout.rootFiles.contains(memory.lastPathComponent) || memory.deletingLastPathComponent() != root.appendingPathComponent("Memory") else { throw LibraryError.invalidResult(String(localized: "根文件需要保留，可以编辑其内容。")) }
        try database.transaction {
            try removeMemoryIndex(id.uuidString)
        }
        if FileManager.default.fileExists(atPath: memory.path) { try FileManager.default.removeItem(at: memory) }
        let directory = root.appendingPathComponent("Entries/\(id.uuidString)")
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func entry(_ row: [String: String]) throws -> KnowledgeEntry {
        guard let id = row["id"].flatMap(UUID.init(uuidString:)), KnowledgeKind(rawValue: row["kind"] ?? "") != nil,
              let agent = ClipAgent(rawValue: row["agent"] ?? ""), let path = row["path"] else { throw LibraryError.database(String(localized: "知识记录格式错误")) }
        let url = root.appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        let body = text.range(of: "\n---\n").map { String(text[$0.upperBound...]) } ?? text
        let document = try MemoryDocument(text)
        return KnowledgeEntry(id: id, kind: .memory, title: row["title"] ?? "", body: body,
                              revision: Int(row["revision"] ?? "1") ?? 1,
                              updatedAt: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "0") ?? 0),
                              agent: agent, sourceIDs: document.sourceIDs, fileURL: try memoryURL(id),
                              relativePath: try database.run("SELECT path FROM memory_files WHERE id=?", [id.uuidString]).first?["path"] ?? "",
                              contextSourceIDs: document.contextSourceIDs, observedAt: document.observedAt, aliases: document.aliases)
    }

    func saveEntry(id: UUID, kind: KnowledgeKind, title: String, body: String, revision: Int,
                           agent: ClipAgent, sourceIDs: [UUID], relativePath: String? = nil, updatedAt: Date? = nil,
                           extraMetadata: String? = nil, contextSourceIDs: [UUID]? = nil, observedAt: Date? = nil) throws -> URL {
        let previous = try database.run("SELECT path FROM memory_files WHERE id=?", [id.uuidString]).first?["path"]
        let memoryPath = relativePath ?? previous ?? MemoryLayout.defaultPath(id: id, title: title)
        let memory = try MemoryLayout.url(memoryPath, in: root.appendingPathComponent("Memory"))
        if let owner = try database.run("SELECT id FROM memory_files WHERE path=?", [memoryPath]).first?["id"], owner != id.uuidString { throw LibraryError.conflict }
        if FileManager.default.fileExists(atPath: memory.path), try MemoryDocument(String(contentsOf: memory, encoding: .utf8)).id != id { throw LibraryError.conflict }
        // Citations in the body are evidence even when the page's source list missed them, as on a page an agent created
        // by splitting a Daily note: recorded screenshots cited in the text join the list, so passages keep their sourceIDs.
        var sourceIDs = sourceIDs
        for cited in MemoryPassage.explicitSources(in: body) where !sourceIDs.contains(cited) {
            if try !database.run("SELECT id FROM captures WHERE id=?", [cited.uuidString]).isEmpty { sourceIDs.append(cited) }
        }
        let oldHistory = try database.run("SELECT path FROM entries WHERE id=?", [id.uuidString]).first?["path"]
        let previousDocument = try oldHistory.map { try MemoryDocument(String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) }
        let retainedObservation = previousDocument?.sourceIDs == sourceIDs ? previousDocument?.observedAt : nil
        let observation = try observedAt ?? availableCaptures(ids: sourceIDs).map(\.date).max() ?? retainedObservation
        let date = updatedAt ?? Date()
        let directory = root.appendingPathComponent("Entries/\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = "Entries/\(id.uuidString)/\(revision).md"
        let url = root.appendingPathComponent(path)
        let text = try MemoryDocument.encode(id: id, title: title, body: body, revision: revision, agent: agent, sourceIDs: sourceIDs, path: memoryPath, updatedAt: date,
            extraMetadata: extraMetadata ?? previousDocument?.extraMetadata ?? "", contextSourceIDs: contextSourceIDs ?? previousDocument?.contextSourceIDs ?? [], observedAt: observation)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let aliases = try MemoryDocument(text).aliases
        do {
            try database.run("""
                INSERT INTO entries VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                kind=excluded.kind,title=excluded.title,revision=excluded.revision,updated_at=excluded.updated_at,agent=excluded.agent,path=excluded.path
                """, [id.uuidString, "memory", title, String(revision), String(date.timeIntervalSince1970), agent.rawValue, path])
            try database.run("INSERT INTO memory_files VALUES(?,?,NULL,1) ON CONFLICT(id) DO UPDATE SET path=excluded.path,pending=1", [id.uuidString, memoryPath])
            try database.run("DELETE FROM entry_sources WHERE entry_id=?", [id.uuidString])
            for source in sourceIDs {
                if try !database.run("SELECT id FROM captures WHERE id=?", [source.uuidString]).isEmpty {
                    try database.run("INSERT OR IGNORE INTO entry_sources VALUES(?,?)", [id.uuidString, source.uuidString])
                }
            }
            let searchBody = try indexMemoryPassages(id: id, title: title, body: body, revision: revision, sourceIDs: sourceIDs)
            try database.run("DELETE FROM entry_search WHERE id=?", [id.uuidString])
            try database.run("INSERT INTO entry_search(id,title,body,terms,anchors,aliases) VALUES(?,?,?,?,?,?)", [id.uuidString, title, searchBody, Self.tokens(title + " " + searchBody), try anchorTerms(id.uuidString), Self.aliasSearchText(aliases)])
            try indexLinks(id: id, body: body)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// Each alias on its own line, lowercased, for exact matches; then its word tokens for full-text matches.
}
