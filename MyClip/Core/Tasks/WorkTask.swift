import Foundation

public enum WorkTaskStatus: String, Codable, CaseIterable, Sendable {
    case candidate, todo, doing, done, ignored
    public var title: String {
        switch self {
        case .candidate: String(localized: "待确认")
        case .todo: String(localized: "待办")
        case .doing: String(localized: "进行中")
        case .done: String(localized: "已完成")
        case .ignored: String(localized: "已忽略")
        }
    }
    public var isConfirmed: Bool { self == .todo || self == .doing || self == .done }
    public var isUnfinished: Bool { self == .todo || self == .doing }
}

public struct WorkTaskDraft: Codable, Sendable {
    public var taskID: UUID?
    public var title: String
    public var project: String
    public var suggestedStatus: WorkTaskStatus
    public var evidence: String
    public var sourceIDs: [UUID]
    public var memoryIDs: [UUID]

    public init(taskID: UUID? = nil, title: String, project: String = "", suggestedStatus: WorkTaskStatus = .todo, evidence: String, sourceIDs: [UUID] = [], memoryIDs: [UUID] = []) {
        self.taskID = taskID; self.title = title; self.project = project; self.suggestedStatus = suggestedStatus
        self.evidence = evidence; self.sourceIDs = sourceIDs; self.memoryIDs = memoryIDs
    }
}

public struct WorkTaskEvidence: Identifiable, Sendable {
    public let id: UUID
    public let body: String
    public let sourceIDs: [UUID]
    public let memoryIDs: [UUID]
    public let date: Date
}

public struct WorkTask: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let project: String
    public let status: WorkTaskStatus
    public let suggestedStatus: WorkTaskStatus?
    public let createdAt: Date
    public let updatedAt: Date
    public let confirmedAt: Date?
    public let completedAt: Date?
    public var waitingReason: String = ""
    public var statusObservedAt: Date? = nil
    public let evidence: [WorkTaskEvidence]
    public var projectTitle: String { project.isEmpty ? String(localized: "未归类") : project }
}

public struct WorkTaskEvent: Identifiable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let from: WorkTaskStatus?
    public let to: WorkTaskStatus
    public let date: Date
    public let actor: WorkTaskActor
}

public enum WorkTaskActor: String, Sendable {
    case user, ai
    public var title: String { self == .ai ? "AI" : String(localized: "你") }
}

public struct WorkTaskReview: Sendable {
    public let taskID: UUID
    public let title: String
    public let status: WorkTaskStatus
    fileprivate let previous: [String: String]
    fileprivate let applied: [String: String]
    fileprivate let eventID: String
}

public struct WorkTaskStatistics: Sendable {
    public struct Day: Identifiable, Sendable {
        public let date: Date
        public var added = 0
        public var completed = 0
        public var id: Date { date }
    }
    public var days: [Day] = []
    public var added = 0
    public var completed = 0
    public var unfinished = 0
    public var backlogChange = 0
    public init() {}
}

extension LibraryStore {
    static func migrateWorkTasks(_ database: SQLiteConnection) throws {
        try database.transaction {
            if try !database.run("PRAGMA table_info(work_tasks)").contains(where: { $0["name"] == "status_observed_at" }) {
                try database.script("ALTER TABLE work_tasks ADD COLUMN status_observed_at REAL; UPDATE work_tasks SET status_observed_at=updated_at;")
            }
            if try !database.run("PRAGMA table_info(work_task_events)").contains(where: { $0["name"] == "actor" }) {
                try database.script("ALTER TABLE work_task_events ADD COLUMN actor TEXT NOT NULL DEFAULT 'user';")
                try database.run("UPDATE work_task_events SET actor='ai' WHERE from_status IS NULL AND to_status='candidate'")
            }
            try database.script("PRAGMA user_version=7;")
        }
    }

