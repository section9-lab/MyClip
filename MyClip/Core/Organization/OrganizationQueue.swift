import Foundation

public struct OrganizationQueue: Sendable {
    public static let batchSize = 8
    public static let textBatchSize = 32
    public static let textCharacterLimit = 12_000
    public static let interval: TimeInterval = 300
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

    public func organizationQueue(at date: Date = Date()) throws -> OrganizationQueue {
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
        if let head = try queueHead(at: date, lastStartedAt: result.lastStartedAt) {
            result.nextAgent = head.agent
            result.readyAt = head.readyAt
        }
        return result
    }

    public func setOrganizationPaused(_ paused: Bool, reason: String? = nil) throws {
        try database.run("UPDATE organization_queue SET paused=?,pause_reason=? WHERE id=1", [paused ? "1" : "0", paused ? reason : nil])
    }

    public func reassignPendingCaptures(to agent: ClipAgent) throws {
        try database.transaction {
            try database.run("""
                INSERT INTO pending_captures(capture_id,agent,queued_at)
                    SELECT capture_id,?,queued_at FROM pending_captures WHERE agent!=? ORDER BY queued_at,rowid
                    ON CONFLICT(capture_id,agent) DO UPDATE SET queued_at=min(pending_captures.queued_at,excluded.queued_at)
                """, [agent.rawValue, agent.rawValue])
            try database.run("DELETE FROM pending_captures WHERE agent!=?", [agent.rawValue])
        }
    }

    public func claimNextJob(at date: Date = Date(), immediately: Bool = false, jobID: UUID? = nil) throws -> ClipJob? {
        try database.transaction {
            guard try database.run("SELECT id FROM jobs WHERE state='running' LIMIT 1").isEmpty else { return nil }
            if !immediately {
                let queue = try organizationQueue(at: date)
                guard !queue.paused, let readyAt = queue.readyAt, date >= readyAt else { return nil }
            }
            let id: String
            if let jobID {
                guard try !database.run("SELECT id FROM jobs WHERE id=? AND state='queued'", [jobID.uuidString]).isEmpty else { return nil }
                id = jobID.uuidString
            } else {
                guard let head = try queueHead(at: date) else { return nil }
                let agent = head.agent
                if case .job(let queuedID) = head.item {
                    id = queuedID
                } else {
                    let candidates = try captures(ids: pendingInputIDs(agent: agent)).map(organizationInput)
                    var inputs: [OrganizationInput] = []
                    var images = 0, texts = 0, characters = 0
                    for input in candidates {
                        if let text = input.text {
                            guard texts < OrganizationQueue.textBatchSize,
                                  characters + text.count <= OrganizationQueue.textCharacterLimit else { break }
                            texts += 1
                            characters += text.count
                        } else {
                            guard images < OrganizationQueue.batchSize else { break }
                            images += 1
                        }
                        inputs.append(input)
                    }
                    let sources = inputs.map { $0.capture.id }
                    guard !sources.isEmpty else { return nil }
                    let jobID = try insertJob(sourceIDs: sources, agent: agent, date: date)
                    try freezeOrganizationInputs(inputs, jobID: jobID)
                    id = jobID.uuidString
                    for source in sources { try database.run("DELETE FROM pending_captures WHERE capture_id=? AND agent=?", [source.uuidString, agent.rawValue]) }
                }
            }
            // The previous attempt's reason stays on the row so a retry can put it in the agent's prompt; completion clears it.
            try database.run("UPDATE jobs SET state='running',retry_at=NULL,attempts=attempts+1 WHERE id=?", [id])
            try database.run("INSERT INTO job_times VALUES(?,?,NULL) ON CONFLICT(id) DO UPDATE SET started_at=excluded.started_at,finished_at=NULL", [id, String(date.timeIntervalSince1970)])
            try database.run("UPDATE organization_queue SET last_started_at=? WHERE id=1", [String(date.timeIntervalSince1970)])
            return try database.run("SELECT * FROM jobs WHERE id=?", [id]).first.map(job)
        }
    }

