import Foundation

/// Last week's summary: where it goes and the Daily pages it draws on.
public struct WeeklySummary: Sendable, Equatable, Codable {
    public var path: String
    public var dailies: [String]
}

/// What one dream may touch, fixed when the dream is queued.
public struct ConsolidationPlan: Sendable, Equatable, Codable {
    /// Reading records filed as entities or Inbox items; nothing else moves them, since they rarely change again.
    public var misfiled: [String] = []
    /// Pages changed since the last completed dream, and their one-hop neighbours.
    public var changed: [String]
    public var neighbours: [String]
    /// Set on the first dream of a week.
    public var weekly: WeeklySummary?
    /// Untouched pages reviewed longest ago, so every page is looked at again every few days.
    public var patrol: [String] = []

    public var reviewsPages: Bool { !(misfiled.isEmpty && changed.isEmpty && neighbours.isEmpty) }
    public var pages: [String] { misfiled + changed + neighbours + patrol }
}

/// A dream: the Agent reorganizes existing memory once a day while the user is away, like sleep consolidates the day.
/// It shares the organizing queue with batches but has its own timing, turn length and failure rules.
public enum MemoryDream {
    /// A dream day starts at this local hour, so a late night still belongs to the day before.
    public static let dayStartHour = 4
    /// No new screenshots for this long counts as the user being away.
    public static let idleInterval: TimeInterval = 20 * 60
    /// Each turn may run this long; a batch turn stops at the ACP client's default.
    public static let turnLimit: Duration = .seconds(2700)
    /// Runs a dream gets, counting the first; one retry covers a dropped connection.
    public static let maxAttempts = 2
    public static let retryDelay: TimeInterval = 1800
    /// Pages in the review turn: misfiled pages first, then changed pages, then neighbours; the rest waits a day.
    /// A live run over 30 pages used a whole turn on aliases alone.
    public static let scopeLimit = 12
    public static let misfiledLimit = 4
    /// Pages in the patrol turn.
    public static let patrolLimit = 8

    /// The dream day a moment belongs to.
    static func day(of date: Date, calendar: Calendar) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date.addingTimeInterval(-Double(dayStartHour) * 3600))
    }

    static func weekPath(for date: Date, calendar: Calendar) -> String {
        let week = calendar.component(.weekOfYear, from: date), year = calendar.component(.yearForWeekOfYear, from: date)
        return String(format: "Daily/%04d/Weekly/%04d-W%02d.md", year, year, week)
    }
}

extension LibraryStore {
    /// Start of the last dream that finished; the next dream reviews what changed after it.
    static let consolidatedAtKey = "consolidated_at"

    /// Queues today's dream when it is due: nothing else is waiting, the user has been away a while and no dream was
    /// queued this dream day. A day with nothing to reorganize is recorded as done without a job.
    @discardableResult
    public func enqueueDreamIfDue(agent: ClipAgent, at date: Date = Date(), calendar: Calendar = .current) throws -> ClipJob? {
        guard try database.run("SELECT id FROM jobs WHERE state IN ('queued','running') LIMIT 1").isEmpty,
              try database.run("SELECT capture_id FROM pending_captures LIMIT 1").isEmpty else { return nil }
        if let last = try database.run("SELECT max(captured_at) t FROM captures").first?["t"].flatMap(Double.init),
           date.timeIntervalSince1970 - last < MemoryDream.idleInterval { return nil }
        let today = MemoryDream.day(of: date, calendar: calendar)
        let lastDream = try database.run("SELECT max(created_at) t FROM jobs WHERE kind='dream'").first?["t"].flatMap(Double.init)
        let lastDone = try database.run("SELECT value FROM vault_meta WHERE key=?", [Self.consolidatedAtKey]).first?["value"].flatMap(Double.init)
        for time in [lastDream, lastDone].compactMap({ $0 }) where MemoryDream.day(of: Date(timeIntervalSince1970: time), calendar: calendar) == today {
            return nil
        }
        guard let plan = try dreamPlan(at: date, calendar: calendar) else {
            try recordConsolidation(at: date)
            return nil
        }
        return try queueDream(plan, agent: agent, at: date)
    }

    /// The user asked for a dream now: no waiting for idle time, and a day with nothing new still gets its patrol.
    /// It counts as that day's dream. Nil only while another dream is queued or running, or when memory is empty.
    @discardableResult
    public func enqueueDreamNow(agent: ClipAgent, at date: Date = Date(), calendar: Calendar = .current) throws -> ClipJob? {
        guard try database.run("SELECT id FROM jobs WHERE kind='dream' AND state IN ('queued','running') LIMIT 1").isEmpty,
              let plan = try dreamPlan(at: date, calendar: calendar, patrolAlone: true) else { return nil }
        return try queueDream(plan, agent: agent, at: date)
    }

