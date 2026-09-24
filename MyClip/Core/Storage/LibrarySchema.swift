import Foundation

extension LibraryStore {
    static func prepareDatabase(_ database: SQLiteConnection) throws {
        let version = Int(try database.run("PRAGMA user_version").first?["user_version"] ?? "0") ?? 0
        guard version <= 15 else { throw LibraryError.database(String(localized: "资料库由更新的 MyClip 创建，请升级应用。")) }
        if version > 0 && version < 10 {
            // Search tables gain anchor text, stemming and resolved link edges; they are rebuilt from entry files below.
            try database.script("DROP TABLE IF EXISTS entry_search; DROP TABLE IF EXISTS memory_passage_search; DROP TABLE IF EXISTS memory_links;")
        } else if version > 0 && version < 12 {
            // The full-text table gains declared aliases; it is rebuilt from entry files on the first synchronization.
            try database.script("DROP TABLE IF EXISTS entry_search;")
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
            CREATE VIRTUAL TABLE IF NOT EXISTS entry_search USING fts5(id UNINDEXED, title, body, terms, anchors, aliases, tokenize='porter unicode61');
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
                fragment TEXT NOT NULL DEFAULT '', ordinal INTEGER, label TEXT NOT NULL DEFAULT '',
                fact TEXT NOT NULL DEFAULT '', section TEXT NOT NULL DEFAULT '', date REAL
            );
            CREATE INDEX IF NOT EXISTS memory_links_source ON memory_links(source);
            CREATE INDEX IF NOT EXISTS memory_links_target ON memory_links(target_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_edge_search USING fts5(fact, section, terms, tokenize='porter unicode61');
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
            CREATE TABLE IF NOT EXISTS dream_plans (job_id TEXT PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE, plan TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS memory_reviews (entry_id TEXT PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE, reviewed_at REAL NOT NULL);
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
        if version < 12 {
            // Aliases join the index, and published files drop their evidence lists: every file is rewritten once.
            if version > 0 {
                try database.run("INSERT OR REPLACE INTO vault_meta(key,value) VALUES('search_rebuild','1')")
                try database.run("UPDATE memory_files SET pending=1")
            }
            try database.script("PRAGMA user_version=12;")
        }
        if version < 13 {
            // Dreams join the queue as their own kind of job, with a fixed plan and a per-page review clock.
            let jobColumns = Set(try database.run("PRAGMA table_info(jobs)").compactMap { $0["name"] })
            if !jobColumns.contains("kind") { try database.script("ALTER TABLE jobs ADD COLUMN kind TEXT NOT NULL DEFAULT 'batch';") }
            try database.script("PRAGMA user_version=13;")
        }
        if version < 14 {
            // Link edges carry the line that holds them, its heading and a date, and the lines become searchable.
            let linkColumns = Set(try database.run("PRAGMA table_info(memory_links)").compactMap { $0["name"] })
            if !linkColumns.contains("fact") {
                try database.script("""
                    ALTER TABLE memory_links ADD COLUMN fact TEXT NOT NULL DEFAULT '';
                    ALTER TABLE memory_links ADD COLUMN section TEXT NOT NULL DEFAULT '';
                    ALTER TABLE memory_links ADD COLUMN date REAL;
                    """)
            }
            if version > 0 { try database.run("INSERT OR REPLACE INTO vault_meta(key,value) VALUES('search_rebuild','1')") }
            try database.script("PRAGMA user_version=14;")
        }
        if version < 15 {
            // Pages whose source list missed screenshots cited in their text are repaired once on the next synchronization,
            // and passages are re-read: citations with a time between two IDs used to lose both IDs.
            if version > 0 {
                try database.run("INSERT OR REPLACE INTO vault_meta(key,value) VALUES('source_repair','1')")
                try database.run("INSERT OR REPLACE INTO vault_meta(key,value) VALUES('search_rebuild','1')")
            }
            try database.script("PRAGMA user_version=15;")
        }
        // Edge text shares the link's rowid, so removing a link (directly or by cascade) removes its searchable text.
        try database.script("""
            CREATE TRIGGER IF NOT EXISTS memory_links_forget AFTER DELETE ON memory_links BEGIN
                DELETE FROM memory_edge_search WHERE rowid=old.rowid;
            END;
            """)
    }

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
}