    public func workTasks() throws -> [WorkTask] {
        try database.run("SELECT * FROM work_tasks ORDER BY updated_at DESC,id").map { row in
            guard let id = row["id"].flatMap(UUID.init(uuidString:)),
                  let status = row["status"].flatMap(WorkTaskStatus.init(rawValue:)) else {
                throw LibraryError.database(String(localized: "任务记录格式错误。"))
            }
            func date(_ key: String) -> Date? { row[key].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }
            let evidence = try database.run("SELECT * FROM work_task_evidence WHERE task_id=? ORDER BY created_at DESC,rowid DESC", [id.uuidString]).map { item -> WorkTaskEvidence in
                guard let evidenceID = item["id"].flatMap(UUID.init(uuidString:)) else { throw LibraryError.database(String(localized: "任务依据格式错误。")) }
                return WorkTaskEvidence(id: evidenceID, body: item["body"] ?? "",
                    sourceIDs: try JSONDecoder().decode([UUID].self, from: Data((item["source_ids"] ?? "[]").utf8)),
                    memoryIDs: try JSONDecoder().decode([UUID].self, from: Data((item["memory_ids"] ?? "[]").utf8)),
                    date: Date(timeIntervalSince1970: Double(item["created_at"] ?? "0") ?? 0))
            }
            return WorkTask(id: id, title: row["title"] ?? "", project: row["project"] ?? "", status: status,
                suggestedStatus: row["suggested_status"].flatMap(WorkTaskStatus.init(rawValue:)),
                createdAt: date("created_at") ?? .distantPast, updatedAt: date("updated_at") ?? .distantPast,
                confirmedAt: date("confirmed_at"), completedAt: date("completed_at"), waitingReason: row["waiting_reason"] ?? "", statusObservedAt: date("status_observed_at"), evidence: evidence)
        }
    }

    @discardableResult
    public func ingestTaskSuggestions(_ drafts: [WorkTaskDraft], allowedSourceIDs: Set<UUID>, allowedMemoryIDs: Set<UUID>, at date: Date = Date()) throws -> Int {
        guard drafts.count <= 40 else { throw LibraryError.invalidResult(String(localized: "一次最多识别 40 项任务。")) }
        return try database.transaction {
            var changed: Set<UUID> = []
            for draft in drafts {
                let fields = try Self.taskFields(title: draft.title, project: draft.project)
                let quote = draft.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
                let sources = Set(draft.sourceIDs), memories = Set(draft.memoryIDs)
                guard draft.suggestedStatus.isConfirmed, !quote.isEmpty, quote.count <= 2400,
                      !sources.isEmpty || !memories.isEmpty,
                      sources.isSubset(of: allowedSourceIDs), memories.isSubset(of: allowedMemoryIDs) else {
                    throw LibraryError.invalidResult(String(localized: "任务缺少有效依据，或引用了本次分析范围之外的来源。"))
                }
                var observations: [Date] = []
                var undatedUpdates: [Date] = []
                for source in sources {
                    guard let row = try database.run("SELECT captured_at FROM captures WHERE id=?", [source.uuidString]).first,
                          let time = row["captured_at"].flatMap(Double.init) else { throw LibraryError.invalidResult(String(localized: "任务截图来源不存在。")) }
                    observations.append(Date(timeIntervalSince1970: time))
                }
                for memory in memories {
                    guard let row = try database.run("SELECT * FROM entries WHERE id=?", [memory.uuidString]).first else { throw LibraryError.invalidResult(String(localized: "任务 Memory 来源不存在。")) }
                    let memory = try entry(row)
                    if let observed = try memory.observedAt ?? availableCaptures(ids: memory.sourceIDs).map(\.date).max() {
                        observations.append(observed)
                    } else {
                        undatedUpdates.append(memory.updatedAt)
                    }
                }
                let existing: [String: String]?
                if let id = draft.taskID {
                    guard let row = try database.run("SELECT * FROM work_tasks WHERE id=?", [id.uuidString]).first else { throw LibraryError.invalidResult(String(localized: "关联的任务不存在。")) }
                    existing = row
                } else {
                    existing = try database.run("SELECT * FROM work_tasks WHERE identity=?", [fields.identity]).first
                }
                if existing?["status"] == WorkTaskStatus.ignored.rawValue { continue }
                let id = existing?["id"].flatMap(UUID.init(uuidString:)) ?? UUID()
                if existing == nil { try insertWorkTask(id: id, title: fields.title, project: fields.project, identity: fields.identity, status: .candidate, at: date, actor: .ai) }
                let sourceJSON = try Self.taskIDsJSON(sources), memoryJSON = try Self.taskIDsJSON(memories)
                let fingerprint = Self.memoryHash(quote + "\n" + sourceJSON + "\n" + memoryJSON)
                if try database.run("SELECT id FROM work_task_evidence WHERE task_id=? AND fingerprint=?", [id.uuidString, fingerprint]).first != nil { continue }
                try database.run("INSERT INTO work_task_evidence VALUES(?,?,?,?,?,?,?)", [UUID().uuidString, id.uuidString, fingerprint, quote, sourceJSON, memoryJSON, String(date.timeIntervalSince1970)])
                let status = existing?["status"].flatMap(WorkTaskStatus.init(rawValue:)) ?? .candidate
                let cutoff = Date(timeIntervalSince1970: (existing?["status_observed_at"] ?? existing?["updated_at"]).flatMap(Double.init) ?? 0)
                let observedAt = observations.filter { $0 <= date }.max()
                let fresh = observedAt.map { $0 > cutoff } ?? false
                if existing == nil || fresh || undatedUpdates.contains(where: { $0 > cutoff && $0 <= date }) {
                    let advances = (status == .todo && [.doing, .done].contains(draft.suggestedStatus))
                        || (status == .doing && draft.suggestedStatus == .done)
                    if advances && fresh {
                        try changeWorkTaskStatus(id, status: draft.suggestedStatus, at: date, actor: .ai, observedAt: observedAt)
                    } else {
                        try database.run("UPDATE work_tasks SET suggested_status=?,updated_at=?,status_observed_at=coalesce(?,status_observed_at) WHERE id=?",
                            [draft.suggestedStatus == status ? nil : draft.suggestedStatus.rawValue, String(date.timeIntervalSince1970), fresh || existing == nil ? observedAt.map { String($0.timeIntervalSince1970) } : nil, id.uuidString])
                    }
                }
                changed.insert(id)
            }
            return changed.count
        }
    }