    private func queueDream(_ plan: ConsolidationPlan, agent: ClipAgent, at date: Date) throws -> ClipJob? {
        let id = try database.transaction { () -> UUID in
            let id = try insertJob(sourceIDs: [], agent: agent, date: date)
            try database.run("UPDATE jobs SET kind='dream' WHERE id=?", [id.uuidString])
            try database.run("INSERT INTO dream_plans VALUES(?,?)", [id.uuidString, String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)])
            return id
        }
        return try database.run("SELECT * FROM jobs WHERE id=?", [id.uuidString]).first.map(job)
    }

    /// Nil when there is nothing to reorganize. Until a dream finishes, the window reaches back one day before the first.
    public func dreamPlan(at date: Date = Date(), calendar: Calendar = .current, patrolAlone: Bool = false) throws -> ConsolidationPlan? {
        try synchronizeMemoryFiles()
        let last = try database.run("SELECT value FROM vault_meta WHERE key=?", [Self.consolidatedAtKey]).first?["value"].flatMap(Double.init)
        let first = try database.run("SELECT min(created_at) t FROM jobs WHERE kind='dream'").first?["t"].flatMap(Double.init)
        let since = Date(timeIntervalSince1970: last ?? min(first ?? date.timeIntervalSince1970, date.timeIntervalSince1970) - 86_400)
        let entries = try database.run("SELECT * FROM entries").map(entry).filter { !$0.relativePath.hasPrefix(Self.archivePrefix) }
        let changed = entries.filter { $0.updatedAt >= since }.sorted { $0.updatedAt > $1.updatedAt }
        var weekly: WeeklySummary?
        var iso = calendar
        iso.firstWeekday = 2
        iso.minimumDaysInFirstWeek = 4
        if let previousWeek = iso.date(byAdding: .weekOfYear, value: -1, to: date), let interval = iso.dateInterval(of: .weekOfYear, for: previousWeek) {
            let path = MemoryDream.weekPath(for: previousWeek, calendar: iso)
            let formatter = DateFormatter()
            formatter.calendar = iso
            formatter.timeZone = iso.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let days = Set(stride(from: interval.start, to: interval.end, by: 86_400).map { formatter.string(from: $0) })
            let dailies = entries.map(\.relativePath).filter { path in
                path.hasPrefix("Daily/") && days.contains { path.hasSuffix("/\($0).md") || path.contains("/\($0)/") }
            }.sorted()
            if !dailies.isEmpty, !entries.contains(where: { $0.relativePath == path }) { weekly = WeeklySummary(path: path, dailies: dailies) }
        }
        let misfiled = Array(try memoryLint(now: date).misfiled.prefix(MemoryDream.misfiledLimit))
        let changedPaths = Array(changed.map(\.relativePath).filter { !misfiled.contains($0) }.prefix(MemoryDream.scopeLimit - misfiled.count))
        var neighbours: [String] = []
        let chosen = Set(changedPaths + misfiled)
        for item in changed.prefix(changedPaths.count) where !item.isRootDocument {
            let rows = try database.run("""
                SELECT f.path FROM memory_links l JOIN memory_files f ON f.id=l.target_id WHERE l.source=?
                UNION SELECT f.path FROM memory_links l JOIN memory_files f ON f.id=l.source WHERE l.target_id=?
                """, [item.id.uuidString, item.id.uuidString])
            for path in rows.compactMap({ $0["path"] }) where !chosen.contains(path) && !neighbours.contains(path)
                && !MemoryLayout.rootFiles.contains(path) && !path.hasPrefix(Self.archivePrefix) {
                guard chosen.count + neighbours.count < MemoryDream.scopeLimit else { break }
                neighbours.append(path)
            }
        }
        // Knowledge pages outside today's scope, never reviewed or reviewed longest ago. Daily pages are history.
        let taken = chosen.union(neighbours)
        let reviewed = Dictionary(uniqueKeysWithValues: try database.run("SELECT entry_id,reviewed_at FROM memory_reviews").compactMap { row -> (String, Double)? in
            guard let id = row["entry_id"], let time = row["reviewed_at"].flatMap(Double.init) else { return nil }
            return (id, time)
        })
        let patrol = entries.filter { ($0.relativePath.hasPrefix("Wiki/") || $0.relativePath.hasPrefix("Inbox/")) && !taken.contains($0.relativePath) }
            .sorted { (reviewed[$0.id.uuidString] ?? 0, $0.relativePath) < (reviewed[$1.id.uuidString] ?? 0, $1.relativePath) }
            .prefix(MemoryDream.patrolLimit).map(\.relativePath)
        let plan = ConsolidationPlan(misfiled: misfiled, changed: changedPaths, neighbours: neighbours.sorted(), weekly: weekly, patrol: Array(patrol))
        return plan.reviewsPages || weekly != nil || (patrolAlone && !plan.patrol.isEmpty) ? plan : nil
    }

    public func recordConsolidation(at date: Date = Date()) throws {
        try database.run("INSERT INTO vault_meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                         [Self.consolidatedAtKey, String(date.timeIntervalSince1970)])
    }

    public func beginConsolidation() throws -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: try snapshot().entries.map { ($0.id, $0.revision) })
    }

    /// Settles whatever a dream turn left on disk, like a batch without new screenshots: a deleted root file comes back,
    /// a bad write goes back to its last good revision, and cited evidence is recomputed from each changed body.
    @discardableResult
    public func settleConsolidation(previousRevisions: [UUID: Int]) throws -> Int {
        // No starting point means the turn never began; without one every page would look edited.
        guard !previousRevisions.isEmpty else { return 0 }
        let directory = root.appendingPathComponent("Memory")
        for path in MemoryLayout.rootFiles where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) {
            guard let row = try database.run("SELECT e.path FROM entries e JOIN memory_files f ON f.id=e.id WHERE f.path=?", [path]).first,
                  let stored = row["path"] else { continue }
            let text = try String(contentsOf: root.appendingPathComponent(stored), encoding: .utf8)
            try MemoryDocument.published(text, path: path).write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        _ = try restoreRejectedMemoryFiles()
        let entries = try snapshot().entries
        let changed = entries.filter { previousRevisions[$0.id] != $0.revision }
        try database.transaction {
            for entry in changed {
                let previous = try previousRevisions[entry.id].map {
                    try MemoryDocument(String(contentsOf: root.appendingPathComponent("Entries/\(entry.id)/\($0).md"), encoding: .utf8))
                }
                // Merging moves citations between pages, so any screenshot the library still knows stays citable.
                let allowed = Set((previous?.contextSourceIDs ?? []) + (previous?.sourceIDs ?? []))
                let sources = try MemoryDocument.citedSourceIDs(in: entry.body).filter {
                    try allowed.contains($0) || !database.run("SELECT id FROM captures WHERE id=?", [$0.uuidString]).isEmpty
                }
                let observed = try availableCaptures(ids: sources).map(\.date).max() ?? previous?.observedAt
                _ = try saveEntry(id: entry.id, kind: .memory, title: entry.title, body: entry.body, revision: entry.revision + 1,
                    agent: entry.agent, sourceIDs: sources, relativePath: entry.relativePath,
                    contextSourceIDs: Array(Set((previous?.contextSourceIDs ?? []) + sources)).sorted { $0.uuidString < $1.uuidString }, observedAt: observed)
            }
        }
        try publishMemoryFiles()
        return changed.count + Set(previousRevisions.keys).subtracting(entries.map(\.id)).count
    }

    /// Ends a dream. Files are settled either way; the queue is never paused. A finished dream moves the review baseline
    /// and the review clock of the pages it saw; an unfinished one leaves both, so tomorrow's dream picks the pages up.
    @discardableResult
    public func finishDream(jobID: UUID, previousRevisions: [UUID: Int], error: String? = nil, at date: Date = Date()) throws -> Int {
        guard let row = try database.run("SELECT * FROM jobs WHERE id=? AND kind='dream' AND state IN ('running','queued')", [jobID.uuidString]).first else {
            throw LibraryError.invalidResult(String(localized: "整理任务未在执行。"))
        }
        let dream = try job(row)
        let changed = try settleConsolidation(previousRevisions: previousRevisions)
        try database.transaction {
            if error == nil {
                let started = try database.run("SELECT started_at FROM job_times WHERE id=?", [jobID.uuidString]).first?["started_at"].flatMap(Double.init)
                try recordConsolidation(at: started.map(Date.init(timeIntervalSince1970:)) ?? date)
                for path in dream.dreamPlan?.pages ?? [] {
                    guard let id = try database.run("SELECT id FROM memory_files WHERE path=?", [path]).first?["id"] else { continue }
                    try database.run("INSERT INTO memory_reviews VALUES(?,?) ON CONFLICT(entry_id) DO UPDATE SET reviewed_at=excluded.reviewed_at",
                                     [id, String(date.timeIntervalSince1970)])
                }
            }
            try database.run("UPDATE jobs SET state=?,error=?,retry_at=NULL WHERE id=?", [error == nil ? "completed" : "failed", error, jobID.uuidString])
            try database.run("UPDATE job_times SET finished_at=? WHERE id=?", [String(date.timeIntervalSince1970), jobID.uuidString])
        }
        return changed
    }
}
