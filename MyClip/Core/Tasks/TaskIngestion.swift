import Foundation

public struct TaskIngestion: Sendable, Identifiable {
    public static let repairTimeLimit: Duration = .seconds(300)
    public enum State: String, Sendable { case pending, running, completed, failed }
    public let id: UUID
    public let jobID: UUID?
    public let response: String
    public let sourceIDs: Set<UUID>
    public let memoryIDs: Set<UUID>
    public let state: State
    public let attempts: Int
    public let changedCount: Int
    public let rejectedCount: Int
    public let error: String?
}

public struct TaskIngestionSummary: Sendable {
    public var pendingCount = 0
    public var failedCount = 0
    public var lastError: String?
    public var observedThrough: Date?
    public init() {}
}

extension LibraryStore {
    /// Additive metadata is compatible with an installed older app while its historical responses are repaired.
    static func prepareTaskIngestions(_ database: SQLiteConnection) throws {
        try database.script("""
            CREATE TABLE IF NOT EXISTS task_ingestions (
                id TEXT PRIMARY KEY, job_id TEXT UNIQUE REFERENCES jobs(id) ON DELETE CASCADE,
                original_response TEXT NOT NULL, response TEXT NOT NULL, source_ids TEXT NOT NULL, memory_ids TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL,
                error TEXT, changed_count INTEGER NOT NULL DEFAULT 0, rejected_count INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS task_ingestions_queue ON task_ingestions(state,retry_at,created_at);
            """)
    }

    @discardableResult
    public func enqueueTaskIngestion(response: String, sourceIDs: Set<UUID>, memoryIDs: Set<UUID>, jobID: UUID? = nil,
                                     at date: Date = Date()) throws -> UUID {
        let id = jobID ?? UUID()
        try insertTaskIngestion(id: id, jobID: jobID, response: response, sourceIDs: sourceIDs, memoryIDs: memoryIDs, at: date)
        return id
    }

    // Called inside Memory's completion transaction: a crash cannot leave a completed batch without its task stage.
    func insertTaskIngestion(id: UUID, jobID: UUID?, response: String, sourceIDs: Set<UUID>, memoryIDs: Set<UUID>, at date: Date) throws {
        func encode(_ ids: Set<UUID>) throws -> String { String(decoding: try JSONEncoder().encode(ids.map(\.uuidString).sorted()), as: UTF8.self) }
        try database.run("""
            INSERT OR IGNORE INTO task_ingestions(id,job_id,original_response,response,source_ids,memory_ids,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?)
            """, [id.uuidString, jobID?.uuidString, response, response, try encode(sourceIDs), try encode(memoryIDs),
                   String(date.timeIntervalSince1970), String(date.timeIntervalSince1970)])
    }

    public func taskIngestion(_ id: UUID) throws -> TaskIngestion {
        guard let row = try database.run("SELECT * FROM task_ingestions WHERE id=?", [id.uuidString]).first,
              let state = row["state"].flatMap(TaskIngestion.State.init(rawValue:)) else {
            throw LibraryError.invalidResult("任务识别记录不存在。")
        }
        func ids(_ column: String) throws -> Set<UUID> { Set(try JSONDecoder().decode([UUID].self, from: Data((row[column] ?? "[]").utf8))) }
        return TaskIngestion(id: id, jobID: row["job_id"].flatMap(UUID.init(uuidString:)), response: row["response"] ?? "",
            sourceIDs: try ids("source_ids"), memoryIDs: try ids("memory_ids"), state: state, attempts: Int(row["attempts"] ?? "0") ?? 0,
            changedCount: Int(row["changed_count"] ?? "0") ?? 0, rejectedCount: Int(row["rejected_count"] ?? "0") ?? 0, error: row["error"])
    }

