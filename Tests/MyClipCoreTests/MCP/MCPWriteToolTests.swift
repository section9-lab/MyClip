import XCTest
@testable import MyClipCore

/// The write half of the MyClip MCP server: only the sessions MyClip launches may call it, and both tools are upserts.
@MainActor
final class MCPWriteToolTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func reply(_ server: MemoryMCP, _ json: String) async throws -> String {
        let response = await server.respond(json)
        return try XCTUnwrap(response)
    }

    private func initialize(_ server: MemoryMCP) async throws {
        _ = try await reply(server, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}")
    }

    private func call(_ server: MemoryMCP, _ name: String, _ arguments: String) async throws -> String {
        try await reply(server, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"\(name)\",\"arguments\":\(arguments)}}")
    }

    func testWriteToolsAreOnlyListedForWritableServers() async throws {
        let store = try LibraryStore(root: root)
        let readOnly = MemoryMCP(store: store)
        try await initialize(readOnly)
        let readTools = try await reply(readOnly, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")
        XCTAssertFalse(readTools.contains("calendar_add"))
        XCTAssertFalse(readTools.contains("board_add"))

        let writable = MemoryMCP(store: store, writable: true)
        try await initialize(writable)
        let tools = try await reply(writable, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")
        for name in ["board_add", "calendar_add", "calendar_list"] {
            XCTAssertTrue(tools.contains(name), name)
        }
        let instructions = try await reply(writable, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"initialize\"}")
        XCTAssertTrue(instructions.contains("board_add"), "A writable session is told what the tools are for")
    }

    func testCalendarAddReschedulesTheSameLineInsteadOfDuplicating() async throws {
        let store = try LibraryStore(root: root)
        let now = try await store.readMemory(path: "Now.md")
        let fact = "10 月 28 日下午 3 点在会议室开周会，需要到场。"
        try await store.updateEntry(id: now.id, title: now.title, body: "# Now\n\n## 下一步\n- \(fact)\n", expectedRevision: now.revision)

        let server = MemoryMCP(store: store, writable: true)
        try await initialize(server)
        let arguments = """
        {"path":"Now.md","evidence":"\(fact)","title":"周会","start":"2026-10-28T15:00:00+08:00","end":"2026-10-28T16:00:00+08:00","kind":"meeting"}
        """
        let first = try await call(server, "calendar_add", arguments)
        XCTAssertTrue(first.contains("\"isError\":false"), first)
        var events = try await store.calendarEvents()
        XCTAssertEqual(events.count, 1)

        let moved = arguments
            .replacingOccurrences(of: "T15:00:00", with: "T17:00:00")
            .replacingOccurrences(of: "T16:00:00", with: "T18:00:00")
        let second = try await call(server, "calendar_add", moved)
        XCTAssertTrue(second.contains("\"isError\":false"), second)
        events = try await store.calendarEvents()
        XCTAssertEqual(events.count, 1, "Quoting the same line reschedules the one event")
        XCTAssertEqual(events[0].kind, .meeting)
        XCTAssertEqual(events[0].memoryPath, "Now.md")

        let listed = try await call(server, "calendar_list", "{}")
        XCTAssertTrue(listed.contains("\"events\""))
        XCTAssertTrue(listed.contains("周会"))
    }

    func testDismissedEventIsNotBroughtBack() async throws {
        let store = try LibraryStore(root: root)
        let now = try await store.readMemory(path: "Now.md")
        let fact = "11 月 2 日外出到银行办事。"
        try await store.updateEntry(id: now.id, title: now.title, body: "# Now\n\n- \(fact)\n", expectedRevision: now.revision)
        let server = MemoryMCP(store: store, writable: true)
        try await initialize(server)
        let arguments = """
        {"path":"Now.md","evidence":"\(fact)","start":"2026-11-02T09:00:00+08:00","end":"2026-11-02T11:00:00+08:00","kind":"travel"}
        """
        _ = try await call(server, "calendar_add", arguments)
        let drafts = try await store.calendarEvents()
        let created = try XCTUnwrap(drafts.first)
        try await store.dismissCalendarEvent(created.id)

        _ = try await call(server, "calendar_add", arguments)
        let remaining = try await store.calendarEvents()
        XCTAssertTrue(remaining.isEmpty, "A dismissed event stays dismissed")
    }

    func testBoardAddWritesOneCardWithItsEvidence() async throws {
        let store = try LibraryStore(root: root)
        let now = try await store.readMemory(path: "Now.md")
        let fact = "准备周三评审的材料。"
        try await store.updateEntry(id: now.id, title: now.title, body: "# Now\n\n- \(fact)\n", expectedRevision: now.revision)
        let server = MemoryMCP(store: store, writable: true)
        try await initialize(server)
        let arguments = "{\"title\":\"准备周三评审材料\",\"project\":\"MyClip\",\"path\":\"Now.md\",\"evidence\":\"\(fact)\"}"
        let response = try await call(server, "board_add", arguments)
        XCTAssertTrue(response.contains("\"isError\":false"), response)
        var tasks = try await store.workTasks()
        XCTAssertEqual(tasks.map(\.title), ["准备周三评审材料"])
        XCTAssertEqual(tasks.first?.status, .todo)

        // The same work quoted again updates the card instead of adding a second one.
        _ = try await call(server, "board_add", arguments)
        tasks = try await store.workTasks()
        XCTAssertEqual(tasks.count, 1)
    }

    /// The board tool answers are JSON-RPC envelopes; the payload sits in the first text content block.
    private func payload(_ response: String) throws -> [String: Any] {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testBoardUpdateAndDeleteMoveTheSameCard() async throws {
        let store = try LibraryStore(root: root)
        let now = try await store.readMemory(path: "Now.md")
        let fact = "准备周三评审的材料。"
        try await store.updateEntry(id: now.id, title: now.title, body: "# Now\n\n- \(fact)\n", expectedRevision: now.revision)
        let server = MemoryMCP(store: store, writable: true)
        try await initialize(server)

        _ = try await call(server, "board_add", "{\"title\":\"准备评审材料\",\"path\":\"Now.md\",\"evidence\":\"\(fact)\"}")
        let listed = try await call(server, "board_list", "{}")
        let board = try payload(listed)
        let cards = try XCTUnwrap(board["tasks"] as? [[String: Any]])
        let id = try XCTUnwrap(cards.first?["id"] as? String)

        let updated = try await call(server, "board_update", "{\"id\":\"\(id)\",\"status\":\"doing\",\"title\":\"准备周三评审材料\"}")
        XCTAssertTrue(updated.contains("\"isError\":false"), updated)
        var tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.status, .doing)
        XCTAssertEqual(tasks.first?.title, "准备周三评审材料")

        let deleted = try await call(server, "board_delete", "{\"id\":\"\(id)\"}")
        XCTAssertTrue(deleted.contains("\"isError\":false"), deleted)
        tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.status, .ignored, "A deleted card keeps its evidence but leaves the board")
        let remaining = try await call(server, "board_list", "{}")
        XCTAssertFalse(remaining.contains("准备周三评审材料"), "board_list omits ignored cards")
    }

    func testCalendarUpdateAndDeleteUseTheListedId() async throws {
        let store = try LibraryStore(root: root)
        let now = try await store.readMemory(path: "Now.md")
        let fact = "10 月 28 日下午 3 点在会议室开周会。"
        try await store.updateEntry(id: now.id, title: now.title, body: "# Now\n\n- \(fact)\n", expectedRevision: now.revision)
        let server = MemoryMCP(store: store, writable: true)
        try await initialize(server)
        _ = try await call(server, "calendar_add", "{\"path\":\"Now.md\",\"evidence\":\"\(fact)\",\"title\":\"周会\",\"start\":\"2026-10-28T15:00:00+08:00\",\"end\":\"2026-10-28T16:00:00+08:00\",\"kind\":\"meeting\"}")
        let created = try await store.calendarEvents()
        let id = try XCTUnwrap(created.first?.id).uuidString

        let moved = try await call(server, "calendar_update", "{\"id\":\"\(id)\",\"start\":\"2026-10-28T17:00:00+08:00\",\"end\":\"2026-10-28T18:00:00+08:00\",\"location\":\"会议室 B\"}")
        XCTAssertTrue(moved.contains("\"isError\":false"), moved)
        let listed = try await store.calendarEvents()
        let updated = try XCTUnwrap(listed.first)
        XCTAssertEqual(updated.start, try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-28T09:00:00Z")))
        XCTAssertEqual(updated.location, "会议室 B")

        let removed = try await call(server, "calendar_delete", "{\"id\":\"\(id)\"}")
        XCTAssertTrue(removed.contains("\"isError\":false"), removed)
        let remaining = try await store.calendarEvents()
        XCTAssertTrue(remaining.isEmpty, "A cancelled event leaves the calendar")
        // The line is still in Memory, so projection must not bring the event back.
        try await store.synchronizeCalendarEvents()
        let afterProjection = try await store.calendarEvents()
        XCTAssertTrue(afterProjection.isEmpty)
    }

    func testWriteToolsRejectArgumentsFromAnotherPage() async throws {
        let store = try LibraryStore(root: root)
        let server = MemoryMCP(store: store, writable: true)
        try await initialize(server)
        let response = try await call(server, "board_add", "{\"title\":\"偷来的任务\",\"path\":\"Wiki/不存在.md\",\"evidence\":\"依据\"}")
        XCTAssertTrue(response.contains("\"isError\":true"), response)
        let tasks = try await store.workTasks()
        XCTAssertTrue(tasks.isEmpty)
    }
}