    @discardableResult
    public func createWorkTask(title: String, project: String = "", waitingReason: String = "", at date: Date = Date()) throws -> UUID {
        let fields = try Self.taskFields(title: title, project: project)
        guard waitingReason.count <= 240 else { throw LibraryError.invalidResult(String(localized: "等待事项最多 240 字。")) }
        return try database.transaction {
            guard try database.run("SELECT id FROM work_tasks WHERE identity=?", [fields.identity]).isEmpty else { throw LibraryError.invalidResult(String(localized: "同项目下已有同名任务，请更新原任务。")) }
            let id = UUID()
            try insertWorkTask(id: id, title: fields.title, project: fields.project, identity: fields.identity, status: .todo, at: date)
            try database.run("UPDATE work_tasks SET waiting_reason=? WHERE id=?", [waitingReason.trimmingCharacters(in: .whitespacesAndNewlines), id.uuidString])
            return id
        }
    }

    public func updateWorkTask(_ id: UUID, title: String, project: String, waitingReason: String? = nil) throws {
        let fields = try Self.taskFields(title: title, project: project)
        guard (waitingReason?.count ?? 0) <= 240 else { throw LibraryError.invalidResult(String(localized: "等待事项最多 240 字。")) }
        try database.transaction {
            guard try database.run("SELECT id FROM work_tasks WHERE id=?", [id.uuidString]).first != nil else { throw LibraryError.invalidResult(String(localized: "任务不存在。")) }
            guard try database.run("SELECT id FROM work_tasks WHERE identity=? AND id<>?", [fields.identity, id.uuidString]).isEmpty else { throw LibraryError.invalidResult(String(localized: "同项目下已有同名任务。")) }
            let time = String(Date().timeIntervalSince1970)
            try database.run("UPDATE work_tasks SET title=?,project=?,identity=?,updated_at=?,waiting_reason=coalesce(?,waiting_reason),status_observed_at=? WHERE id=?", [fields.title, fields.project, fields.identity, time, waitingReason?.trimmingCharacters(in: .whitespacesAndNewlines), time, id.uuidString])
        }
    }