    /// Each candidate has its own atomic task/evidence/event write. Invalid provenance is kept for correction,
    /// never silently removed. Replaying an interrupted stage is safe because evidence fingerprints are idempotent.
    @discardableResult
    public func applyTaskIngestion(_ id: UUID, response: String? = nil, at date: Date = Date()) throws -> TaskIngestion {
        let stage = try taskIngestion(id)
        guard stage.state != .completed else { return stage }
        let text = response ?? stage.response
        var rejected: [Data] = [], errors: [String] = [], changed = 0
        let items: [Data]
        do { items = try TaskResponse.items(text) }
        catch {
            try recordTaskIngestionFailure(id, response: text, error: error.localizedDescription, rejectedCount: 1, at: date)
            return try taskIngestion(id)
        }
        for (index, item) in items.enumerated() {
            do {
                let draft: WorkTaskDraft
                do { draft = try JSONDecoder().decode(WorkTaskDraft.self, from: item) }
                catch { throw LibraryError.invalidResult("任务字段格式错误，包括 taskID、状态或来源数组。") }
                changed += try ingestTaskSuggestions([draft], allowedSourceIDs: stage.sourceIDs, allowedMemoryIDs: stage.memoryIDs, at: date)
            } catch let error as LibraryError {
                guard case .invalidResult = error else { throw error }
                rejected.append(item)
                errors.append("候选 \(index + 1)：\(error.localizedDescription)")
            }
        }
        if rejected.isEmpty {
            try database.run("""
                UPDATE task_ingestions SET response=?,state='completed',error=NULL,rejected_count=0,retry_at=NULL,
                    changed_count=changed_count+?,updated_at=? WHERE id=?
                """, [text, String(changed), String(date.timeIntervalSince1970), id.uuidString])
        } else {
            let remainder = "{\"tasks\":[" + rejected.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]}"
            try recordTaskIngestionFailure(id, response: remainder, error: errors.joined(separator: "\n"),
                                          rejectedCount: rejected.count, changedCount: changed, at: date)
        }
        return try taskIngestion(id)
    }

    public func failTaskIngestion(_ id: UUID, error: String, retryable: Bool = true, at date: Date = Date()) throws {
        let stage = try taskIngestion(id)
        guard stage.state != .completed else { return }
        try recordTaskIngestionFailure(id, response: stage.response, error: error, rejectedCount: max(1, stage.rejectedCount), retryable: retryable, at: date)
    }

    private func recordTaskIngestionFailure(_ id: UUID, response: String, error: String, rejectedCount: Int,
                                            changedCount: Int = 0, retryable: Bool = true, at date: Date) throws {
        let attempts = try taskIngestion(id).attempts
        let retry = retryable && RetryPolicy.canRetry(afterAttempt: attempts)
        try database.run("""
            UPDATE task_ingestions SET response=?,state=?,error=?,rejected_count=?,changed_count=changed_count+?,retry_at=?,updated_at=? WHERE id=?
            """, [response, retry ? "pending" : "failed", error, String(rejectedCount), String(changedCount),
                   retry ? String(date.addingTimeInterval(RetryPolicy.delay(afterAttempt: attempts)).timeIntervalSince1970) : nil,
                   String(date.timeIntervalSince1970), id.uuidString])
    }

    public func claimNextTaskIngestion(at date: Date = Date()) throws -> TaskIngestion? {
        try database.transaction {
            guard try database.run("SELECT id FROM task_ingestions WHERE state='running' LIMIT 1").isEmpty,
                  let id = try database.run("""
                    SELECT id FROM task_ingestions WHERE state='pending' AND attempts<? AND (retry_at IS NULL OR retry_at<=?)
                    ORDER BY created_at,id LIMIT 1
                    """, [String(RetryPolicy.maxAttempts), String(date.timeIntervalSince1970)]).first?["id"].flatMap(UUID.init(uuidString:)) else { return nil }
            try database.run("UPDATE task_ingestions SET state='running',attempts=attempts+1,updated_at=? WHERE id=?",
                             [String(date.timeIntervalSince1970), id.uuidString])
            return try taskIngestion(id)
        }
    }

    public func recoverInterruptedTaskIngestions(at date: Date = Date()) throws {
        for row in try database.run("SELECT id FROM task_ingestions WHERE state='running'") {
            if let id = row["id"].flatMap(UUID.init(uuidString:)) {
                try failTaskIngestion(id, error: "上次任务补处理被中断，将继续核对来源。", at: date)
            }
        }
    }

    public func retryFailedTaskIngestions(at date: Date = Date()) throws {
        try database.run("UPDATE task_ingestions SET state='pending',attempts=0,retry_at=NULL,updated_at=? WHERE state='failed'", [String(date.timeIntervalSince1970)])
    }

    /// Older builds recorded the response but not the task outcome. Reconcile against evidence fingerprints first;
    /// unseen candidates go through source/identity correction before import, avoiding renamed legacy duplicates.
    @discardableResult
    public func recoverHistoricalTaskIngestions(at date: Date = Date()) throws -> Int {
        let rows = try database.run("""
            SELECT j.id,e.response,e.finished_at FROM jobs j JOIN execution_records e ON e.job_id=j.id
            WHERE j.state='completed' AND j.kind='batch' AND e.stop_reason='end_turn' AND e.response IS NOT NULL
                AND e.id=(SELECT id FROM execution_records WHERE job_id=j.id AND stop_reason='end_turn' ORDER BY started_at DESC,rowid DESC LIMIT 1)
                AND NOT EXISTS(SELECT 1 FROM task_ingestions t WHERE t.job_id=j.id)
            ORDER BY e.started_at,e.rowid
            """)
        let memories = Set(try database.run("SELECT id FROM entries").compactMap { $0["id"].flatMap(UUID.init(uuidString:)) })
        for row in rows {
            guard let id = row["id"].flatMap(UUID.init(uuidString:)), let response = row["response"] else { continue }
            let sources = Set(try database.run("SELECT capture_id FROM job_sources WHERE job_id=?", [id.uuidString])
                .compactMap { $0["capture_id"].flatMap(UUID.init(uuidString:)) })
            try database.transaction {
                try insertTaskIngestion(id: id, jobID: id, response: response, sourceIDs: sources, memoryIDs: memories, at: date)
                if let drafts = try? TaskResponse.parse(response), (try? taskEvidenceAlreadyRecorded(drafts)) == true {
                    try database.run("UPDATE task_ingestions SET state='completed' WHERE id=?", [id.uuidString])
                } else {
                    try database.run("UPDATE task_ingestions SET error=?,rejected_count=1 WHERE id=?",
                                     ["旧版任务记录待补处理：请核对任务归属、来源编号与发生时间。", id.uuidString])
                }
            }
        }
        return rows.count
    }

    public func taskIngestionMemories(_ stage: TaskIngestion) throws -> [KnowledgeEntry] {
        try synchronizeMemoryFiles()
        // A corrected reply may use a Memory created by the original turn. Freeze the exact catalog shown for
        // this attempt instead of accepting arbitrary IDs the model invents or learns later.
        let memories = try matchingMemories(query: "").sorted {
            let left = !stage.sourceIDs.isDisjoint(with: $0.sourceIDs), right = !stage.sourceIDs.isDisjoint(with: $1.sourceIDs)
            return left == right ? $0.updatedAt > $1.updatedAt : left
        }.prefix(200).map { $0 }
        let ids = String(decoding: try JSONEncoder().encode(memories.map { $0.id.uuidString }.sorted()), as: UTF8.self)
        try database.run("UPDATE task_ingestions SET memory_ids=? WHERE id=?", [ids, stage.id.uuidString])
        return memories
    }

    public func taskIngestionCaptures(_ stage: TaskIngestion) throws -> [ClipCapture] {
        try availableCaptures(ids: stage.sourceIDs.sorted { $0.uuidString < $1.uuidString })
            .filter { FileManager.default.fileExists(atPath: $0.imageURL.path) }.sorted { $0.date < $1.date }
    }

    public func taskIngestionSummary() throws -> TaskIngestionSummary {
        var summary = TaskIngestionSummary()
        for row in try database.run("SELECT state,count(*) n FROM task_ingestions GROUP BY state") {
            let count = Int(row["n"] ?? "0") ?? 0
            if row["state"] == "failed" { summary.failedCount += count }
            else if row["state"] == "pending" || row["state"] == "running" { summary.pendingCount += count }
        }
        summary.lastError = try database.run("SELECT error FROM task_ingestions WHERE state IN ('pending','running','failed') ORDER BY updated_at DESC LIMIT 1").first?["error"]
        summary.observedThrough = try database.run("""
            SELECT max(c.captured_at) time FROM task_ingestions t JOIN job_sources s ON s.job_id=t.job_id
            JOIN captures c ON c.id=s.capture_id WHERE t.state='completed'
            """).first?["time"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return summary
    }
}
