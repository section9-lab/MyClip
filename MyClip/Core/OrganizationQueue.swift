import Foundation

public struct OrganizationQueue: Sendable {
    public static let batchSize = 8
    public static let interval: TimeInterval = 180
    public var pendingCounts: [ClipAgent: Int] = [:]
    public var pendingCount: Int { pendingCounts.values.reduce(0, +) }
    public var nextAgent: ClipAgent?
    public var readyAt: Date?
    public var lastStartedAt: Date?
    public var paused = false
    public var pauseReason: String?

    public init() {}
}

extension LibraryStore {
    static func migrateOrganizationQueue(_ database: SQLiteConnection, version: Int) throws {
        try database.transaction {
            try database.script("""
                CREATE TABLE IF NOT EXISTS pending_captures (
                    capture_id TEXT NOT NULL REFERENCES captures(id), agent TEXT NOT NULL, queued_at REAL NOT NULL,
                    PRIMARY KEY(capture_id,agent)
                );
                CREATE INDEX IF NOT EXISTS pending_captures_time ON pending_captures(queued_at);
                CREATE TABLE IF NOT EXISTS organization_queue (
                    id INTEGER PRIMARY KEY CHECK(id=1), last_started_at REAL, paused INTEGER NOT NULL DEFAULT 0, pause_reason TEXT
                );
                INSERT OR IGNORE INTO organization_queue(id) VALUES(1);
                """)
            if version < 6 {
                // Unstarted legacy jobs are only placeholders. Keep running/retried jobs and all history intact.
                try database.script("""
                    INSERT OR IGNORE INTO pending_captures
                        SELECT s.capture_id,j.agent,c.captured_at FROM job_sources s
                        JOIN jobs j ON j.id=s.job_id JOIN captures c ON c.id=s.capture_id
                        WHERE j.state='queued' AND NOT EXISTS (SELECT 1 FROM job_times t WHERE t.id=j.id AND t.started_at IS NOT NULL)
                        ORDER BY c.captured_at,c.rowid;
                    UPDATE organization_queue SET last_started_at=(SELECT max(started_at) FROM job_times) WHERE id=1;
                    DELETE FROM job_times WHERE started_at IS NULL AND id IN (SELECT id FROM jobs WHERE state='queued');
                    DELETE FROM jobs WHERE state='queued' AND id NOT IN (SELECT id FROM job_times);
                    PRAGMA user_version=6;
                    """)
            }
        }
    }

    public func organizationQueue() throws -> OrganizationQueue {
        var result = OrganizationQueue()
        let settings = try database.run("SELECT * FROM organization_queue WHERE id=1").first
        result.paused = settings?["paused"] == "1"
        result.pauseReason = settings?["pause_reason"]
        result.lastStartedAt = settings?["last_started_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        for row in try database.run("""
            SELECT agent,sum(n) n FROM (
                SELECT agent,count(*) n FROM pending_captures GROUP BY agent
                UNION ALL SELECT j.agent,count(*) n FROM jobs j JOIN job_sources s ON s.job_id=j.id WHERE j.state='queued' GROUP BY j.agent
            ) GROUP BY agent
            """) {
            if let agent = row["agent"].flatMap(ClipAgent.init(rawValue:)) { result.pendingCounts[agent] = Int(row["n"] ?? "0") ?? 0 }
        }
        if let first = try queueHead(), let queuedAt = first["queued_at"].flatMap(Double.init) {
            result.nextAgent = first["agent"].flatMap(ClipAgent.init(rawValue:))
            let oldestDeadline = Date(timeIntervalSince1970: queuedAt).addingTimeInterval(OrganizationQueue.interval)
            result.readyAt = max(oldestDeadline, result.lastStartedAt?.addingTimeInterval(OrganizationQueue.interval) ?? .distantPast)
        }
        return result
    }

    public func setOrganizationPaused(_ paused: Bool, reason: String? = nil) throws {
        try database.run("UPDATE organization_queue SET paused=?,pause_reason=? WHERE id=1", [paused ? "1" : "0", paused ? reason : nil])
    }

    public func claimNextJob(at date: Date = Date(), immediately: Bool = false, jobID: UUID? = nil) throws -> ClipJob? {
        try database.transaction {
            guard try database.run("SELECT id FROM jobs WHERE state='running' LIMIT 1").isEmpty else { return nil }
            if !immediately {
                let queue = try organizationQueue()
                guard !queue.paused, let readyAt = queue.readyAt, date >= readyAt else { return nil }
            }
            let id: String
            if let jobID {
                guard try !database.run("SELECT id FROM jobs WHERE id=? AND state='queued'", [jobID.uuidString]).isEmpty else { return nil }
                id = jobID.uuidString
            } else {
                guard let first = try queueHead(), let agent = first["agent"].flatMap(ClipAgent.init(rawValue:)) else { return nil }
                if first["kind"] == "job", let queuedID = first["id"] {
                    id = queuedID
                } else {
                    let sources = try database.run("SELECT capture_id FROM pending_captures WHERE agent=? ORDER BY queued_at,rowid LIMIT ?", [agent.rawValue, String(OrganizationQueue.batchSize)])
                        .compactMap { $0["capture_id"].flatMap(UUID.init(uuidString:)) }
                    guard !sources.isEmpty else { return nil }
                    id = try insertJob(sourceIDs: sources, agent: agent, date: date).uuidString
                    for source in sources { try database.run("DELETE FROM pending_captures WHERE capture_id=? AND agent=?", [source.uuidString, agent.rawValue]) }
                }
            }
            try database.run("UPDATE jobs SET state='running',error=NULL WHERE id=?", [id])
            try database.run("INSERT INTO job_times VALUES(?,?,NULL) ON CONFLICT(id) DO UPDATE SET started_at=excluded.started_at,finished_at=NULL", [id, String(date.timeIntervalSince1970)])
            try database.run("UPDATE organization_queue SET last_started_at=? WHERE id=1", [String(date.timeIntervalSince1970)])
            return try database.run("SELECT * FROM jobs WHERE id=?", [id]).first.map(job)
        }
    }

    private func queueHead() throws -> [String: String]? {
        try database.run("""
            SELECT 'capture' kind,capture_id id,agent,queued_at,rowid position FROM pending_captures
            UNION ALL SELECT 'job',id,agent,created_at,rowid FROM jobs WHERE state='queued'
            ORDER BY queued_at,position LIMIT 1
            """).first
    }

    func hasOrganizedDuplicate(imageID: String, context: CaptureContext, agent: ClipAgent) throws -> Bool {
        try !database.run("""
            SELECT c.id FROM captures c WHERE c.image_id=? AND c.bundle_id=? AND c.window_id=? AND c.window_title=?
            AND c.captured_at>=? AND c.captured_at<=? AND (
                EXISTS (SELECT 1 FROM pending_captures p WHERE p.capture_id=c.id AND p.agent=?)
                OR EXISTS (SELECT 1 FROM job_sources s JOIN jobs j ON j.id=s.job_id WHERE s.capture_id=c.id AND j.agent=? AND j.state!='cancelled')
            ) LIMIT 1
            """, [imageID, context.bundleID, String(context.windowID), context.windowTitle,
                    String(context.date.addingTimeInterval(-60).timeIntervalSince1970), String(context.date.timeIntervalSince1970), agent.rawValue, agent.rawValue]).isEmpty
    }
}
