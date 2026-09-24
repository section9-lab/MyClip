import Foundation

extension LibraryStore {
    public func recoverInterruptedJobs(at date: Date = Date()) throws {
        try database.transaction {
            let running = try database.run("SELECT id,attempts,kind FROM jobs WHERE state='running'")
            guard !running.isEmpty else { return }
            for row in running {
                guard let id = row["id"].flatMap(UUID.init(uuidString:)) else { continue }
                let attempts = Int(row["attempts"] ?? "0") ?? 0
                if row["kind"] == ClipJobKind.dream.rawValue {
                    // Files an interrupted dream left behind are settled by the next synchronization; the dream itself
                    // gets one more try, and never holds up the queue.
                    if attempts < MemoryDream.maxAttempts {
                        try requeue(id: id, error: String(localized: "上次做梦被中断，稍后会继续。"), at: date.addingTimeInterval(MemoryDream.retryDelay))
                    } else {
                        try database.run("UPDATE jobs SET state='failed',error=?,retry_at=NULL WHERE id=?", [String(localized: "上次做梦被中断，明天会再做。"), id.uuidString])
                        try database.run("UPDATE job_times SET finished_at=? WHERE id=?", [String(date.timeIntervalSince1970), id.uuidString])
                    }
                } else if RetryPolicy.canRetry(afterAttempt: attempts) {
                    try requeue(id: id, error: String(localized: "上次整理被中断，会自动重新整理。"), at: date.addingTimeInterval(RetryPolicy.delay(afterAttempt: attempts)))
                } else {
                    let reason = String(localized: "上次整理被中断，且已重试 \(attempts) 次；已保留截图和已有 Memory，请手动重试。")
                    try database.run("UPDATE jobs SET state='failed',error=?,retry_at=NULL WHERE id=?", [reason, id.uuidString])
                    try database.run("UPDATE job_times SET finished_at=? WHERE id=?", [String(date.timeIntervalSince1970), id.uuidString])
                    try setOrganizationPaused(true, reason: reason)
                }
            }
        }
    }

    @discardableResult
    public func enqueue(sourceIDs: [UUID], agent: ClipAgent) throws -> UUID {
        guard !sourceIDs.isEmpty, sourceIDs.count <= OrganizationQueue.batchSize else { throw LibraryError.missingSource }
        let inputs = try captures(ids: sourceIDs)
        guard inputs.allSatisfy({ FileManager.default.fileExists(atPath: $0.imageURL.path) }) else { throw LibraryError.missingSource }
        return try database.transaction {
            let id = try insertJob(sourceIDs: sourceIDs, agent: agent, date: Date())
            for source in sourceIDs {
                try database.run("DELETE FROM pending_captures WHERE capture_id=? AND agent=?", [source.uuidString, agent.rawValue])
            }
            return id
        }
    }

    public func finishJob(id: UUID, state: ClipJobState, error: String? = nil) throws {
        guard state == .failed || state == .cancelled else { throw LibraryError.invalidResult(String(localized: "不可直接完成任务")) }
        try database.transaction {
            guard try !database.run("SELECT id FROM jobs WHERE id=? AND state IN ('running','queued')", [id.uuidString]).isEmpty else { return }
            try database.run("UPDATE jobs SET state=?,error=? WHERE id=?", [state.rawValue, error, id.uuidString])
            try database.run("UPDATE job_times SET finished_at=? WHERE id=?", [String(Date().timeIntervalSince1970), id.uuidString])
            if state == .failed { try setOrganizationPaused(true, reason: error ?? String(localized: "整理失败，请手动重试。")) }
        }
    }

    /// A manual retry starts the attempt count over; the user has looked at the failure.
    public func retryJob(id: UUID) throws {
        guard let row = try database.run("SELECT * FROM jobs WHERE id=? AND state IN ('failed','cancelled')", [id.uuidString]).first else { return }
        let inputs = try captures(ids: job(row).sourceIDs)
        guard inputs.allSatisfy({ FileManager.default.fileExists(atPath: $0.imageURL.path) }) else { throw LibraryError.missingSource }
        try database.transaction {
            try database.run("UPDATE jobs SET state='queued',error=NULL,attempts=0,retry_at=NULL WHERE id=?", [id.uuidString])
            try setOrganizationPaused(false)
        }
    }

    /// Puts a running batch back in line after a transient failure without pausing the queue.
    /// The error stays on the job so the history shows why it ran again.
    public func scheduleRetry(id: UUID, error: String, at date: Date) throws {
        try database.transaction {
            guard try !database.run("SELECT id FROM jobs WHERE id=? AND state='running'", [id.uuidString]).isEmpty else { return }
            try requeue(id: id, error: error, at: date)
        }
    }

    private func requeue(id: UUID, error: String, at date: Date) throws {
        try database.run("UPDATE jobs SET state='queued',error=?,retry_at=? WHERE id=?", [error, String(date.timeIntervalSince1970), id.uuidString])
        try database.run("UPDATE job_times SET finished_at=? WHERE id=?", [String(Date().timeIntervalSince1970), id.uuidString])
    }

    @discardableResult
    func insertJob(sourceIDs: [UUID], agent: ClipAgent, date: Date) throws -> UUID {
        let jobID = UUID()
        let id = jobID.uuidString
        try database.run("INSERT INTO jobs(id,agent,state,created_at,error) VALUES(?,?,'queued',?,NULL)", [id, agent.rawValue, String(date.timeIntervalSince1970)])
        for source in sourceIDs {
            try database.run("INSERT INTO job_sources VALUES(?,?)", [id, source.uuidString])
        }
        return jobID
    }

    func job(_ row: [String: String]) throws -> ClipJob {
        guard let id = row["id"].flatMap(UUID.init(uuidString:)), let agent = ClipAgent(rawValue: row["agent"] ?? ""),
              let state = ClipJobState(rawValue: row["state"] ?? "") else { throw LibraryError.database(String(localized: "任务记录格式错误")) }
        let sources = try database.run("SELECT capture_id FROM job_sources WHERE job_id=? ORDER BY rowid", [id.uuidString])
            .compactMap { $0["capture_id"].flatMap(UUID.init(uuidString:)) }
        var result = ClipJob(id: id, agent: agent, state: state,
                       createdAt: Date(timeIntervalSince1970: Double(row["created_at"] ?? "0") ?? 0), sourceIDs: sources, error: row["error"],
                       attempts: Int(row["attempts"] ?? "0") ?? 0,
                       retryAt: row["retry_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
        if row["kind"] == ClipJobKind.dream.rawValue {
            result.kind = .dream
            result.dreamPlan = try database.run("SELECT plan FROM dream_plans WHERE job_id=?", [id.uuidString]).first?["plan"]
                .flatMap { try? JSONDecoder().decode(ConsolidationPlan.self, from: Data($0.utf8)) }
        }
        return result
    }

    public func organizationHandoff() throws -> String? {
        try database.run("SELECT value FROM vault_meta WHERE key='organization_handoff'").first?["value"]
    }
}
