import XCTest
@testable import MyClipCore

@MainActor
final class MemoryLinkGraphTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func writeMemory(path: String, title: String, body: String, updatedAt: TimeInterval = 100) throws -> UUID {
        let id = UUID()
        let url = root.appendingPathComponent("Memory/\(path)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MemoryDocument.encode(id: id, title: title, body: body, revision: 1, agent: .codex, sourceIDs: [], path: path,
                                  updatedAt: Date(timeIntervalSince1970: updatedAt)).write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    private func service(_ store: LibraryStore) async -> (MemoryMCP, String) {
        let service = MemoryMCP(store: store)
        let reply = await service.respond("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}") ?? ""
        return (service, reply)
    }

    private func call(_ service: MemoryMCP, _ args: [String: Any], name: String = "search_memories") async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name, "arguments": args]])
        let raw = await service.respond(String(decoding: data, as: UTF8.self))
        let reply = try XCTUnwrap(raw)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    func testHeadingFragmentIsParsedRenderedAndPreservedOnRename() {
        let links = Wikilink.parse("见 [[Wiki/Projects/chat-bridge#查找JEV模型复刻|chat-bridge]] 与 [[Wiki/Projects/MyClip#路线图]] 和 [[Plain]]")
        XCTAssertEqual(links.map(\.target), ["Wiki/Projects/chat-bridge", "Wiki/Projects/MyClip", "Plain"])
        XCTAssertEqual(links.map(\.fragment), ["查找JEV模型复刻", "路线图", ""])
        XCTAssertEqual(links.map(\.label), ["chat-bridge", "Wiki/Projects/MyClip#路线图", "Plain"])
        XCTAssertEqual(links.map(\.hasLabel), [true, false, false])
        let rendered = Wikilink.markdown("[[Wiki/Projects/MyClip#路线图|计划]]")
        XCTAssertTrue(rendered.hasPrefix("[计划](myclip-memory:///Wiki/Projects/MyClip#"), rendered)
        let renamed = Wikilink.replacingTargets(in: "[[Old/Page#节|标签]] [[Old/Page#节]]", with: ["old/page": "New/Page"])
        XCTAssertEqual(renamed, "[[New/Page#节|标签]] [[New/Page#节]]")
    }

    func testAnchoredLinksResolveIntoEdgesWithFragmentAndPassage() async throws {
        let project = try writeMemory(path: "Wiki/Projects/chat-bridge.md", title: "chat-bridge", body: "# chat-bridge\n\n## 路由\n\n路由细节。")
        let daily = try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20",
                                    body: "上午处理邮件。\n\n15:13 讨论 JEV 复刻清单。详见 [[Wiki/Projects/chat-bridge#路由|chat-bridge]]。")
        let store = try LibraryStore(root: root)
        let relations = try await store.relations(daily)
        XCTAssertEqual(relations.outgoing.map(\.id), [project])
        XCTAssertTrue(relations.unresolved.isEmpty, "Heading fragments must not make a link unresolved")
        let edge = try XCTUnwrap(relations.outgoingEdges.first)
        XCTAssertEqual(edge.fragment, "路由")
        XCTAssertEqual(edge.label, "chat-bridge")
        XCTAssertEqual(edge.ordinal, 1)
        XCTAssertTrue(edge.passage.contains("JEV 复刻清单"))
        let backlinks = try await store.relations(project)
        XCTAssertEqual(backlinks.incoming.map(\.id), [daily])
        XCTAssertTrue(backlinks.incomingEdges.first?.passage.contains("JEV") == true)
    }

    func testLinkWrittenBeforeTargetResolvesWhenTargetAppears() async throws {
        let daily = try writeMemory(path: "Daily/2026/09/2026-09-21.md", title: "2026-09-21", body: "参考 [[Wiki/Topics/JEV|JEV 模型]]。")
        let store = try LibraryStore(root: root)
        let pending = try await store.relations(daily)
        XCTAssertEqual(pending.unresolved, ["Wiki/Topics/JEV"])
        let topic = try writeMemory(path: "Wiki/Topics/JEV.md", title: "JEV", body: "TypeSafe 提出的结构化输出模型。")
        let resolved = try await store.relations(daily)
        XCTAssertEqual(resolved.outgoing.map(\.id), [topic])
        XCTAssertTrue(resolved.unresolved.isEmpty)
        let incoming = try await store.relations(topic)
        XCTAssertEqual(incoming.incoming.map(\.id), [daily])
        try FileManager.default.removeItem(at: root.appendingPathComponent("Memory/Wiki/Topics/JEV.md"))
        let afterDelete = try await store.relations(daily)
        XCTAssertEqual(afterDelete.unresolved, ["Wiki/Topics/JEV"], "Deleting the target makes the edge unresolved again")
    }

    func testAnchorTextFromOtherMemoriesMakesTargetSearchable() async throws {
        let target = try writeMemory(path: "Wiki/Projects/MyClip.md", title: "MyClip", body: "截图整理应用。", updatedAt: 100)
        try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20", body: "今天继续做 [[Wiki/Projects/MyClip|记忆项目]] 的评测。", updatedAt: 200)
        let store = try LibraryStore(root: root)
        let found = try await store.searchMemories(query: "记忆项目")
        XCTAssertTrue(found.map(\.id).contains(target), "The label another note uses is an alias of the target")
        try await store.rebuildSearchIndex()
        let rebuilt = try await store.searchMemories(query: "记忆项目")
        XCTAssertTrue(rebuilt.map(\.id).contains(target), "Anchors survive a full index rebuild")
    }

    func testEnglishWordFormsMatchThroughStemming() async throws {
        let id = try writeMemory(path: "Wiki/Topics/Caroline.md", title: "Caroline", body: "Caroline is researching coral reefs this year.")
        let store = try LibraryStore(root: root)
        let stem = try await store.searchMemories(query: "research")
        XCTAssertEqual(stem.map(\.id), [id])
        let forms = try await store.searchMemories(query: "Researched reef")
        XCTAssertEqual(forms.map(\.id), [id])
    }

    func testArchivesAreExcludedFromMCPSearchUnlessRequested() async throws {
        let live = try writeMemory(path: "Wiki/Projects/chat-bridge.md", title: "chat-bridge", body: "JEV 路由方案。", updatedAt: 100)
        let archived = try writeMemory(path: "Wiki/Archives/Memory入口-2026-09-21.md", title: "Memory 入口历史快照", body: "旧目录提到 JEV 路由。", updatedAt: 200)
        let store = try LibraryStore(root: root)
        let (service, _) = await service(store)
        let page = try await call(service, ["query": "JEV"])
        XCTAssertEqual((page["memories"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [live.uuidString])
        let all = try await call(service, ["query": "JEV", "includeArchives": true])
        XCTAssertEqual(Set((all["memories"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []), [live.uuidString, archived.uuidString])
        let app = try await store.searchMemories(query: "JEV")
        XCTAssertEqual(app.count, 2, "The app keeps listing archives")
    }

    func testListingsCarryCountsAndReadMemoryReturnsContextOnRequest() async throws {
        let source = UUID(), context = UUID()
        let path = "Wiki/Topics/Notes.md"
        let url = root.appendingPathComponent("Memory/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MemoryDocument.encode(id: UUID(), title: "Notes", body: "编译失败。来源：截图 `\(source)`。", revision: 1, agent: .codex, sourceIDs: [source], path: path,
                                  contextSourceIDs: [context]).write(to: url, atomically: true, encoding: .utf8)
        let store = try LibraryStore(root: root)
        let (service, _) = await service(store)
        let page = try await call(service, ["query": "编译"])
        let hit = try XCTUnwrap((page["memories"] as? [[String: Any]])?.first)
        XCTAssertEqual(hit["sourceCount"] as? Int, 1)
        XCTAssertEqual(hit["contextSourceCount"] as? Int, 1)
        XCTAssertNil(hit["sourceIDs"])
        XCTAssertNil(hit["contextSourceIDs"])
        let match = try XCTUnwrap((hit["matches"] as? [[String: Any]])?.first)
        XCTAssertEqual(match["sourceIDs"] as? [String], [source.uuidString])
        XCTAssertNil(match["documentSourceIDs"])
        let plain = try await call(service, ["path": path], name: "read_memory")
        XCTAssertEqual(plain["sourceIDs"] as? [String], [source.uuidString])
        XCTAssertNil(plain["contextSourceIDs"])
        XCTAssertEqual(plain["contextSourceCount"] as? Int, 1)
        let full = try await call(service, ["path": path, "includeContext": true], name: "read_memory")
        XCTAssertEqual(full["contextSourceIDs"] as? [String], [context.uuidString])
    }

    func testMultipleQueriesFuseResultsAndReportMatchedQueries() async throws {
        let hotel = try writeMemory(path: "Wiki/Topics/Hotel.md", title: "Hotel", body: "酒店预订已确认。", updatedAt: 100)
        let flight = try writeMemory(path: "Wiki/Topics/Flight.md", title: "Flight", body: "航班改到周五。", updatedAt: 200)
        let both = try writeMemory(path: "Wiki/Topics/Trip.md", title: "Trip", body: "出差安排：酒店和航班都已处理。", updatedAt: 50)
        let store = try LibraryStore(root: root)
        let (service, _) = await service(store)
        let page = try await call(service, ["queries": ["酒店", "航班"]])
        let memories = try XCTUnwrap(page["memories"] as? [[String: Any]])
        XCTAssertEqual(memories.first?["id"] as? String, both.uuidString, "A memory answering both sub-questions ranks first")
        XCTAssertEqual(Set(memories.compactMap { $0["id"] as? String }), [hotel.uuidString, flight.uuidString, both.uuidString].reduce(into: Set<String>()) { $0.insert($1) })
        XCTAssertEqual(Set(memories.first?["matchedQueries"] as? [String] ?? []), ["酒店", "航班"])
        let hotelHit = try XCTUnwrap(memories.first { $0["id"] as? String == hotel.uuidString })
        XCTAssertEqual(hotelHit["matchedQueries"] as? [String], ["酒店"])
        let invalid = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "search_memories", "arguments": [String: Any]()]])
        let rawReply = await service.respond(String(decoding: invalid, as: UTF8.self))
        let reply = try XCTUnwrap(rawReply)
        XCTAssertTrue(reply.contains("\"isError\":true"), "query or queries is required")
    }

    func testSearchReturnsOneHopNeighboursWithTheLinkingPassage() async throws {
        let hotel = try writeMemory(path: "Wiki/Topics/Hotel.md", title: "Hotel reservation", body: "预订已确认。", updatedAt: 100)
        let trip = try writeMemory(path: "Wiki/Projects/Shanghai.md", title: "Shanghai trip", body: "行程概览。\n\n住宿：[[Wiki/Topics/Hotel|酒店]]，已付款。", updatedAt: 200)
        let daily = try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20", body: "整理了 [[Wiki/Projects/Shanghai|上海行程]] 的票据。", updatedAt: 300)
        try writeMemory(path: "Wiki/Archives/old.md", title: "old", body: "旧记录 [[Wiki/Projects/Shanghai]]。", updatedAt: 10)
        let store = try LibraryStore(root: root)
        let index = try await store.readMemory(path: "Memory.md")
        try await store.updateEntry(id: index.id, title: index.title, body: index.body + "\n- [[Wiki/Projects/Shanghai|上海]]\n", expectedRevision: index.revision)
        let (service, _) = await service(store)
        let page = try await call(service, ["query": "概览"])
        XCTAssertEqual((page["memories"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [trip.uuidString])
        let related = try XCTUnwrap(page["related"] as? [[String: Any]])
        let ids = related.compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(ids), [hotel.uuidString, daily.uuidString], "Neighbours exclude the root index and archives")
        let hotelEntry = try XCTUnwrap(related.first { $0["id"] as? String == hotel.uuidString })
        let via = try XCTUnwrap((hotelEntry["via"] as? [[String: Any]])?.first)
        XCTAssertEqual(via["direction"] as? String, "outgoing")
        XCTAssertEqual(via["label"] as? String, "酒店")
        XCTAssertEqual(via["from"] as? String, trip.uuidString)
        XCTAssertTrue((via["passage"] as? String)?.contains("已付款") == true)
        let dailyEntry = try XCTUnwrap(related.first { $0["id"] as? String == daily.uuidString })
        let backlink = try XCTUnwrap((dailyEntry["via"] as? [[String: Any]])?.first)
        XCTAssertEqual(backlink["direction"] as? String, "backlink")
        XCTAssertTrue((backlink["passage"] as? String)?.contains("票据") == true)
        let compact = try await call(service, ["query": "概览", "expand": false])
        XCTAssertEqual((compact["related"] as? [[String: Any]])?.count, 0)
    }

    func testRelatedMemoriesToolReturnsEdgesAndInstructionsStartWithSearch() async throws {
        let target = try writeMemory(path: "Wiki/Projects/chat-bridge.md", title: "chat-bridge", body: "# chat-bridge\n\n目录：[[Wiki/Projects/chat-bridge#路由|路由]]\n\n## 路由\n\n细节。")
        try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20", body: "讨论 JEV。详见 [[Wiki/Projects/chat-bridge#路由|chat-bridge]]。")
        try writeMemory(path: "Wiki/Archives/snapshot.md", title: "snapshot", body: "旧目录 [[Wiki/Projects/chat-bridge]]。")
        let store = try LibraryStore(root: root)
        let (service, initialize) = await service(store)
        XCTAssertTrue(initialize.contains("Start with search_memories"), initialize)
        XCTAssertFalse(initialize.contains("Start with read_memory"))
        let links = try await call(service, ["id": target.uuidString], name: "get_related_memories")
        XCTAssertEqual((links["outgoing"] as? [[String: Any]])?.count, 0, "Links to the page's own sections are not relations")
        XCTAssertEqual((links["backlinks"] as? [[String: Any]])?.count, 1, "Archive snapshots stay out unless requested")
        let withArchives = try await call(service, ["id": target.uuidString, "includeArchives": true], name: "get_related_memories")
        XCTAssertEqual((withArchives["backlinks"] as? [[String: Any]])?.count, 2)
        let backlink = try XCTUnwrap((links["backlinks"] as? [[String: Any]])?.first)
        let via = try XCTUnwrap((backlink["via"] as? [[String: Any]])?.first)
        XCTAssertEqual(via["fragment"] as? String, "路由")
        XCTAssertTrue((via["passage"] as? String)?.contains("讨论 JEV") == true)
        XCTAssertNil(backlink["contextSourceIDs"])
    }

    func testExistingLibraryMigratesLinkAndSearchTablesOnce() async throws {
        let target = try writeMemory(path: "Wiki/Projects/MyClip.md", title: "MyClip", body: "应用。")
        let daily = try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20", body: "做 [[Wiki/Projects/MyClip#计划|记忆项目]]。")
        _ = try await LibraryStore(root: root).snapshot()
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        try database.script("DROP TABLE memory_links; DROP TABLE entry_search; DROP TABLE memory_passage_search;")
        try database.script("CREATE TABLE memory_links (source TEXT NOT NULL, target TEXT NOT NULL, label TEXT NOT NULL, PRIMARY KEY(source,target,label)); CREATE VIRTUAL TABLE entry_search USING fts5(id UNINDEXED, title, body, terms); CREATE VIRTUAL TABLE memory_passage_search USING fts5(entry_id UNINDEXED, ordinal UNINDEXED, title, body, terms); PRAGMA user_version=9;")
        let migrated = try LibraryStore(root: root)
        let relations = try await migrated.relations(daily)
        XCTAssertEqual(relations.outgoing.map(\.id), [target])
        let found = try await migrated.searchMemories(query: "记忆项目")
        XCTAssertTrue(found.map(\.id).contains(target))
        let version = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite")).run("PRAGMA user_version").first?["user_version"]
        XCTAssertEqual(version, "11")
        XCTAssertTrue(try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite")).run("SELECT value FROM vault_meta WHERE key='search_rebuild'").isEmpty)
    }
}