    public func setWorkTaskStatus(_ id: UUID, status: WorkTaskStatus, at date: Date = Date()) throws {
        try database.transaction {
            try changeWorkTaskStatus(id, status: status, at: date, actor: .user)
        }
    }

    public func reviewWorkTask(_ id: UUID, status: WorkTaskStatus, at date: Date = Date()) throws -> WorkTaskReview {
        try database.transaction {
            guard status.isConfirmed || status == .ignored else { throw LibraryError.invalidResult(String(localized: "请选择确认后的任务状态，或忽略这条建议。")) }
            guard let previous = try database.run("SELECT * FROM work_tasks WHERE id=?", [id.uuidString]).first,
                  previous["status"] == WorkTaskStatus.candidate.rawValue else { throw LibraryError.invalidResult(String(localized: "这项任务已不在待确认列表，请查看最新状态。")) }
            try changeWorkTaskStatus(id, status: status, at: date, actor: .user)
            guard let applied = try database.run("SELECT * FROM work_tasks WHERE id=?", [id.uuidString]).first,
                  let eventID = try database.run("SELECT id FROM work_task_events WHERE task_id=? ORDER BY rowid DESC LIMIT 1", [id.uuidString]).first?["id"] else {
                throw LibraryError.database(String(localized: "无法读取任务确认记录。"))
            }
            return WorkTaskReview(taskID: id, title: previous["title"] ?? "", status: status, previous: previous, applied: applied, eventID: eventID)
        }
    }

    public func undoWorkTaskReview(_ review: WorkTaskReview) throws {
        try database.transaction {
            let id = review.taskID.uuidString
            guard try database.run("SELECT * FROM work_tasks WHERE id=?", [id]).first == review.applied,
                  try database.run("SELECT id FROM work_task_events WHERE task_id=? ORDER BY rowid DESC LIMIT 1", [id]).first?["id"] == review.eventID else {
                throw LibraryError.invalidResult(String(localized: "任务已有新的修改，无法撤销这次确认。请在详情中调整状态。"))
            }
            let previous = review.previous
            try database.run("UPDATE work_tasks SET status=?,suggested_status=?,updated_at=?,confirmed_at=?,completed_at=?,waiting_reason=?,status_observed_at=? WHERE id=?",
                [previous["status"], previous["suggested_status"], previous["updated_at"], previous["confirmed_at"], previous["completed_at"], previous["waiting_reason"], previous["status_observed_at"], id])
            try database.run("DELETE FROM work_task_events WHERE id=?", [review.eventID])
        }
    }

    private func changeWorkTaskStatus(_ id: UUID, status: WorkTaskStatus, at date: Date, actor: WorkTaskActor, observedAt: Date? = nil) throws {
        guard let row = try database.run("SELECT status FROM work_tasks WHERE id=?", [id.uuidString]).first,
              let previous = row["status"].flatMap(WorkTaskStatus.init(rawValue:)) else { throw LibraryError.invalidResult(String(localized: "任务不存在。")) }
        let observation = String((observedAt ?? date).timeIntervalSince1970)
        if previous == status {
            try database.run("UPDATE work_tasks SET suggested_status=NULL,updated_at=?,status_observed_at=? WHERE id=?", [String(date.timeIntervalSince1970), observation, id.uuidString])
            return
        }
        let time = String(date.timeIntervalSince1970)
        try database.run("UPDATE work_tasks SET status=?,suggested_status=NULL,updated_at=?,confirmed_at=coalesce(confirmed_at,?),completed_at=?,waiting_reason=coalesce(?,waiting_reason),status_observed_at=? WHERE id=?",
            [status.rawValue, time, status.isConfirmed ? time : nil, status == .done ? time : nil, status == .done ? "" : nil, observation, id.uuidString])
        try recordWorkTaskEvent(id, from: previous, to: status, at: date, actor: actor)
    }

