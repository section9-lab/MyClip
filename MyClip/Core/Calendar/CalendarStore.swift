import Foundation

extension LibraryStore {
    /// Project dated Memory passages into calendar events. Only events that have not ended yet are imported:
    /// the calendar is a scheduling surface, not a second history view. Writes are idempotent per occurrence.
    @discardableResult
    public func synchronizeCalendarEvents(now: Date = Date(), calendar: Calendar = .current) throws -> Int {
        let today = calendar.startOfDay(for: now)
        guard let horizon = calendar.date(byAdding: .day, value: 365, to: today) else { return 0 }
        let rows = try database.run("""
            SELECT DISTINCT entry_id FROM memory_passages
            WHERE event_start IS NOT NULL AND event_end IS NOT NULL AND event_end >= ? AND event_start <= ?
            """, [String(today.timeIntervalSince1970), String(horizon.timeIntervalSince1970)])
        var changed = 0
        for row in rows {
            guard let id = row["entry_id"].flatMap(UUID.init(uuidString:)),
                  let memory = try? readMemory(id) else { continue }
            for passage in MemoryPassage.parse(memory.body, sourceIDs: memory.sourceIDs) {
                guard let time = passage.eventTime, time.end >= today, time.start <= horizon else { continue }
                let evidence = String(passage.text.prefix(1200)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !evidence.isEmpty else { continue }
                let title = Self.calendarTitle(from: passage.text, fallback: memory.title)
                if try upsertMemoryCalendarEvent(memory: memory, title: title, evidence: evidence, time: time, at: now) {
                    changed += 1
                }
            }
        }
        return changed
    }

    public func calendarEvents() throws -> [CalendarEvent] {
        try database.run("""
            SELECT c.*, f.path AS memory_path FROM calendar_events c
            LEFT JOIN memory_files f ON f.id = c.memory_id
            WHERE c.state = 'scheduled'
            """).compactMap(calendarEvent).sorted(by: CalendarLayout.sort)
    }

    @discardableResult
    public func createCalendarEvent(_ draft: CalendarEventDraft, at date: Date = Date(), calendar: Calendar = .current) throws -> UUID {
        let fields = try Self.calendarFields(draft, calendar: calendar)
        let id = UUID()
        try database.run("""
            INSERT INTO calendar_events(id,title,notes,location,project,kind,start_at,end_at,is_all_day,state,origin,evidence,edited_at,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,'scheduled','user','',NULL,?,?)
            """, [id.uuidString, fields.title, fields.notes, fields.location, fields.project, draft.kind.rawValue,
                   String(fields.start.timeIntervalSince1970), String(fields.end.timeIntervalSince1970),
                   fields.isAllDay ? "1" : "0", String(date.timeIntervalSince1970), String(date.timeIntervalSince1970)])
        return id
    }

    public func updateCalendarEvent(_ id: UUID, _ draft: CalendarEventDraft, at date: Date = Date(), calendar: Calendar = .current) throws {
        let fields = try Self.calendarFields(draft, calendar: calendar)
        guard try database.run("SELECT id FROM calendar_events WHERE id=?", [id.uuidString]).first != nil else {
            throw LibraryError.invalidResult(String(localized: "日程不存在。"))
        }
        try database.run("""
            UPDATE calendar_events SET title=?,notes=?,location=?,project=?,kind=?,start_at=?,end_at=?,is_all_day=?,
                edited_at=?,updated_at=? WHERE id=?
            """, [fields.title, fields.notes, fields.location, fields.project, draft.kind.rawValue,
                   String(fields.start.timeIntervalSince1970), String(fields.end.timeIntervalSince1970),
                   fields.isAllDay ? "1" : "0", String(date.timeIntervalSince1970), String(date.timeIntervalSince1970), id.uuidString])
    }

    /// Removing an AI event keeps a dismissal marker, so the next synchronization does not bring it back.
    public func dismissCalendarEvent(_ id: UUID, at date: Date = Date()) throws {
        guard try database.run("SELECT id FROM calendar_events WHERE id=?", [id.uuidString]).first != nil else {
            throw LibraryError.invalidResult(String(localized: "日程不存在。"))
        }
        try database.run("UPDATE calendar_events SET state='dismissed',updated_at=? WHERE id=?",
                         [String(date.timeIntervalSince1970), id.uuidString])
    }

    private func upsertMemoryCalendarEvent(memory: KnowledgeEntry, title: String, evidence: String,
                                           time: MemoryEventTime, at date: Date) throws -> Bool {
        let isAllDay = time.precision == "day"
        let candidates = try database.run("""
            SELECT c.*, f.path AS memory_path FROM calendar_events c
            LEFT JOIN memory_files f ON f.id = c.memory_id
            WHERE c.origin = 'memory' AND c.memory_id = ?
            """, [memory.id.uuidString]).compactMap(calendarEvent)
        // A passage keeps its verbatim text across title/date edits, so evidence identifies the occurrence first.
        // The nearest start within 36 hours covers an agent rewriting the line while the event stays the same day.
        let match = candidates.first { $0.evidence == evidence }
            ?? candidates.min { abs($0.start.timeIntervalSince(time.start)) < abs($1.start.timeIntervalSince(time.start)) }
        if let match, match.evidence == evidence || abs(match.start.timeIntervalSince(time.start)) <= 36 * 3600 {
            guard match.state == .scheduled, !match.edited else { return false }
            guard match.title != title || match.start != time.start || match.end != time.end
                    || match.isAllDay != isAllDay || match.evidence != evidence else { return false }
            try database.run("""
                UPDATE calendar_events SET title=?,start_at=?,end_at=?,is_all_day=?,evidence=?,updated_at=? WHERE id=?
                """, [title, String(time.start.timeIntervalSince1970), String(time.end.timeIntervalSince1970),
                       isAllDay ? "1" : "0", evidence, String(date.timeIntervalSince1970), match.id.uuidString])
            return true
        }
        try database.run("""
            INSERT INTO calendar_events(id,title,notes,location,project,kind,start_at,end_at,is_all_day,state,origin,evidence,memory_id,edited_at,created_at,updated_at)
            VALUES(?,?,'','','','other',?,?,?,'scheduled','memory',?,?,NULL,?,?)
            """, [UUID().uuidString, title, String(time.start.timeIntervalSince1970), String(time.end.timeIntervalSince1970),
                   isAllDay ? "1" : "0", evidence, memory.id.uuidString,
                   String(date.timeIntervalSince1970), String(date.timeIntervalSince1970)])
        return true
    }

    /// One scheduled event by id, so an agent can update or remove exactly the event it listed.
    public func calendarEvent(id: UUID) throws -> CalendarEvent? {
        try database.run("""
            SELECT c.*, f.path AS memory_path FROM calendar_events c
            LEFT JOIN memory_files f ON f.id = c.memory_id
            WHERE c.id = ? AND c.state = 'scheduled'
            """, [id.uuidString]).first.flatMap(calendarEvent)
    }

    /// An agent's edit of an existing event. Only the fields it passes change; everything else keeps its value.
    /// The edit pins the event (`edited_at`), so Memory projection will not revert what the digest decided.
    @discardableResult
    public func updateCalendarEventFromAgent(_ id: UUID, title: String? = nil, start: Date? = nil, end: Date? = nil,
                                             allDay: Bool? = nil, kind: CalendarEventKind? = nil, location: String? = nil,
                                             project: String? = nil, at date: Date = Date()) throws -> UUID {
        guard let existing = try calendarEvent(id: id) else { throw LibraryError.invalidResult(String(localized: "日程不存在。")) }
        var draft = CalendarEventDraft(event: existing)
        if let title { draft.title = title }
        if let start { draft.start = start }
        if let end { draft.end = end }
        if let allDay { draft.isAllDay = allDay }
        if let kind { draft.kind = kind }
        if let location { draft.location = location }
        if let project { draft.project = project }
        try updateCalendarEvent(id, draft, at: date)
        return id
    }

    /// An agent's calendar write, from the hourly digest. It is an upsert keyed the same way as the Memory
    /// projection (memory + the supporting line, with the nearest start within 36 hours as a fallback), so the same
    /// fact can never become two events. A user edit pins the event and a dismissal stays dismissed.
    @discardableResult
    public func saveCalendarEvent(fromAgent memory: KnowledgeEntry, title: String, evidence: String,
                                  kind: CalendarEventKind, location: String, project: String,
                                  start: Date, end: Date, isAllDay: Bool, at date: Date = Date()) throws -> UUID {
        let fields = try Self.calendarFields(
            CalendarEventDraft(title: title, location: location, project: project, kind: kind, start: start, end: end, isAllDay: isAllDay),
            calendar: .current)
        let quote = String(evidence.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
        let candidates = try database.run("""
            SELECT c.*, f.path AS memory_path FROM calendar_events c
            LEFT JOIN memory_files f ON f.id = c.memory_id
            WHERE c.origin = 'memory' AND c.memory_id = ?
            """, [memory.id.uuidString]).compactMap(calendarEvent)
        let match = candidates.first { $0.evidence == quote }
            ?? candidates.min { abs($0.start.timeIntervalSince(fields.start)) < abs($1.start.timeIntervalSince(fields.start)) }
        if let match, match.evidence == quote || abs(match.start.timeIntervalSince(fields.start)) <= 36 * 3600 {
            guard match.state == .scheduled, !match.edited else { return match.id }
            try database.run("""
                UPDATE calendar_events SET title=?,notes=?,location=?,project=?,kind=?,start_at=?,end_at=?,is_all_day=?,
                    evidence=?,updated_at=? WHERE id=?
                """, [fields.title, fields.notes, fields.location, fields.project, kind.rawValue,
                       String(fields.start.timeIntervalSince1970), String(fields.end.timeIntervalSince1970),
                       fields.isAllDay ? "1" : "0", quote, String(date.timeIntervalSince1970), match.id.uuidString])
            return match.id
        }
        let id = UUID()
        try database.run("""
            INSERT INTO calendar_events(id,title,notes,location,project,kind,start_at,end_at,is_all_day,state,origin,evidence,memory_id,edited_at,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,'scheduled','memory',?,?,NULL,?,?)
            """, [id.uuidString, fields.title, fields.notes, fields.location, fields.project, kind.rawValue,
                   String(fields.start.timeIntervalSince1970), String(fields.end.timeIntervalSince1970),
                   fields.isAllDay ? "1" : "0", quote, memory.id.uuidString,
                   String(date.timeIntervalSince1970), String(date.timeIntervalSince1970)])
        return id
    }

    private func calendarEvent(_ row: [String: String]) -> CalendarEvent? {
        guard let id = row["id"].flatMap(UUID.init(uuidString:)),
              let title = row["title"],
              let start = row["start_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
              let end = row["end_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) else { return nil }
        return CalendarEvent(
            id: id, title: title,
            notes: row["notes"] ?? "", location: row["location"] ?? "", project: row["project"] ?? "",
            kind: row["kind"].flatMap(CalendarEventKind.init(rawValue:)) ?? .other,
            start: start, end: end, isAllDay: row["is_all_day"] == "1",
            state: row["state"].flatMap(CalendarEventState.init(rawValue:)) ?? .scheduled,
            origin: row["origin"].flatMap(CalendarEventOrigin.init(rawValue:)) ?? .user,
            evidence: row["evidence"] ?? "",
            memoryID: row["memory_id"].flatMap(UUID.init(uuidString:)),
            memoryPath: row["memory_path"],
            taskID: row["task_id"].flatMap(UUID.init(uuidString:)),
            edited: row["edited_at"] != nil)
    }

    private static func calendarFields(_ draft: CalendarEventDraft, calendar: Calendar) throws
        -> (title: String, notes: String, location: String, project: String, start: Date, end: Date, isAllDay: Bool) {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 240 else {
            throw LibraryError.invalidResult(String(localized: "日程名称不能为空且最多 240 字。"))
        }
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard notes.count <= 2_000 else { throw LibraryError.invalidResult(String(localized: "备注最多 2000 字。")) }
        let location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard location.count <= 200 else { throw LibraryError.invalidResult(String(localized: "地点最多 200 字。")) }
        let project = draft.project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard project.count <= 120 else { throw LibraryError.invalidResult(String(localized: "项目名称最多 120 字。")) }
        var start = draft.start, end = draft.end
        if draft.isAllDay {
            start = calendar.startOfDay(for: start)
            end = calendar.startOfDay(for: end)
            if end <= start { end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400) }
        }
        guard end > start else { throw LibraryError.invalidResult(String(localized: "结束时间必须晚于开始时间。")) }
        guard end.timeIntervalSince(start) <= 366 * 86_400 else { throw LibraryError.invalidResult(String(localized: "日程最长 366 天。")) }
        return (title, notes, location, project, start, end, draft.isAllDay)
    }

    /// Use the passage's own first line as the event name. Memory lines already read as short statements;
    /// citations, list markers and emphasis are presentation, not part of the name.
    static func calendarTitle(from text: String, fallback: String) -> String {
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("<!--") else { continue }
            line = line.replacingOccurrences(of: #"^[#>\-\*\+•]+\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\s*(?:来源|sources?)\s*[：:].*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Memory keeps one fact per line; the first sentence is the event name, the rest is context.
            if let stop = line.firstIndex(where: { "。！？".contains($0) }),
               line.distance(from: line.startIndex, to: stop) >= 4 {
                line = String(line[..<stop])
            }
            guard !line.isEmpty else { continue }
            return String(line.prefix(120))
        }
        return String(fallback.prefix(120))
    }
}
