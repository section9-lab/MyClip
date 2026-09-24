import Foundation

public struct LibraryStatistics: Sendable {
    public var captures = 0
    public var uniqueImages = 0
    public var memories = 0
    public var completed = 0
    public var failed = 0
    public var pending = 0
    public var mcpReads = 0
    public var averageSeconds: Double?
    public var storageBytes: Int64 = 0
    public var days: [Count] = []
    public var applications: [Count] = []
    public struct Count: Identifiable, Sendable {
        public let name: String
        public let count: Int
        public var id: String { name }
    }
    public init() {}
}

extension LibraryStore {
    public func statistics(since: Date = .distantPast) throws -> LibraryStatistics {
        let date = String(since.timeIntervalSince1970)
        func count(_ sql: String, _ args: [String?] = []) throws -> Int {
            Int(try database.run(sql, args).first?["n"] ?? "0") ?? 0
        }
        var result = LibraryStatistics()
        result.captures = try count("SELECT count(*) n FROM captures WHERE captured_at>=?", [date])
        result.uniqueImages = try count("SELECT count(DISTINCT image_id) n FROM captures WHERE captured_at>=?", [date])
        result.memories = try count("SELECT count(*) n FROM entries WHERE updated_at>=?", [date])
        result.completed = try count("SELECT count(*) n FROM jobs WHERE state='completed' AND created_at>=?", [date])
        result.failed = try count("SELECT count(*) n FROM jobs WHERE state='failed' AND created_at>=?", [date])
        result.pending = try count("SELECT count(*) n FROM jobs WHERE state IN ('running','queued')")
        result.mcpReads = try count("SELECT count(*) n FROM mcp_reads WHERE read_at>=?", [date])
        result.averageSeconds = try database.run("SELECT avg(t.finished_at-t.started_at) seconds FROM job_times t JOIN jobs j ON j.id=t.id WHERE j.state='completed' AND j.created_at>=?", [date]).first?["seconds"].flatMap(Double.init)
        result.days = try database.run("SELECT strftime('%Y-%m-%d', captured_at, 'unixepoch', 'localtime') name, count(*) n FROM captures WHERE captured_at>=? GROUP BY name ORDER BY name", [date]).map { .init(name: $0["name"] ?? "", count: Int($0["n"] ?? "0") ?? 0) }
        result.applications = try database.run("SELECT app_name name,count(*) n FROM captures WHERE captured_at>=? GROUP BY app_name ORDER BY n DESC LIMIT 12", [date]).map { .init(name: $0["name"] ?? "", count: Int($0["n"] ?? "0") ?? 0) }
        for item in (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Images"), includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            result.storageBytes += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return result
    }
}

public struct MemoryProposal: Identifiable, Sendable {
    public let id: UUID
    public let drafts: [KnowledgeDraft]
}

extension LibraryStore {
    public func proposals() throws -> [MemoryProposal] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Proposals"), includingPropertiesForKeys: nil).compactMap { url in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return MemoryProposal(id: id, drafts: try JSONDecoder().decode([KnowledgeDraft].self, from: Data(contentsOf: url)))
        }
    }

    public func discardProposal(_ id: UUID) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("Proposals/\(id.uuidString).json"))
        try finishJob(id: id, state: .cancelled, error: String(localized: "已保留原记忆，忽略修改建议"))
    }

    public func acceptProposal(_ id: UUID, revisions: [UUID: Int]) throws {
        guard let proposal = try proposals().first(where: { $0.id == id }) else { throw LibraryError.conflict }
        try synchronizeMemoryFiles()
        // An approval applies only to the exact versions the user reviewed.
        for draft in proposal.drafts {
            if let target = draft.entryID {
                guard try readMemory(target).revision == revisions[target] else { throw LibraryError.conflict }
            }
        }
        var written: [URL] = []
        do {
            try database.transaction {
                for draft in proposal.drafts {
                    let target = draft.entryID ?? UUID()
                    let current = try resolveMemory(target.uuidString)
                    let path = try draftPath(draft, current: current)
                    let sourceIDs = Array(Set((current?.sourceIDs ?? []) + draft.sourceIDs))
                    _ = try captures(ids: draft.sourceIDs)
                    let url = try saveEntry(id: target, kind: .memory, title: draft.title, body: draft.body,
                                            revision: (current?.revision ?? 0) + 1, agent: current?.agent ?? .codex, sourceIDs: sourceIDs, relativePath: path)
                    written.append(url)
                    try database.run("INSERT OR IGNORE INTO protected_entries VALUES(?)", [target.uuidString])
                }
                try database.run("UPDATE jobs SET state='completed',error=NULL WHERE id=?", [id.uuidString])
            }
        } catch { for url in written { try? FileManager.default.removeItem(at: url) }; throw error }
        try publishMemoryFiles()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Proposals/\(id.uuidString).json"))
    }
}