    public func workTaskEvents(_ id: UUID? = nil) throws -> [WorkTaskEvent] {
        try database.run("SELECT * FROM work_task_events" + (id == nil ? "" : " WHERE task_id=?") + " ORDER BY created_at,rowid", id.map { [$0.uuidString] } ?? []).map { row in
            guard let eventID = row["id"].flatMap(UUID.init(uuidString:)), let taskID = row["task_id"].flatMap(UUID.init(uuidString:)),
                  let to = row["to_status"].flatMap(WorkTaskStatus.init(rawValue:)) else { throw LibraryError.database(String(localized: "任务历史格式错误。")) }
            return WorkTaskEvent(id: eventID, taskID: taskID, from: row["from_status"].flatMap(WorkTaskStatus.init(rawValue:)), to: to,
                date: Date(timeIntervalSince1970: Double(row["created_at"] ?? "0") ?? 0), actor: row["actor"].flatMap(WorkTaskActor.init(rawValue:)) ?? .user)
        }
    }

    public func workTaskStatistics(days: Int, now: Date = Date(), calendar: Calendar = .current) throws -> WorkTaskStatistics {
        let tasks = try workTasks(), events = try workTaskEvents()
        let today = calendar.startOfDay(for: now)
        let first = tasks.compactMap(\.confirmedAt).filter { $0 <= now }.min() ?? today
        let start = days == 0 ? calendar.startOfDay(for: first) : calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today)!
        var result = WorkTaskStatistics()
        var cursor = start
        while cursor <= today {
            result.days.append(.init(date: cursor))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        let indices = Dictionary(uniqueKeysWithValues: result.days.enumerated().map { ($0.element.date, $0.offset) })
        for task in tasks {
            if let date = task.confirmedAt, date <= now, let index = indices[calendar.startOfDay(for: date)] { result.days[index].added += 1 }
        }
        var completions: [Date: Set<UUID>] = [:]
        var latest: [UUID: WorkTaskStatus] = [:]
        for event in events where event.date <= now {
            latest[event.taskID] = event.to
            let day = calendar.startOfDay(for: event.date)
            guard indices[day] != nil else { continue }
            if event.to == .done { completions[day, default: []].insert(event.taskID) }
            result.backlogChange += (event.to.isUnfinished ? 1 : 0) - (event.from?.isUnfinished == true ? 1 : 0)
        }
        for (day, ids) in completions { if let index = indices[day] { result.days[index].completed = ids.count } }
        result.added = result.days.reduce(0) { $0 + $1.added }
        result.completed = result.days.reduce(0) { $0 + $1.completed }
        result.unfinished = latest.values.filter(\.isUnfinished).count
        return result
    }

    private static func taskFields(title: String, project: String) throws -> (title: String, project: String, identity: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines), project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 240, project.count <= 120 else { throw LibraryError.invalidResult(String(localized: "任务名称不能为空且最多 240 字，项目名称最多 120 字。")) }
        func normalize(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return (title, project, memoryHash(normalize(project) + "\n" + normalize(title)))
    }

    private static func taskIDsJSON(_ ids: Set<UUID>) throws -> String {
        String(decoding: try JSONEncoder().encode(ids.sorted { $0.uuidString < $1.uuidString }), as: UTF8.self)
    }

    private func insertWorkTask(id: UUID, title: String, project: String, identity: String, status: WorkTaskStatus, at date: Date, actor: WorkTaskActor = .user) throws {
        let time = String(date.timeIntervalSince1970)
        try database.run("INSERT INTO work_tasks(id,identity,title,project,status,created_at,updated_at,confirmed_at,status_observed_at) VALUES(?,?,?,?,?,?,?,?,?)", [id.uuidString, identity, title, project, status.rawValue, time, time, status.isConfirmed ? time : nil, time])
        try recordWorkTaskEvent(id, from: nil, to: status, at: date, actor: actor)
    }

    private func recordWorkTaskEvent(_ id: UUID, from: WorkTaskStatus?, to: WorkTaskStatus, at date: Date, actor: WorkTaskActor) throws {
        try database.run("INSERT INTO work_task_events(id,task_id,from_status,to_status,created_at,actor) VALUES(?,?,?,?,?,?)", [UUID().uuidString, id.uuidString, from?.rawValue, to.rawValue, String(date.timeIntervalSince1970), actor.rawValue])
    }
}