    public func prepareOrganizationText(at date: Date = Date()) async throws {
        guard let head = try queueHead(at: date), head.item == .captures else { return }
        for capture in try captures(ids: pendingInputIDs(agent: head.agent)) where capture.reason.prefersText {
            try Task.checkCancellation()
            do { _ = try await recognizeImageText(id: capture.imageID) }
            catch is CancellationError { throw CancellationError() }
            catch { continue } // Recognition failures use the original image when the job is claimed.
        }
    }

    private func pendingInputIDs(agent: ClipAgent) throws -> [UUID] {
        try database.run("SELECT capture_id FROM pending_captures WHERE agent=? ORDER BY queued_at,rowid LIMIT ?",
            [agent.rawValue, String(OrganizationQueue.batchSize + OrganizationQueue.textBatchSize)])
            .compactMap { $0["capture_id"].flatMap(UUID.init(uuidString:)) }
    }

    private struct QueueHead {
        enum Item: Equatable { case job(String), captures }
        let item: Item
        let agent: ClipAgent
        let readyAt: Date
    }

    /// The next batch to run and when it may start. A batch that already ran once goes first as soon as its backoff has
    /// passed; until then fresh screenshots and hand-picked batches keep the queue busy in the order they arrived. When
    /// both are due, the unfinished batch wins. Every start also waits out the queue's own interval since the previous start.
    private func queueHead(at date: Date, lastStartedAt: Date? = nil) throws -> QueueHead? {
        let lastStarted = try lastStartedAt
            ?? database.run("SELECT last_started_at FROM organization_queue WHERE id=1").first?["last_started_at"]
                .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let floor = lastStarted?.addingTimeInterval(OrganizationQueue.interval) ?? .distantPast
        var unfinished: QueueHead?
        if let row = try database.run("SELECT id,agent,retry_at FROM jobs WHERE state='queued' AND attempts>0 ORDER BY retry_at,created_at,rowid LIMIT 1").first,
           let id = row["id"], let agent = row["agent"].flatMap(ClipAgent.init(rawValue:)) {
            let retryAt = row["retry_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            unfinished = QueueHead(item: .job(id), agent: agent, readyAt: max(retryAt, floor))
        }
        var fresh: QueueHead?
        // A queued dream goes first: an automatic one is only queued when nothing else waits, a manual one was asked for.
        if let row = try database.run("""
            SELECT 'capture' kind,capture_id id,agent,queued_at,rowid position,0 dream FROM pending_captures
            UNION ALL SELECT 'job',id,agent,created_at,rowid,kind='dream' FROM jobs WHERE state='queued' AND attempts=0
            ORDER BY dream DESC,queued_at,position LIMIT 1
            """).first, let id = row["id"], let agent = row["agent"].flatMap(ClipAgent.init(rawValue:)),
           let queuedAt = row["queued_at"].flatMap(Double.init) {
            let oldestDeadline = row["dream"] == "1" ? Date(timeIntervalSince1970: queuedAt) : Date(timeIntervalSince1970: queuedAt).addingTimeInterval(OrganizationQueue.interval)
            fresh = QueueHead(item: row["kind"] == "job" ? .job(id) : .captures, agent: agent, readyAt: max(oldestDeadline, floor))
        }
        guard let unfinished else { return fresh }
        guard let fresh else { return unfinished }
        return max(fresh.readyAt, date) < max(unfinished.readyAt, date) ? fresh : unfinished
    }

    func hasOrganizedDuplicate(imageID: String, context: CaptureContext, agent: ClipAgent) throws -> Bool {
        try !database.run("""
            SELECT c.id FROM captures c WHERE c.image_id=? AND c.bundle_id=? AND c.window_id=?
            AND c.captured_at>=? AND c.captured_at<=? AND (
                EXISTS (SELECT 1 FROM pending_captures p WHERE p.capture_id=c.id AND p.agent=?)
                OR EXISTS (SELECT 1 FROM job_sources s JOIN jobs j ON j.id=s.job_id WHERE s.capture_id=c.id AND j.agent=? AND j.state!='cancelled')
            ) LIMIT 1
            """, [imageID, context.bundleID, String(context.windowID),
                    String(context.date.addingTimeInterval(-LibraryStore.sceneGap).timeIntervalSince1970), String(context.date.timeIntervalSince1970), agent.rawValue, agent.rawValue]).isEmpty
    }
}
