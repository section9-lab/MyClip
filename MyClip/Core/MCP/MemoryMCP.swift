import Foundation

public actor MemoryMCP {
    private let store: LibraryStore
    private let writable: Bool
    private var initialized = false
    /// `writable` is only set for sessions MyClip launches itself (the organizing agent). The copy installed into
    /// other clients stays read-only, so no external tool can edit the board or the calendar.
    public init(store: LibraryStore, writable: Bool = false) {
        self.store = store
        self.writable = writable
    }

    public static func isEnabled(in root: URL) -> Bool {
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("MCP.disabled").path)
    }

    public static func setEnabled(_ enabled: Bool, in root: URL) throws {
        let marker = root.appendingPathComponent("MCP.disabled")
        if enabled {
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        } else {
            try Data().write(to: marker, options: .atomic)
        }
    }

    public static func run(arguments: [String]) async {
        do {
            let index = arguments.firstIndex(of: "--library")
            let root = index.flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyClip")
            let service = MemoryMCP(store: try LibraryStore(root: root), writable: arguments.contains("--write-tools"))
            while let line = readLine() {
                if let response = await service.respond(line) {
                    try FileHandle.standardOutput.write(contentsOf: Data((response + "\n").utf8))
                }
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
        }
    }

    /// Characters of each root file quoted at connection time.
    static let digestFileLimit = 800

    /// Who the user is and what they are working on, so an answer can use it without first deciding to search.
    /// Taken once per connection; empty when both files are still the seeded templates or cannot be read.
    func contextDigest() async -> String {
        // A disabled server shares nothing, the digest included.
        guard Self.isEnabled(in: store.root) else { return "" }
        var parts: [String] = []
        for path in ["Profile.md", "Now.md"] {
            // Revision 1 is the seeded template, whichever language it was written in.
            guard let memory = try? await store.readMemory(path: path), memory.revision > 1 else { continue }
            let text = Self.digestText(memory.body, template: MemoryLayout.initialBody(for: path))
            guard !text.isEmpty else { continue }
            let observed = memory.observedAt.map { "observedAt=\($0.ISO8601Format())" } ?? "observedAt unknown"
            parts.append("--- \(path) (\(observed)) ---\n\(text)")
        }
        guard !parts.isEmpty else { return "" }
        return MCPPrompt.digestIntroduction + parts.joined(separator: "\n")
    }

    static func digestText(_ body: String, template: String?) -> String {
        let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != template?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
        let lines = MemoryDocument.displayMarkdown(normalized).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("<!-- myclip-event ") }
        var result = ""
        for line in lines {
            guard result.count + line.count + 1 <= digestFileLimit else { return (result.isEmpty ? String(line.prefix(digestFileLimit)) : result) + "…" }
            result += (result.isEmpty ? "" : "\n") + line
        }
        return result
    }

    public func respond(_ line: String) async -> String? {
        var id: Any = NSNull()
        do {
            guard line.utf8.count <= 2_000_000, let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
                return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "Invalid request"]])
            }
            guard let requestID = request["id"] else { return nil }
            id = requestID
            let params = request["params"] as? [String: Any] ?? [:]
            var result: [String: Any]
            switch method {
            case "initialize":
                initialized = true
                let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
                let requested = params["protocolVersion"] as? String ?? ""
                result = ["protocolVersion": supported.contains(requested) ? requested : "2025-11-25",
                          "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "myclip", "version": "0.5.0"],
                          "instructions": MCPPrompt.instructions(writable: writable) + (await contextDigest())]
            case "ping": result = [:]
            case "tools/list" where initialized: result = ["tools": MCPPrompt.tools(writable: writable)]
            case "tools/call" where initialized:
                guard let name = params["name"] as? String, names.contains(name), let arguments = params["arguments"] as? [String: Any] else {
                    return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool or invalid arguments"]])
                }
                do {
                    result = try await call(name, arguments)
                    try await store.recordMCPRead(name)
                } catch {
                    result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
                }
            default:
                return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": initialized ? "Method not found" : "Initialize first"]])
            }
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32700, "message": "Parse error"]])
        }
    }

    private func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        guard Self.isEnabled(in: store.root) else { throw LibraryError.invalidResult("MyClip MCP 已关闭。请在 MyClip 设置中开启记忆访问。") }
        let accepted: Set<String>
        switch name {
        case "memory_search": accepted = ["query", "since", "until", "app", "limit"]
        case "memory_get": accepted = ["path", "from", "lines"]
        case "board_list": accepted = ["status"]
        case "board_add": accepted = ["title", "project", "status", "path", "evidence"]
        case "board_update": accepted = ["id", "title", "project", "status"]
        case "board_delete": accepted = ["id"]
        case "calendar_list": accepted = ["from", "to"]
        case "calendar_add": accepted = ["title", "start", "end", "allDay", "kind", "location", "project", "path", "evidence"]
        case "calendar_update": accepted = ["id", "title", "start", "end", "allDay", "kind", "location", "project"]
        case "calendar_delete": accepted = ["id"]
        default: throw LibraryError.invalidResult("未知工具：\(name)。")
        }
        // Unknown arguments (including ones earlier versions accepted) are errors, not silently ignored filters.
        if let unknown = args.keys.sorted().first(where: { !accepted.contains($0) }) {
            throw LibraryError.invalidResult("不支持的参数：\(unknown)。可用参数：\(accepted.sorted().joined(separator: ", "))。")
        }
        let value: [String: Any]
        if name == "memory_search" {
            guard let query = args["query"] as? String, query.count <= 1000 else { throw LibraryError.invalidResult("query 必须是字符串，最多 1000 字。") }
            func date(_ key: String) throws -> Date? {
                guard let value = args[key] else { return nil }
                guard let text = value as? String else { throw LibraryError.invalidResult("\(key) 必须是 ISO 8601 时间。") }
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: text) { return date }
                formatter.formatOptions.insert(.withFractionalSeconds)
                guard let date = formatter.date(from: text) else { throw LibraryError.invalidResult("\(key) 必须是 ISO 8601 时间。") }
                return date
            }
            let hits = try await store.memorySearch(query: query, limit: args["limit"] as? Int ?? 10, since: date("since"), until: date("until"), app: args["app"] as? String)
            var results: [[String: Any]] = []
            for hit in hits {
                let cited = Array(Set(hit.passages.flatMap(\.sourceIDs))).sorted { $0.uuidString < $1.uuidString }
                var item: [String: Any] = ["path": hit.memory.relativePath, "title": hit.memory.title,
                                           "snippet": hit.passages.map(\.text).joined(separator: "\n…\n"),
                                           "time": Self.time(hit.memory, passages: hit.passages) as Any? ?? NSNull(),
                                           "sourceIDs": cited.map(\.uuidString)]
                let apps = try await store.sourceApps(cited.isEmpty ? hit.memory.sourceIDs : cited)
                if !apps.isEmpty { item["apps"] = Array(apps.prefix(3)) }
                if !hit.via.isEmpty { item["via"] = hit.via.map(Self.hop) }
                if !hit.links.isEmpty { item["links"] = hit.links }
                results.append(item)
            }
            value = ["results": results]
        } else if name == "memory_get" {
            guard let raw = args["path"] as? String, !raw.isEmpty else { throw LibraryError.invalidResult("请提供 path，例如 Wiki/Projects/MyClip.md 或 Wiki/Projects/MyClip.md#当前状态。") }
            let heading = raw.firstIndex(of: "#").map { String(raw[raw.index(after: $0)...]) }
            let path = raw.firstIndex(of: "#").map { String(raw[..<$0]) } ?? raw
            let entry = try await store.readMemory(path: path)
            let text: String
            if let heading, !heading.isEmpty {
                guard let section = entry.section(heading) else { throw LibraryError.invalidResult("没有找到标题“\(heading)”。") }
                text = section
            } else { text = entry.body }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let from = min(max(args["from"] as? Int ?? 1, 1), max(lines.count, 1))
            let count = min(max(args["lines"] as? Int ?? 200, 1), 2000)
            let slice = lines.dropFirst(from - 1).prefix(count)
            let next = from - 1 + slice.count < lines.count ? from + slice.count : nil
            let neighborhood = try await store.memoryNeighborhood(entry.id)
            let sources = try await store.sourceSummary(entry.id)
            var sections: [String] = [], grouped: [String: [[String: Any]]] = [:]
            for link in neighborhood.links {
                if grouped[link.section] == nil { sections.append(link.section) }
                grouped[link.section, default: []].append(Self.edge(link))
            }
            value = ["path": entry.relativePath, "title": entry.title, "updatedAt": entry.updatedAt.ISO8601Format(),
                     "observedAt": entry.observedAt?.ISO8601Format() as Any? ?? NSNull(),
                     "content": slice.joined(separator: "\n"), "from": from, "nextFrom": next as Any? ?? NSNull(), "totalLines": lines.count,
                     "links": sections.map { ["section": $0, "links": grouped[$0]!] },
                     "backlinks": neighborhood.backlinks.map(Self.edge),
                     "sources": ["count": sources.count, "earliest": sources.earliest?.ISO8601Format() as Any? ?? NSNull(),
                                 "latest": sources.latest?.ISO8601Format() as Any? ?? NSNull(),
                                 "apps": sources.apps.prefix(10).map { ["name": $0.name, "count": $0.count] }]]
        } else if name == "board_list" {
            value = try await boardList(args)
        } else if name == "board_add" {
            value = try await boardAdd(args)
        } else if name == "board_update" {
            value = try await boardUpdate(args)
        } else if name == "board_delete" {
            value = try await boardDelete(args)
        } else if name == "calendar_list" {
            value = try await calendarList(args)
        } else if name == "calendar_add" {
            value = try await calendarAdd(args)
        } else if name == "calendar_update" {
            value = try await calendarUpdate(args)
        } else {
            value = try await calendarDelete(args)
        }
        return ["content": [["type": "text", "text": encode(value) ?? "{}"]], "structuredContent": value, "isError": false]
    }

    /// When the content happened: the earliest annotated event among the returned passages, else the latest cited screenshot.
    private static func time(_ entry: KnowledgeEntry, passages: [MemoryPassage]) -> String? {
        passages.compactMap(\.eventTime?.start).min()?.ISO8601Format() ?? entry.observedAt?.ISO8601Format()
    }

    /// Edge dates are days in the user's time zone (a Daily path or an annotated event), so they print as local dates.
    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func hop(_ hop: MemoryHop) -> [String: Any] {
        var result: [String: Any] = ["page": hop.page, "fact": hop.fact]
        if !hop.section.isEmpty { result["section"] = hop.section }
        if let date = hop.date { result["date"] = day(date) }
        return result
    }

    private static func edge(_ edge: MemoryEdgeView) -> [String: Any] {
        var result: [String: Any] = ["page": edge.page, "title": edge.title, "fact": edge.fact]
        if !edge.section.isEmpty { result["section"] = edge.section }
        if let date = edge.date { result["date"] = day(date) }
        return result
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }


    // MARK: - Write tools

    /// What is already on the board, so the digest can rename or move a card instead of adding a duplicate.
    private func boardList(_ args: [String: Any]) async throws -> [String: Any] {
        let filter = (args["status"] as? String).flatMap(WorkTaskStatus.init(rawValue:))
        let tasks = try await store.workTasks().filter { filter == nil ? $0.status != .ignored : $0.status == filter }
        let items = tasks.prefix(200).map { task -> [String: Any] in
            ["id": task.id.uuidString, "title": task.title, "project": task.project, "status": task.status.rawValue,
             "updatedAt": task.updatedAt.ISO8601Format()]
        }
        return ["tasks": items]
    }

    /// Renames a card, moves it to another project, or changes its column. The change is recorded as AI, so history
    /// still shows which side moved it.
    private func boardUpdate(_ args: [String: Any]) async throws -> [String: Any] {
        let id = try uuid(args, "id")
        let status: WorkTaskStatus?
        if let raw = args["status"] as? String {
            guard let parsed = WorkTaskStatus(rawValue: raw), parsed.isOnBoard else {
                throw LibraryError.invalidResult("status 只能是 todo、doing 或 done。")
            }
            status = parsed
        } else { status = nil }
        try await store.updateWorkTaskFromAgent(id, title: args["title"] as? String, project: args["project"] as? String, status: status)
        return ["id": id.uuidString, "status": status?.rawValue as Any? ?? NSNull()]
    }

    /// Takes a card off the board without losing its evidence: it moves to the ignored column, which a later ingestion
    /// will not silently revive.
    private func boardDelete(_ args: [String: Any]) async throws -> [String: Any] {
        let id = try uuid(args, "id")
        try await store.removeWorkTaskFromAgent(id)
        return ["id": id.uuidString, "status": WorkTaskStatus.ignored.rawValue]
    }

    /// An explicit agent edit of one event. Only the fields passed change; the edit pins the event so Memory
    /// projection does not revert it.
    private func calendarUpdate(_ args: [String: Any]) async throws -> [String: Any] {
        let id = try uuid(args, "id")
        let kind: CalendarEventKind?
        if let raw = args["kind"] as? String {
            guard let parsed = CalendarEventKind(rawValue: raw) else {
                throw LibraryError.invalidResult("kind 只能是 meeting、travel、deadline 或 other。")
            }
            kind = parsed
        } else { kind = nil }
        try await store.updateCalendarEventFromAgent(id, title: args["title"] as? String, start: try isoDate(args, "start"),
            end: try isoDate(args, "end"), allDay: args["allDay"] as? Bool, kind: kind,
            location: args["location"] as? String, project: args["project"] as? String)
        return ["id": id.uuidString]
    }

    /// Hides an event and remembers the decision, so neither Memory projection nor a later digest brings it back.
    private func calendarDelete(_ args: [String: Any]) async throws -> [String: Any] {
        let id = try uuid(args, "id")
        try await store.dismissCalendarEvent(id)
        return ["id": id.uuidString, "state": "dismissed"]
    }

    /// The agent's board write. It goes through the same ingestion as a task response, so identity, evidence and
    /// status rules hold; the page it quotes is the only allowed source.
    private func boardAdd(_ args: [String: Any]) async throws -> [String: Any] {
        let title = try text(args, "title"), path = try text(args, "path"), evidence = try text(args, "evidence")
        guard !title.isEmpty, title.count <= 240 else { throw LibraryError.invalidResult("title 不能为空且最多 240 字。") }
        guard !evidence.isEmpty, evidence.count <= 2400 else { throw LibraryError.invalidResult("evidence 必须是支持这条任务的原文，最多 2400 字。") }
        let status = WorkTaskStatus(rawValue: args["status"] as? String ?? "todo") ?? .todo
        guard status.isOnBoard else { throw LibraryError.invalidResult("status 只能是 todo、doing 或 done。") }
        let memory = try await store.readMemory(path: path)
        let project = (args["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let draft = WorkTaskDraft(title: title, project: project, suggestedStatus: status, evidence: evidence, memoryIDs: [memory.id])
        let changed = try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [], allowedMemoryIDs: [memory.id])
        return ["changed": changed, "path": memory.relativePath, "memoryID": memory.id.uuidString, "status": status.rawValue]
    }

    /// An upsert keyed by page and supporting line, so a digest that runs again over the same fact updates the event
    /// instead of adding a second one. Times are ISO 8601; `allDay` makes the day the unit and ignores the clock.
    private func calendarAdd(_ args: [String: Any]) async throws -> [String: Any] {
        let path = try text(args, "path"), evidence = try text(args, "evidence")
        guard !evidence.isEmpty, evidence.count <= 1200 else { throw LibraryError.invalidResult("evidence 必须是日程依据的原文，最多 1200 字。") }
        guard let start = try isoDate(args, "start") else { throw LibraryError.invalidResult("start 必须是 ISO 8601 时间。") }
        let allDay = args["allDay"] as? Bool ?? false
        let end = try isoDate(args, "end") ?? (allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start) : nil)
            ?? start.addingTimeInterval(1800)
        let kind = CalendarEventKind(rawValue: args["kind"] as? String ?? "other") ?? .other
        let memory = try await store.readMemory(path: path)
        let given = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = given.isEmpty ? LibraryStore.calendarTitle(from: evidence, fallback: memory.title) : String(given.prefix(240))
        let id = try await store.saveCalendarEvent(fromAgent: memory, title: title, evidence: evidence, kind: kind,
            location: (args["location"] as? String) ?? "", project: (args["project"] as? String) ?? "",
            start: start, end: end, isAllDay: allDay)
        return ["id": id.uuidString, "title": title, "start": start.ISO8601Format(), "end": end.ISO8601Format(),
                "allDay": allDay, "path": memory.relativePath]
    }

    /// What is already scheduled, so the digest does not create the same meeting twice.
    private func calendarList(_ args: [String: Any]) async throws -> [String: Any] {
        let from = try isoDate(args, "from"), to = try isoDate(args, "to")
        let events = try await store.calendarEvents().filter { event in
            (from.map { $0 < event.end } ?? true) && (to.map { $0 > event.start } ?? true)
        }
        let items = events.prefix(200).map { event -> [String: Any] in
            ["id": event.id.uuidString, "title": event.title, "start": event.start.ISO8601Format(),
             "end": event.end.ISO8601Format(), "allDay": event.isAllDay, "kind": event.kind.rawValue,
             "origin": event.origin.rawValue, "memoryPath": event.memoryPath as Any? ?? NSNull()]
        }
        return ["events": items]
    }

    private func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try text(args, key)) else {
            throw LibraryError.invalidResult("\(key) 必须是 calendar_list 或 board_list 返回的 id。")
        }
        return id
    }

    private func text(_ args: [String: Any], _ key: String) throws -> String {
        guard let raw = args[key] as? String else { throw LibraryError.invalidResult("请提供 \(key)。") }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isoDate(_ args: [String: Any], _ key: String) throws -> Date? {
        guard let raw = args[key] else { return nil }
        guard let value = raw as? String else { throw LibraryError.invalidResult("\(key) 必须是 ISO 8601 时间。") }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let date = formatter.date(from: value) else { throw LibraryError.invalidResult("\(key) 必须是 ISO 8601 时间。") }
        return date
    }

    private var names: [String] { Self.readNames + (writable ? Self.writeNames : []) }
    private static let readNames = ["memory_search", "memory_get"]
    private static let writeNames = ["board_list", "board_add", "board_update", "board_delete",
                                     "calendar_list", "calendar_add", "calendar_update", "calendar_delete"]
}

extension LibraryStore {
    func recordMCPRead(_ tool: String) throws {
        try database.run("INSERT INTO mcp_reads(tool,read_at) VALUES(?,?)", [tool, String(Date().timeIntervalSince1970)])
    }
}
