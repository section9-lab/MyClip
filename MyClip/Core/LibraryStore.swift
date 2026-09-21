import Foundation
import NaturalLanguage

public actor LibraryStore {
    public nonisolated let root: URL
    let database: SQLiteConnection
    private var textRecognitionTasks: [String: Task<String, Error>] = [:]

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Entries"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Memory"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Proposals"), withIntermediateDirectories: true)
        database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        let version = Int(try database.run("PRAGMA user_version").first?["user_version"] ?? "0") ?? 0
        guard version <= 11 else { throw LibraryError.database("资料库由更新的 MyClip 创建，请升级应用。") }
        if version > 0 && version < 10 {
            // Search tables gain anchor text, stemming and resolved link edges; they are rebuilt from entry files below.
            try database.script("DROP TABLE IF EXISTS entry_search; DROP TABLE IF EXISTS memory_passage_search; DROP TABLE IF EXISTS memory_links;")
        }
        try database.script("""
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS images (
                id TEXT PRIMARY KEY, width INTEGER NOT NULL, height INTEGER NOT NULL, available INTEGER NOT NULL DEFAULT 1,
                block_hash TEXT
            );
            CREATE TABLE IF NOT EXISTS captures (
                id TEXT PRIMARY KEY, image_id TEXT NOT NULL REFERENCES images(id),
                app_name TEXT NOT NULL, bundle_id TEXT NOT NULL, window_title TEXT NOT NULL,
                window_id INTEGER NOT NULL, reason TEXT NOT NULL, captured_at REAL NOT NULL, scene_id TEXT
            );
            CREATE INDEX IF NOT EXISTS captures_time ON captures(captured_at DESC);
            CREATE INDEX IF NOT EXISTS captures_window ON captures(bundle_id, window_id, captured_at DESC);
            CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, agent TEXT NOT NULL, state TEXT NOT NULL, created_at REAL NOT NULL, error TEXT,
                attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL
            );
            CREATE TABLE IF NOT EXISTS job_sources (
                job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
                capture_id TEXT NOT NULL REFERENCES captures(id), PRIMARY KEY(job_id, capture_id)
            );
            CREATE TABLE IF NOT EXISTS job_inputs (
                job_id TEXT NOT NULL, capture_id TEXT NOT NULL, ocr_text TEXT,
                PRIMARY KEY(job_id,capture_id),
                FOREIGN KEY(job_id,capture_id) REFERENCES job_sources(job_id,capture_id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, revision INTEGER NOT NULL,
                updated_at REAL NOT NULL, agent TEXT NOT NULL, path TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS entry_sources (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                capture_id TEXT NOT NULL REFERENCES captures(id), PRIMARY KEY(entry_id, capture_id)
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS entry_search USING fts5(id UNINDEXED, title, body, terms, anchors, tokenize='porter unicode61');
            CREATE TABLE IF NOT EXISTS memory_passages (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL,
                revision INTEGER NOT NULL, source_ids TEXT NOT NULL, event_start REAL, event_end REAL,
                start_offset INTEGER NOT NULL, end_offset INTEGER NOT NULL, PRIMARY KEY(entry_id,ordinal)
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_passage_search USING fts5(entry_id UNINDEXED, ordinal UNINDEXED, title, body, terms, tokenize='porter unicode61');
            CREATE TABLE IF NOT EXISTS image_text (image_id TEXT PRIMARY KEY REFERENCES images(id), body TEXT NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS capture_search USING fts5(image_id UNINDEXED, body, terms);
            CREATE TABLE IF NOT EXISTS memory_links (
                source TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE, target TEXT NOT NULL, target_id TEXT,
                fragment TEXT NOT NULL DEFAULT '', ordinal INTEGER, label TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS memory_links_source ON memory_links(source);
            CREATE INDEX IF NOT EXISTS memory_links_target ON memory_links(target_id);
            CREATE TABLE IF NOT EXISTS protected_entries (id TEXT PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE);
            CREATE TABLE IF NOT EXISTS job_times (id TEXT PRIMARY KEY REFERENCES jobs(id), started_at REAL, finished_at REAL);
            CREATE TABLE IF NOT EXISTS token_usage (
                id TEXT PRIMARY KEY, agent TEXT NOT NULL, job_id TEXT REFERENCES jobs(id) ON DELETE SET NULL,
                recorded_at REAL NOT NULL, total_tokens INTEGER, input_tokens INTEGER, output_tokens INTEGER,
                cached_read_tokens INTEGER, cached_write_tokens INTEGER, thought_tokens INTEGER
            );
            CREATE TABLE IF NOT EXISTS execution_records (
                id TEXT PRIMARY KEY, job_id TEXT REFERENCES jobs(id) ON DELETE CASCADE,
                session_id TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL,
                stop_reason TEXT, error TEXT, response TEXT, cost_amount TEXT, cost_currency TEXT
            );
            CREATE INDEX IF NOT EXISTS execution_records_job ON execution_records(job_id,started_at);
            CREATE TABLE IF NOT EXISTS execution_tools (
                execution_id TEXT NOT NULL REFERENCES execution_records(id) ON DELETE CASCADE,
                tool_id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(execution_id,tool_id)
            );
            CREATE TABLE IF NOT EXISTS mcp_reads (id INTEGER PRIMARY KEY, tool TEXT NOT NULL, read_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS memory_files (id TEXT PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE, path TEXT NOT NULL COLLATE NOCASE UNIQUE, published_hash TEXT, pending INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS memory_aliases (target TEXT PRIMARY KEY COLLATE NOCASE, id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE);
            CREATE TABLE IF NOT EXISTS vault_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS work_tasks (
                id TEXT PRIMARY KEY, identity TEXT NOT NULL UNIQUE, title TEXT NOT NULL, project TEXT NOT NULL,
                status TEXT NOT NULL, suggested_status TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL,
                confirmed_at REAL, completed_at REAL, waiting_reason TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS work_task_evidence (
                id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES work_tasks(id), fingerprint TEXT NOT NULL,
                body TEXT NOT NULL, source_ids TEXT NOT NULL, memory_ids TEXT NOT NULL, created_at REAL NOT NULL,
                UNIQUE(task_id,fingerprint)
            );
            CREATE TABLE IF NOT EXISTS work_task_events (
                id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES work_tasks(id), from_status TEXT,
                to_status TEXT NOT NULL, created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS work_task_events_time ON work_task_events(created_at);
            UPDATE entries SET kind='memory' WHERE kind='wiki';
            """)
        try Self.migrateOrganizationQueue(database, version: version)
        if version < 7 { try Self.migrateWorkTasks(database) }
        if version < 8 { try database.script("PRAGMA user_version=8;") }
        if version < 9 {
            // Databases created before automatic retries lack the columns; fresh ones already have them.
            let columns = Set(try database.run("PRAGMA table_info(jobs)").compactMap { $0["name"] })
            if !columns.contains("attempts") { try database.script("ALTER TABLE jobs ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;") }
            if !columns.contains("retry_at") { try database.script("ALTER TABLE jobs ADD COLUMN retry_at REAL;") }
            try database.script("PRAGMA user_version=9;")
        }
        if version < 10 {
            // Derived search tables are rebuilt on the first synchronization; the marker survives a crash in between.
            if version > 0 { try database.run("INSERT OR REPLACE INTO vault_meta(key,value) VALUES('search_rebuild','1')") }
            try database.script("PRAGMA user_version=10;")
        }
        if version < 11 {
            // Near-duplicate folding: images learn a block hash, captures join scenes. Existing rows are grouped by window and time.
            let imageColumns = Set(try database.run("PRAGMA table_info(images)").compactMap { $0["name"] })
            if !imageColumns.contains("block_hash") { try database.script("ALTER TABLE images ADD COLUMN block_hash TEXT;") }
            let captureColumns = Set(try database.run("PRAGMA table_info(captures)").compactMap { $0["name"] })
            if !captureColumns.contains("scene_id") { try database.script("ALTER TABLE captures ADD COLUMN scene_id TEXT;") }
            try database.transaction { try Self.backfillScenes(database) }
            try database.script("PRAGMA user_version=11;")
        }
        for row in try database.run("SELECT image_id,body FROM image_text JOIN images ON images.id=image_text.image_id WHERE available=1") {
            guard let id = row["image_id"], let text = row["body"] else { continue }
            let url = root.appendingPathComponent("Images/\(id).txt")
            if !FileManager.default.fileExists(atPath: url.path) {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Captures of one window closer together than this continue the previous scene.
    public static let sceneGap: TimeInterval = 300
    /// A scene is cut after this many frames or this much time so an animating window cannot swallow a whole afternoon.
    public static let sceneFrameLimit = 40
    public static let sceneDuration: TimeInterval = 1800

    /// Where a new capture lands: which scene it joins and whether it is a fresh picture or another look at the previous one.
    public struct RecordingDecision: Sendable, Equatable {
        public var sceneID: String
        /// The image the capture is stored against; the previous frame's image when this one adds nothing.
        public var imageID: String
        public var reusedImage: Bool
        public var verdict: BlockComparison.Verdict?
    }

    public func record(image: CapturedImage, context: CaptureContext, agent: ClipAgent, organize: Bool, extractedText: String? = nil) throws {
        let decision = try database.transaction { () -> RecordingDecision in
            let decision = try recordingDecision(for: image, context: context)
            if !decision.reusedImage {
                try database.run("INSERT INTO images(id,width,height,block_hash) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET available=1,block_hash=coalesce(images.block_hash,excluded.block_hash)",
                                 [image.fingerprint, String(image.width), String(image.height), image.blockHash?.hex])
            }
            try database.run("INSERT INTO captures(id,image_id,app_name,bundle_id,window_title,window_id,reason,captured_at,scene_id) VALUES(?,?,?,?,?,?,?,?,?)", [
                context.id.uuidString, decision.imageID, context.appName, context.bundleID,
                context.windowTitle, String(context.windowID), context.reason.rawValue, String(context.date.timeIntervalSince1970), decision.sceneID
            ])
            if let extractedText, !decision.reusedImage {
                try database.run("INSERT INTO image_text VALUES(?,?) ON CONFLICT(image_id) DO UPDATE SET body=excluded.body", [image.fingerprint, extractedText])
                try database.run("DELETE FROM capture_search WHERE image_id=?", [image.fingerprint])
                try database.run("INSERT INTO capture_search VALUES(?,?,?)", [image.fingerprint, extractedText, Self.tokens(extractedText)])
            }
            // Another look at a picture the Agent already has (or will get) is not organized twice.
            if try organize && !(decision.reusedImage && hasOrganizedDuplicate(imageID: decision.imageID, context: context, agent: agent)) {
                try database.run("INSERT INTO pending_captures VALUES(?,?,?)", [context.id.uuidString, agent.rawValue, String(context.date.timeIntervalSince1970)])
            }
            return decision
        }
        guard !decision.reusedImage else { return }
        let imageURL = root.appendingPathComponent("Images/\(image.fingerprint).png")
        if !FileManager.default.fileExists(atPath: imageURL.path) {
            try image.pngData.write(to: imageURL, options: .atomic)
        }
        if let extractedText {
            try extractedText.write(to: imageURL.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Compares against the newest capture of the same window. Manual screenshots always keep their own image.
    func recordingDecision(for image: CapturedImage, context: CaptureContext) throws -> RecordingDecision {
        var decision = RecordingDecision(sceneID: UUID().uuidString, imageID: image.fingerprint, reusedImage: false, verdict: nil)
        guard let previous = try database.run("""
            SELECT c.image_id,c.captured_at,c.scene_id,i.block_hash FROM captures c JOIN images i ON i.id=c.image_id
            WHERE c.bundle_id=? AND c.window_id=? ORDER BY c.captured_at DESC, c.rowid DESC LIMIT 1
            """, [context.bundleID, String(context.windowID)]).first,
              let previousTime = previous["captured_at"].flatMap(Double.init) else { return decision }
        let elapsed = context.date.timeIntervalSince1970 - previousTime
        guard elapsed >= 0, elapsed < Self.sceneGap else { return decision }
        if let scene = previous["scene_id"] {
            let bounds = try database.run("SELECT count(*) n, min(captured_at) started FROM captures WHERE scene_id=?", [scene]).first
            let frames = Int(bounds?["n"] ?? "0") ?? 0
            let started = bounds?["started"].flatMap(Double.init) ?? previousTime
            if frames < Self.sceneFrameLimit, context.date.timeIntervalSince1970 - started < Self.sceneDuration { decision.sceneID = scene }
        }
        guard context.reason != .manual, let previousImage = previous["image_id"] else { return decision }
        if previousImage == image.fingerprint {
            decision.verdict = .identical
        } else if let current = image.blockHash, let stored = previous["block_hash"].flatMap(BlockHash.init(hex:)) {
            decision.verdict = stored.compare(to: current).verdict
        }
        if decision.verdict == .identical || decision.verdict == .sameScene {
            decision.imageID = previousImage
            decision.reusedImage = true
        }
        return decision
    }

    /// Groups pre-v11 captures into scenes by window and time so the Timeline folds history too.
    private static func backfillScenes(_ database: SQLiteConnection) throws {
        var lastByWindow: [String: (scene: String, time: Double, started: Double, frames: Int)] = [:]
        for row in try database.run("SELECT id,bundle_id,window_id,captured_at FROM captures WHERE scene_id IS NULL ORDER BY captured_at, rowid") {
            guard let id = row["id"], let time = row["captured_at"].flatMap(Double.init) else { continue }
            let key = (row["bundle_id"] ?? "") + "#" + (row["window_id"] ?? "")
            var scene = UUID().uuidString
            var started = time, frames = 1
            if let last = lastByWindow[key], time - last.time < sceneGap, last.frames < sceneFrameLimit, time - last.started < sceneDuration {
                scene = last.scene; started = last.started; frames = last.frames + 1
            }
            lastByWindow[key] = (scene, time, started, frames)
            try database.run("UPDATE captures SET scene_id=? WHERE id=?", [scene, id])
        }
    }

    public func nextImageForTextIndex(excluding: Set<String> = []) throws -> (id: String, url: URL)? {
        let placeholders = excluding.map { _ in "?" }.joined(separator: ",")
        let filter = excluding.isEmpty ? "" : " AND id NOT IN (\(placeholders))"
        guard let id = try database.run("SELECT id FROM images WHERE available=1 AND id NOT IN (SELECT image_id FROM image_text)\(filter) ORDER BY rowid LIMIT 1", Array(excluding)).first?["id"] else { return nil }
        return (id, root.appendingPathComponent("Images/\(id).png"))
    }

    public func recognizeImageText(id: String) async throws -> String {
        guard try !database.run("SELECT id FROM images WHERE id=? AND available=1", [id]).isEmpty else { throw LibraryError.missingSource }
        let documentURL = root.appendingPathComponent("Images/\(id).txt")
        if let text = try database.run("SELECT body FROM image_text WHERE image_id=?", [id]).first?["body"] {
            if !FileManager.default.fileExists(atPath: documentURL.path) {
                try text.write(to: documentURL, atomically: true, encoding: .utf8)
            }
            return text
        }
        let task: Task<String, Error>
        if let running = textRecognitionTasks[id] {
            task = running
        } else {
            let imageURL = root.appendingPathComponent("Images/\(id).png")
            task = Task.detached(priority: .utility) {
                let data = try Data(contentsOf: imageURL)
                guard let text = CaptureTextRecognizer.recognize(data) else { throw LibraryError.textRecognitionFailed }
                return text
            }
            textRecognitionTasks[id] = task
        }
        defer { textRecognitionTasks[id] = nil }
        let text = try await task.value
        try Task.checkCancellation()
        guard try !database.run("SELECT id FROM images WHERE id=? AND available=1", [id]).isEmpty else { throw LibraryError.missingSource }
        try indexImageText(id: id, text: text)
        return text
    }

    public func indexImageText(id: String, text: String) throws {
        try database.transaction {
            guard try !database.run("SELECT id FROM images WHERE id=? AND available=1", [id]).isEmpty else { return }
            try database.run("INSERT INTO image_text VALUES(?,?) ON CONFLICT(image_id) DO UPDATE SET body=excluded.body", [id, text])
            try database.run("DELETE FROM capture_search WHERE image_id=?", [id])
            try database.run("INSERT INTO capture_search VALUES(?,?,?)", [id, text, Self.tokens(text)])
            try text.write(to: root.appendingPathComponent("Images/\(id).txt"), atomically: true, encoding: .utf8)
        }
    }

    public func imageNeedsTextIndex(_ id: String) throws -> Bool {
        try database.run("SELECT image_id FROM image_text WHERE image_id=?", [id]).isEmpty
    }

    /// Rebuilds every derived search table from entry files: passages, full text, link edges and anchor text.
    func rebuildMemorySearchTables() throws {
        try database.run("DELETE FROM entry_search")
        try database.run("DELETE FROM memory_passage_search")
        try database.run("DELETE FROM memory_passages")
        try database.run("DELETE FROM memory_links")
        let items = try database.run("SELECT * FROM entries").map(entry)
        for item in items {
            let searchBody = try indexMemoryPassages(id: item.id, title: item.title, body: item.body, revision: item.revision, sourceIDs: item.sourceIDs)
            try database.run("INSERT INTO entry_search(id,title,body,terms,anchors) VALUES(?,?,?,?,'')", [item.id.uuidString, item.title, searchBody, Self.tokens(item.title + " " + searchBody)])
        }
        // Links resolve against the complete entry set, then anchors are attached to their targets.
        for item in items { try indexLinks(id: item.id, body: item.body) }
    }

    public func rebuildSearchIndex() throws {
        try synchronizeMemoryFiles()
        try database.transaction {
            try rebuildMemorySearchTables()
            try database.run("DELETE FROM capture_search")
            for row in try database.run("SELECT * FROM image_text") {
                let body = row["body"] ?? ""
                try database.run("INSERT INTO capture_search VALUES(?,?,?)", [row["image_id"], body, Self.tokens(body)])
            }
        }
    }

    public func snapshot(query: String = "", captureFilter: CaptureFilter = CaptureFilter(), calendar: Calendar = .current) throws -> LibrarySnapshot {
        let invalid = try synchronizeMemoryFiles()
        var result = LibrarySnapshot()
        result.invalidMemoryFiles = invalid.map(\.description)
        result.memoryFolders = try MemoryLayout.folderPaths(in: root.appendingPathComponent("Memory"))
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = Self.tokens(term).split(separator: " ").map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND ")
        let captureMatch = words.isEmpty ? "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\"" : words
        var captureConditions: [String] = []
        var captureArguments: [String?] = []
        if !term.isEmpty {
            captureConditions.append("""
            (instr(lower(c.app_name || ' ' || c.window_title), ?) > 0 OR c.image_id IN (
                SELECT image_id FROM capture_search WHERE capture_search MATCH ?
                UNION SELECT image_id FROM image_text WHERE instr(lower(body),?)>0
            ))
            """)
            captureArguments += [term, captureMatch, term]
        }
        if let appName = captureFilter.appName {
            captureConditions.append("c.app_name=?")
            captureArguments.append(appName)
        }
        if let range = captureFilter.dateRange {
            guard let end = calendar.dateInterval(of: .day, for: range.upperBound)?.end else {
                throw LibraryError.invalidResult("无法解析筛选日期。")
            }
            captureConditions.append("c.captured_at>=? AND c.captured_at<?")
            captureArguments += [String(calendar.startOfDay(for: range.lowerBound).timeIntervalSince1970), String(end.timeIntervalSince1970)]
        }
        let reasons: [CaptureReason]
        switch captureFilter.event {
        case .all: reasons = []
        case .mouse: reasons = [.pointerIdle, .clickIdle, .clickAfterIdle, .scrollIdle]
        case .keyboard: reasons = [.enter]
        }
        if !reasons.isEmpty {
            captureConditions.append("c.reason IN (\(reasons.map { _ in "?" }.joined(separator: ",")))")
            captureArguments += reasons.map(\.rawValue)
        }
        let captureWhere = captureConditions.isEmpty ? "" : "WHERE " + captureConditions.joined(separator: " AND ")
        result.captures = try database.run("""
            SELECT c.*, i.width, i.height FROM captures c JOIN images i ON c.image_id=i.id
            \(captureWhere) ORDER BY c.captured_at DESC, c.rowid DESC LIMIT 500
            """, captureArguments).map(capture)
        result.captureCount = Int(try database.run("SELECT count(*) AS count FROM captures c \(captureWhere)", captureArguments).first?["count"] ?? "0") ?? 0
        result.captureAppNames = try database.run("SELECT DISTINCT app_name FROM captures ORDER BY app_name").compactMap { $0["app_name"] }
        result.entries = try matchingMemories(query: query)
        result.jobs = try database.run("SELECT * FROM jobs ORDER BY created_at DESC, rowid DESC LIMIT 100").map(job)
        result.queue = try organizationQueue()
        result.imageCount = Int(try database.run("SELECT count(*) AS count FROM images WHERE available=1").first?["count"] ?? "0") ?? 0
        return result
    }

    public func beginMemoryEditing(jobID: UUID) throws -> [UUID: Int] {
        guard try database.run("SELECT id FROM jobs WHERE id=? AND state='running'", [jobID.uuidString]).first != nil else {
            throw LibraryError.invalidResult("整理任务未在执行。")
        }
        return Dictionary(uniqueKeysWithValues: try snapshot().entries.map { ($0.id, $0.revision) })
    }

    public func finishMemoryEditing(jobID: UUID, previousRevisions: [UUID: Int]) throws -> Int {
        guard let row = try database.run("SELECT * FROM jobs WHERE id=? AND state='running'", [jobID.uuidString]).first else {
            throw LibraryError.invalidResult("整理任务未在执行。")
        }
        let task = try job(row)
        let directory = root.appendingPathComponent("Memory")
        for path in MemoryLayout.rootFiles where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) {
            throw LibraryError.invalidResult("Agent 删除了必须保留的根文件：\(path)")
        }
        // A file the agent left empty, oversized or with broken metadata goes back to its last good revision,
        // so one bad write never blocks the vault. The batch then runs again with the reason in its prompt.
        // New files without history stay on disk unindexed and are named in the handoff lint.
        var rejected: [String] = []
        for file in try synchronizeMemoryFiles() {
            guard let history = try database.run("SELECT e.path FROM entries e JOIN memory_files f ON f.id=e.id WHERE f.path=?", [file.path]).first?["path"] else { continue }
            let text = try String(contentsOf: root.appendingPathComponent(history), encoding: .utf8)
            try text.write(to: try MemoryLayout.url(file.path, in: directory), atomically: true, encoding: .utf8)
            rejected.append(file.description)
        }
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
        let handoff = OrganizationHandoff.make(job: task, captures: batchCaptures, changedPaths: changedPaths,
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
            throw LibraryError.invalidResult("任务不存在")
        }
        if row["state"] == "completed" { return }
        guard row["state"] == "running", drafts.count <= 20 else { throw LibraryError.invalidResult("任务状态或条目数量不正确") }
        let sourceIDs = Set(try job(row).sourceIDs)
        let agent = ClipAgent(rawValue: row["agent"] ?? "") ?? .codex
        var written: [URL] = []
        do {
            try database.transaction {
                for draft in drafts {
                    guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          draft.title.count <= 240, draft.body.utf8.count <= 128_000,
                          !draft.sourceIDs.isEmpty, Set(draft.sourceIDs).isSubset(of: sourceIDs)
                    else { throw LibraryError.invalidResult("标题、正文或来源不正确") }
                    for link in Wikilink.parse(draft.body) {
                        guard try resolveMemory(link.target) != nil else { throw LibraryError.invalidResult("Wikilink 目标不存在或不唯一：\(link.target)") }
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

    public func recoverInterruptedJobs(at date: Date = Date()) throws {
        try database.transaction {
            let running = try database.run("SELECT id,attempts FROM jobs WHERE state='running'")
            guard !running.isEmpty else { return }
            for row in running {
                guard let id = row["id"].flatMap(UUID.init(uuidString:)) else { continue }
                let attempts = Int(row["attempts"] ?? "0") ?? 0
                if RetryPolicy.canRetry(afterAttempt: attempts) {
                    try requeue(id: id, error: "上次整理被中断，会自动重新整理。", at: date.addingTimeInterval(RetryPolicy.delay(afterAttempt: attempts)))
                } else {
                    let reason = "上次整理被中断，且已重试 \(attempts) 次；已保留截图和已有 Memory，请手动重试。"
                    try database.run("UPDATE jobs SET state='failed',error=?,retry_at=NULL WHERE id=?", [reason, id.uuidString])
                    try database.run("UPDATE job_times SET finished_at=? WHERE id=?", [String(date.timeIntervalSince1970), id.uuidString])
                    try setOrganizationPaused(true, reason: reason)
                }
            }
        }
    }

    public func expireImages(before date: Date) throws {
        let rows = try database.run("""
            SELECT i.id FROM images i JOIN captures c ON c.image_id=i.id WHERE i.available=1
            GROUP BY i.id HAVING max(c.captured_at) < CAST(? AS REAL) AND i.id NOT IN (
                SELECT c.image_id FROM captures c JOIN job_sources s ON s.capture_id=c.id
                JOIN jobs j ON j.id=s.job_id WHERE j.state IN ('queued','running','failed')
                UNION SELECT c.image_id FROM captures c JOIN pending_captures p ON p.capture_id=c.id
            )
            """, [String(date.timeIntervalSince1970)])
        for row in rows {
            guard let id = row["id"] else { continue }
            let url = root.appendingPathComponent("Images/\(id).png")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let documentURL = url.deletingPathExtension().appendingPathExtension("txt")
            if FileManager.default.fileExists(atPath: documentURL.path) { try FileManager.default.removeItem(at: documentURL) }
            try database.transaction {
                try database.run("UPDATE images SET available=0 WHERE id=?", [id])
                try database.run("DELETE FROM image_text WHERE image_id=?", [id])
                try database.run("DELETE FROM capture_search WHERE image_id=?", [id])
            }
        }
    }

    public func updateEntry(id: UUID, title: String, body: String, expectedRevision: Int) throws {
        try synchronizeMemoryFiles()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidResult("标题和正文不能为空") }
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
        guard !MemoryLayout.rootFiles.contains(memory.lastPathComponent) || memory.deletingLastPathComponent() != root.appendingPathComponent("Memory") else { throw LibraryError.invalidResult("根文件需要保留，可以编辑其内容。") }
        try database.transaction {
            try removeMemoryIndex(id.uuidString)
        }
        if FileManager.default.fileExists(atPath: memory.path) { try FileManager.default.removeItem(at: memory) }
        let directory = root.appendingPathComponent("Entries/\(id.uuidString)")
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    public func captures(ids: [UUID]) throws -> [ClipCapture] {
        try ids.map { id in
            guard let row = try database.run("SELECT c.*,i.width,i.height FROM captures c JOIN images i ON i.id=c.image_id WHERE c.id=?", [id.uuidString]).first else {
                throw LibraryError.missingSource
            }
            return try capture(row)
        }
    }

    public func availableCaptures(ids: [UUID]) throws -> [ClipCapture] {
        var result: [ClipCapture] = []
        for id in ids {
            do { result += try captures(ids: [id]) }
            catch LibraryError.missingSource { continue }
        }
        return result
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
        guard state == .failed || state == .cancelled else { throw LibraryError.invalidResult("不可直接完成任务") }
        try database.transaction {
            guard try !database.run("SELECT id FROM jobs WHERE id=? AND state IN ('running','queued')", [id.uuidString]).isEmpty else { return }
            try database.run("UPDATE jobs SET state=?,error=? WHERE id=?", [state.rawValue, error, id.uuidString])
            try database.run("UPDATE job_times SET finished_at=? WHERE id=?", [String(Date().timeIntervalSince1970), id.uuidString])
            if state == .failed { try setOrganizationPaused(true, reason: error ?? "整理失败，请手动重试。") }
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

    private func capture(_ row: [String: String]) throws -> ClipCapture {
        guard let id = row["id"].flatMap(UUID.init(uuidString:)), let imageID = row["image_id"],
              let reason = CaptureReason(rawValue: row["reason"] ?? "") else { throw LibraryError.database("截图记录格式错误") }
        return ClipCapture(id: id, appName: row["app_name"] ?? "", bundleID: row["bundle_id"] ?? "",
                           windowTitle: row["window_title"] ?? "", windowID: UInt32(row["window_id"] ?? "0") ?? 0,
                           reason: reason, date: Date(timeIntervalSince1970: Double(row["captured_at"] ?? "0") ?? 0),
                           imageID: imageID, imageURL: root.appendingPathComponent("Images/\(imageID).png"),
                           width: Int(row["width"] ?? "0") ?? 0, height: Int(row["height"] ?? "0") ?? 0, sceneID: row["scene_id"])
    }

    func job(_ row: [String: String]) throws -> ClipJob {
        guard let id = row["id"].flatMap(UUID.init(uuidString:)), let agent = ClipAgent(rawValue: row["agent"] ?? ""),
              let state = ClipJobState(rawValue: row["state"] ?? "") else { throw LibraryError.database("任务记录格式错误") }
        let sources = try database.run("SELECT capture_id FROM job_sources WHERE job_id=? ORDER BY rowid", [id.uuidString])
            .compactMap { $0["capture_id"].flatMap(UUID.init(uuidString:)) }
        return ClipJob(id: id, agent: agent, state: state,
                       createdAt: Date(timeIntervalSince1970: Double(row["created_at"] ?? "0") ?? 0), sourceIDs: sources, error: row["error"],
                       attempts: Int(row["attempts"] ?? "0") ?? 0,
                       retryAt: row["retry_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
    }

    func entry(_ row: [String: String]) throws -> KnowledgeEntry {
        guard let id = row["id"].flatMap(UUID.init(uuidString:)), KnowledgeKind(rawValue: row["kind"] ?? "") != nil,
              let agent = ClipAgent(rawValue: row["agent"] ?? ""), let path = row["path"] else { throw LibraryError.database("知识记录格式错误") }
        let url = root.appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        let body = text.range(of: "\n---\n").map { String(text[$0.upperBound...]) } ?? text
        let document = try MemoryDocument(text)
        return KnowledgeEntry(id: id, kind: .memory, title: row["title"] ?? "", body: body,
                              revision: Int(row["revision"] ?? "1") ?? 1,
                              updatedAt: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "0") ?? 0),
                              agent: agent, sourceIDs: document.sourceIDs, fileURL: try memoryURL(id),
                              relativePath: try database.run("SELECT path FROM memory_files WHERE id=?", [id.uuidString]).first?["path"] ?? "",
                              contextSourceIDs: document.contextSourceIDs, observedAt: document.observedAt)
    }

    func saveEntry(id: UUID, kind: KnowledgeKind, title: String, body: String, revision: Int,
                           agent: ClipAgent, sourceIDs: [UUID], relativePath: String? = nil, updatedAt: Date? = nil,
                           extraMetadata: String? = nil, contextSourceIDs: [UUID]? = nil, observedAt: Date? = nil) throws -> URL {
        let previous = try database.run("SELECT path FROM memory_files WHERE id=?", [id.uuidString]).first?["path"]
        let memoryPath = relativePath ?? previous ?? MemoryLayout.defaultPath(id: id, title: title)
        let memory = try MemoryLayout.url(memoryPath, in: root.appendingPathComponent("Memory"))
        if let owner = try database.run("SELECT id FROM memory_files WHERE path=?", [memoryPath]).first?["id"], owner != id.uuidString { throw LibraryError.conflict }
        if FileManager.default.fileExists(atPath: memory.path), try MemoryDocument(String(contentsOf: memory, encoding: .utf8)).id != id { throw LibraryError.conflict }
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
            try database.run("INSERT INTO entry_search(id,title,body,terms,anchors) VALUES(?,?,?,?,?)", [id.uuidString, title, searchBody, Self.tokens(title + " " + searchBody), try anchorTerms(id.uuidString)])
            try indexLinks(id: id, body: body)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    static func tokens(_ text: String) -> String {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]).lowercased() }.joined(separator: " ")
    }
}
