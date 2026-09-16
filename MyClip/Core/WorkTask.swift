import Foundation

public enum WorkTaskStatus: String, Codable, CaseIterable, Sendable {
    case candidate, todo, doing, done, ignored
    public var title: String {
        switch self {
        case .candidate: "待确认"
        case .todo: "待办"
        case .doing: "进行中"
        case .done: "已完成"
        case .ignored: "已忽略"
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
    public let evidence: [WorkTaskEvidence]
    public var projectTitle: String { project.isEmpty ? "未归类" : project }
}

public struct WorkTaskEvent: Identifiable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let from: WorkTaskStatus?
    public let to: WorkTaskStatus
    public let date: Date
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
    public func workTasks() throws -> [WorkTask] {
        try database.run("SELECT * FROM work_tasks ORDER BY updated_at DESC,id").map { row in
            guard let id = row["id"].flatMap(UUID.init(uuidString:)),
                  let status = row["status"].flatMap(WorkTaskStatus.init(rawValue:)) else {
                throw LibraryError.database("任务记录格式错误。")
            }
            func date(_ key: String) -> Date? { row[key].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }
            let evidence = try database.run("SELECT * FROM work_task_evidence WHERE task_id=? ORDER BY created_at DESC,rowid DESC", [id.uuidString]).map { item -> WorkTaskEvidence in
                guard let evidenceID = item["id"].flatMap(UUID.init(uuidString:)) else { throw LibraryError.database("任务依据格式错误。") }
                return WorkTaskEvidence(id: evidenceID, body: item["body"] ?? "",
                    sourceIDs: try JSONDecoder().decode([UUID].self, from: Data((item["source_ids"] ?? "[]").utf8)),
                    memoryIDs: try JSONDecoder().decode([UUID].self, from: Data((item["memory_ids"] ?? "[]").utf8)),
                    date: Date(timeIntervalSince1970: Double(item["created_at"] ?? "0") ?? 0))
            }
            return WorkTask(id: id, title: row["title"] ?? "", project: row["project"] ?? "", status: status,
                suggestedStatus: row["suggested_status"].flatMap(WorkTaskStatus.init(rawValue:)),
                createdAt: date("created_at") ?? .distantPast, updatedAt: date("updated_at") ?? .distantPast,
                confirmedAt: date("confirmed_at"), completedAt: date("completed_at"), waitingReason: row["waiting_reason"] ?? "", evidence: evidence)
        }
    }

    @discardableResult
    public func ingestTaskSuggestions(_ drafts: [WorkTaskDraft], allowedSourceIDs: Set<UUID>, allowedMemoryIDs: Set<UUID>, at date: Date = Date()) throws -> Int {
        guard drafts.count <= 40 else { throw LibraryError.invalidResult("一次最多识别 40 项任务。") }
        return try database.transaction {
            var changed: Set<UUID> = []
            for draft in drafts {
                let fields = try Self.taskFields(title: draft.title, project: draft.project)
                let quote = draft.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
                let sources = Set(draft.sourceIDs), memories = Set(draft.memoryIDs)
                guard draft.suggestedStatus.isConfirmed, !quote.isEmpty, quote.count <= 2400,
                      !sources.isEmpty || !memories.isEmpty,
                      sources.isSubset(of: allowedSourceIDs), memories.isSubset(of: allowedMemoryIDs) else {
                    throw LibraryError.invalidResult("任务缺少有效依据，或引用了本次分析范围之外的来源。")
                }
                for source in sources {
                    guard try database.run("SELECT id FROM captures WHERE id=?", [source.uuidString]).first != nil else { throw LibraryError.invalidResult("任务截图来源不存在。") }
                }
                for memory in memories {
                    guard try database.run("SELECT id FROM entries WHERE id=?", [memory.uuidString]).first != nil else { throw LibraryError.invalidResult("任务 Memory 来源不存在。") }
                }
                let existing: [String: String]?
                if let id = draft.taskID {
                    guard let row = try database.run("SELECT * FROM work_tasks WHERE id=?", [id.uuidString]).first else { throw LibraryError.invalidResult("关联的任务不存在。") }
                    existing = row
                } else {
                    existing = try database.run("SELECT * FROM work_tasks WHERE identity=?", [fields.identity]).first
                }
                if existing?["status"] == WorkTaskStatus.ignored.rawValue { continue }
                let id = existing?["id"].flatMap(UUID.init(uuidString:)) ?? UUID()
                if existing == nil { try insertWorkTask(id: id, title: fields.title, project: fields.project, identity: fields.identity, status: .candidate, at: date) }
                let sourceJSON = try Self.taskIDsJSON(sources), memoryJSON = try Self.taskIDsJSON(memories)
                let fingerprint = Self.memoryHash(quote + "\n" + sourceJSON + "\n" + memoryJSON)
                if try database.run("SELECT id FROM work_task_evidence WHERE task_id=? AND fingerprint=?", [id.uuidString, fingerprint]).first != nil { continue }
                try database.run("INSERT INTO work_task_evidence VALUES(?,?,?,?,?,?,?)", [UUID().uuidString, id.uuidString, fingerprint, quote, sourceJSON, memoryJSON, String(date.timeIntervalSince1970)])
                // Evidence may suggest progress, but it never overwrites a user's confirmed state or title.
                try database.run("UPDATE work_tasks SET suggested_status=?,updated_at=? WHERE id=?", [draft.suggestedStatus.rawValue, String(date.timeIntervalSince1970), id.uuidString])
                changed.insert(id)
            }
            return changed.count
        }
    }

    @discardableResult
    public func createWorkTask(title: String, project: String = "", waitingReason: String = "", at date: Date = Date()) throws -> UUID {
        let fields = try Self.taskFields(title: title, project: project)
        guard waitingReason.count <= 240 else { throw LibraryError.invalidResult("等待事项最多 240 字。") }
        return try database.transaction {
            guard try database.run("SELECT id FROM work_tasks WHERE identity=?", [fields.identity]).isEmpty else { throw LibraryError.invalidResult("同项目下已有同名任务，请更新原任务。") }
            let id = UUID()
            try insertWorkTask(id: id, title: fields.title, project: fields.project, identity: fields.identity, status: .todo, at: date)
            try database.run("UPDATE work_tasks SET waiting_reason=? WHERE id=?", [waitingReason.trimmingCharacters(in: .whitespacesAndNewlines), id.uuidString])
            return id
        }
    }

    public func updateWorkTask(_ id: UUID, title: String, project: String, waitingReason: String? = nil) throws {
        let fields = try Self.taskFields(title: title, project: project)
        guard (waitingReason?.count ?? 0) <= 240 else { throw LibraryError.invalidResult("等待事项最多 240 字。") }
        try database.transaction {
            guard try database.run("SELECT id FROM work_tasks WHERE id=?", [id.uuidString]).first != nil else { throw LibraryError.invalidResult("任务不存在。") }
            guard try database.run("SELECT id FROM work_tasks WHERE identity=? AND id<>?", [fields.identity, id.uuidString]).isEmpty else { throw LibraryError.invalidResult("同项目下已有同名任务。") }
            try database.run("UPDATE work_tasks SET title=?,project=?,identity=?,updated_at=?,waiting_reason=coalesce(?,waiting_reason) WHERE id=?", [fields.title, fields.project, fields.identity, String(Date().timeIntervalSince1970), waitingReason?.trimmingCharacters(in: .whitespacesAndNewlines), id.uuidString])
        }
    }

    public func setWorkTaskStatus(_ id: UUID, status: WorkTaskStatus, at date: Date = Date()) throws {
        try database.transaction {
            guard let row = try database.run("SELECT status FROM work_tasks WHERE id=?", [id.uuidString]).first,
                  let previous = row["status"].flatMap(WorkTaskStatus.init(rawValue:)) else { throw LibraryError.invalidResult("任务不存在。") }
            if previous == status {
                try database.run("UPDATE work_tasks SET suggested_status=NULL WHERE id=?", [id.uuidString])
                return
            }
            let time = String(date.timeIntervalSince1970)
            try database.run("UPDATE work_tasks SET status=?,suggested_status=NULL,updated_at=?,confirmed_at=coalesce(confirmed_at,?),completed_at=?,waiting_reason=coalesce(?,waiting_reason) WHERE id=?",
                [status.rawValue, time, status.isConfirmed ? time : nil, status == .done ? time : nil, status == .done ? "" : nil, id.uuidString])
            try recordWorkTaskEvent(id, from: previous, to: status, at: date)
        }
    }

    public func workTaskEvents(_ id: UUID? = nil) throws -> [WorkTaskEvent] {
        try database.run("SELECT * FROM work_task_events" + (id == nil ? "" : " WHERE task_id=?") + " ORDER BY created_at,rowid", id.map { [$0.uuidString] } ?? []).map { row in
            guard let eventID = row["id"].flatMap(UUID.init(uuidString:)), let taskID = row["task_id"].flatMap(UUID.init(uuidString:)),
                  let to = row["to_status"].flatMap(WorkTaskStatus.init(rawValue:)) else { throw LibraryError.database("任务历史格式错误。") }
            return WorkTaskEvent(id: eventID, taskID: taskID, from: row["from_status"].flatMap(WorkTaskStatus.init(rawValue:)), to: to,
                date: Date(timeIntervalSince1970: Double(row["created_at"] ?? "0") ?? 0))
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
        guard !title.isEmpty, title.count <= 240, project.count <= 120 else { throw LibraryError.invalidResult("任务名称不能为空且最多 240 字，项目名称最多 120 字。") }
        func normalize(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return (title, project, memoryHash(normalize(project) + "\n" + normalize(title)))
    }

    private static func taskIDsJSON(_ ids: Set<UUID>) throws -> String {
        String(decoding: try JSONEncoder().encode(ids.sorted { $0.uuidString < $1.uuidString }), as: UTF8.self)
    }

    private func insertWorkTask(id: UUID, title: String, project: String, identity: String, status: WorkTaskStatus, at date: Date) throws {
        let time = String(date.timeIntervalSince1970)
        try database.run("INSERT INTO work_tasks(id,identity,title,project,status,created_at,updated_at,confirmed_at) VALUES(?,?,?,?,?,?,?,?)", [id.uuidString, identity, title, project, status.rawValue, time, time, status.isConfirmed ? time : nil])
        try recordWorkTaskEvent(id, from: nil, to: status, at: date)
    }

    private func recordWorkTaskEvent(_ id: UUID, from: WorkTaskStatus?, to: WorkTaskStatus, at date: Date) throws {
        try database.run("INSERT INTO work_task_events VALUES(?,?,?,?,?)", [UUID().uuidString, id.uuidString, from?.rawValue, to.rawValue, String(date.timeIntervalSince1970)])
    }
}
