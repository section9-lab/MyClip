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

    private func call(_ service: MemoryMCP, _ args: [String: Any], name: String = "memory_search") async throws -> [String: Any] {
        let result = try await rawCall(service, args, name: name)
        return try XCTUnwrap(result["structuredContent"] as? [String: Any], "\(result)")
    }

    private func rawCall(_ service: MemoryMCP, _ args: [String: Any], name: String) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name, "arguments": args]])
        let raw = await service.respond(String(decoding: data, as: UTF8.self))
        let reply = try XCTUnwrap(raw)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }

    private func results(_ page: [String: Any]) -> [[String: Any]] { page["results"] as? [[String: Any]] ?? [] }
    private func paths(_ page: [String: Any]) -> [String] { results(page).compactMap { $0["path"] as? String } }

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

    func testArchivesStayOutOfMCPSearchButRemainReadable() async throws {
        try writeMemory(path: "Wiki/Projects/chat-bridge.md", title: "chat-bridge", body: "JEV 路由方案。", updatedAt: 100)
        try writeMemory(path: "Wiki/Archives/Memory入口-2026-09-21.md", title: "Memory 入口历史快照", body: "旧目录提到 JEV 路由。", updatedAt: 200)
        let store = try LibraryStore(root: root)
        let (service, _) = await service(store)
        let live = try await call(service, ["query": "JEV"])
        XCTAssertEqual(paths(live), ["Wiki/Projects/chat-bridge.md"])
        let removed = try await rawCall(service, ["query": "JEV", "includeArchives": true], name: "memory_search")
        XCTAssertEqual(removed["isError"] as? Bool, true, "Arguments earlier versions accepted are rejected, not ignored")
        let archive = try await call(service, ["path": "Wiki/Archives/Memory入口-2026-09-21.md"], name: "memory_get")
        XCTAssertEqual(archive["content"] as? String, "旧目录提到 JEV 路由。")
        let app = try await store.searchMemories(query: "JEV")
        XCTAssertEqual(app.count, 2, "The app keeps listing archives")
    }

    func testResultsCiteTheirPassageAndGetSummarizesSources() async throws {
        let source = UUID(), context = UUID()
        let path = "Wiki/Topics/Notes.md"
        let url = root.appendingPathComponent("Memory/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MemoryDocument.encode(id: UUID(), title: "Notes", body: "编译失败。来源：截图 `\(source)`。", revision: 1, agent: .codex, sourceIDs: [source], path: path,
                                  contextSourceIDs: [context]).write(to: url, atomically: true, encoding: .utf8)
        let store = try LibraryStore(root: root)
        let (service, _) = await service(store)
        let page = try await call(service, ["query": "编译"])
        let hit = try XCTUnwrap(results(page).first)
        XCTAssertEqual(hit["sourceIDs"] as? [String], [source.uuidString])
        XCTAssertNil(hit["contextSourceIDs"])
        XCTAssertNil(hit["via"], "Direct matches carry no path")
        XCTAssertTrue((hit["snippet"] as? String)?.hasPrefix("编译失败") == true)
        let document = try await call(service, ["path": path], name: "memory_get")
        XCTAssertNil(document["contextSourceIDs"])
        XCTAssertEqual((document["sources"] as? [String: Any])?["count"] as? Int, 0, "Only recorded screenshots are summarized")
    }

    func testQueryWithSeveralTermsRanksTheMemoryHoldingAllOfThemFirst() async throws {
        try writeMemory(path: "Wiki/Topics/Hotel.md", title: "Hotel", body: "酒店预订已确认。", updatedAt: 100)
        try writeMemory(path: "Wiki/Topics/Flight.md", title: "Flight", body: "航班改到周五。", updatedAt: 200)
        try writeMemory(path: "Wiki/Topics/Trip.md", title: "Trip", body: "出差安排：酒店和航班都已处理。", updatedAt: 50)
        let store = try LibraryStore(root: root)
        let (service, _) = await service(store)
        let page = try await call(service, ["query": "酒店 航班"])
        XCTAssertEqual(paths(page).first, "Wiki/Topics/Trip.md")
        XCTAssertEqual(Set(paths(page)), ["Wiki/Topics/Hotel.md", "Wiki/Topics/Flight.md", "Wiki/Topics/Trip.md"])
        let missing = try await rawCall(service, [:], name: "memory_search")
        XCTAssertEqual(missing["isError"] as? Bool, true, "query is required")
    }

    func testSearchReachesLinkedMemoriesWithTheirFactLines() async throws {
        try writeMemory(path: "Wiki/Topics/Hotel.md", title: "Hotel reservation", body: "预订已确认。", updatedAt: 100)
        try writeMemory(path: "Wiki/Projects/Shanghai.md", title: "Shanghai trip", body: "行程概览。\n\n## 住宿\n\n- 住宿：[[Wiki/Topics/Hotel|酒店]]，已付款。", updatedAt: 200)
        try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20", body: "整理了 [[Wiki/Projects/Shanghai|上海行程]] 的票据。", updatedAt: 300)
        try writeMemory(path: "Wiki/Archives/old.md", title: "old", body: "旧记录 [[Wiki/Projects/Shanghai]]。", updatedAt: 10)
        let store = try LibraryStore(root: root)
        let index = try await store.readMemory(path: "Memory.md")
        try await store.updateEntry(id: index.id, title: index.title, body: index.body + "\n- [[Wiki/Projects/Shanghai|上海]]\n", expectedRevision: index.revision)
        let (service, _) = await service(store)
        let page = try await call(service, ["query": "概览"])
        XCTAssertEqual(paths(page).first, "Wiki/Projects/Shanghai.md")
        XCTAssertEqual(Set(paths(page)), ["Wiki/Projects/Shanghai.md", "Wiki/Topics/Hotel.md", "Daily/2026/09/2026-09-20.md"],
                       "Linked memories join the results; the root index and archives do not")
        let hotel = try XCTUnwrap(results(page).first { $0["path"] as? String == "Wiki/Topics/Hotel.md" })
        let hop = try XCTUnwrap((hotel["via"] as? [[String: Any]])?.first)
        XCTAssertEqual(hop["page"] as? String, "Wiki/Projects/Shanghai.md")
        XCTAssertEqual(hop["section"] as? String, "住宿")
        XCTAssertEqual(hop["fact"] as? String, "住宿：酒店，已付款。")
        let daily = try XCTUnwrap(results(page).first { $0["path"] as? String == "Daily/2026/09/2026-09-20.md" })
        let backlink = try XCTUnwrap((daily["via"] as? [[String: Any]])?.first)
        XCTAssertEqual(backlink["page"] as? String, "Daily/2026/09/2026-09-20.md", "A backlink's fact line is written on the linking page")
        XCTAssertEqual(backlink["date"] as? String, "2026-09-20")
        XCTAssertTrue((daily["snippet"] as? String)?.contains("票据") == true, "A graph-only hit shows the passage that holds the link")
        let filtered = try await call(service, ["query": "概览", "since": "2027-01-01T00:00:00Z"])
        XCTAssertTrue(paths(filtered).isEmpty, "Linked memories must pass the same time filter")
    }

    func testSecondHopRunsOnlyThroughEntityPages() async throws {
        // Two episodes share a person; the question names words only one of them contains.
        try writeMemory(path: "Wiki/People/Maria.md", title: "Maria", body: "## 家庭\n\n- 小时候家里困难，阿姨帮过家里 [[Daily/2023/05/2023-05-02|5/2]]\n- 阿姨们接济过家里 [[Daily/2023/06/2023-06-10|6/10]]")
        try writeMemory(path: "Daily/2023/05/2023-05-02.md", title: "2023-05-02", body: "和 [[Wiki/People/Maria|Maria]] 聊到志愿服务，她的阿姨一直相信做志愿者。")
        try writeMemory(path: "Daily/2023/06/2023-06-10.md", title: "2023-06-10", body: "[[Wiki/People/Maria|Maria]] 说小时候靠外面的帮助渡过难关。")
        try writeMemory(path: "Daily/2023/07/2023-07-01.md", title: "2023-07-01", body: "另一段记录，提到志愿服务。")
        let store = try LibraryStore(root: root)
        let hits = try await store.memorySearch(query: "志愿服务", limit: 10)
        let found = hits.map(\.memory.relativePath)
        XCTAssertTrue(found.contains("Daily/2023/06/2023-06-10.md"), "episode → entity → episode reaches the other session: \(found)")
        let bridged = try XCTUnwrap(hits.first { $0.memory.relativePath == "Daily/2023/06/2023-06-10.md" })
        XCTAssertFalse(bridged.via.isEmpty)
        XCTAssertTrue(bridged.via.contains { $0.page == "Wiki/People/Maria.md" && $0.fact.contains("阿姨们接济") }, "\(bridged.via)")
    }

    func testSnippetKeepsTheMatchingFactLinesOfALongSection() async throws {
        let filler = (1...40).map { "- Nate played video games with friends on day \($0) [[Daily/2022-01-\(String(format: "%02d", $0 % 28 + 1))|day]]" }
        let lines = filler[..<20] + ["- Nate took his two turtles for a walk because he was bored [[Daily/2022-10-25|2022-10-25]]"] + filler[20...]
        try writeMemory(path: "Wiki/People/Nate.md", title: "Nate", body: "# Nate\n\n## Hobbies\n\n" + lines.joined(separator: "\n"))
        try writeMemory(path: "Wiki/People/Joanna.md", title: "Joanna", body: "# Joanna\n\n## Writing\n\n- Joanna writes screenplays.")
        try writeMemory(path: "Daily/2022-10-25.md", title: "2022-10-25", body: "Nate walked his turtles.")
        try writeMemory(path: "Daily/2022-01-02.md", title: "2022-01-02", body: "Games night.")
        let store = try LibraryStore(root: root)
        let hits = try await store.memorySearch(query: "How many turtles does Nate have?")
        let hit = try XCTUnwrap(hits.first { $0.memory.relativePath == "Wiki/People/Nate.md" })
        let snippet = hit.passages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(snippet.contains("two turtles for a walk"), "Rare query words pick the line, not the first common word: \(snippet)")
        XCTAssertFalse(snippet.contains("[["), snippet)
        XCTAssertTrue(hit.links.contains("Daily/2022-10-25.md"), "\(hit.links)")
        XCTAssertEqual(hit.links.contains("Daily/2022-01-02.md"), snippet.contains("day 1 day") || snippet.contains("day 29 day"),
                       "Only links on shown lines are listed: \(hit.links)")
        XCTAssertLessThanOrEqual(snippet.count, GraphConstants.excerptLimit * GraphConstants.passagesPerHit + GraphConstants.passagesPerHit)
    }

    func testCitationsWithTimesBetweenIDsAreReadAndHidden() {
        let first = UUID(), second = UUID()
        let line = "- 确认方案 [[Daily/2026/09/2026-09-18#方案讨论|9/18]] 来源：截图 `\(first)`（2026-09-18T11:19:49Z）、`\(second)`（11:25:08+08:00，含批准）"
        XCTAssertEqual(Set(MemoryPassage.explicitSources(in: line)), [first, second], "A time between two IDs is not inline code")
        XCTAssertEqual(KnowledgeEntry.displayed(line[...]), "- 确认方案 9/18")
        XCTAssertEqual(KnowledgeEntry.displayed("结论。（来源：截图 `\(first)`、截图 `\(second)`）"[...]), "结论。")
        XCTAssertEqual(MemoryPassage.explicitSources(in: "运行 `sources: \(first)` 查看"), [], "Inline code holding a colon is a field, not a citation")
        XCTAssertEqual(MemoryPassage.explicitSources(in: "见 `config: on`。来源：截图 `\(second)`"), [second])
    }

    func testSnippetShowsLinkLabelsWithoutCitationsAndListsLinkTargets() async throws {
        let store = try LibraryStore(root: root)
        let capture = fixtureContext()
        try await store.record(image: fixtureImage(), context: capture, agent: .codex, organize: false)
        let typo = UUID()
        try writeMemory(path: "Daily/2026/09/2026-09-24.md", title: "2026-09-24", body: "# 2026-09-24\n\n## 检索改造\n\n改了片段。")
        try writeMemory(path: "Wiki/Projects/MyClip.md", title: "MyClip", body: "# MyClip\n\n## 检索\n\n"
            + "- 片段去掉引用编号，链接只显示标签 [[Daily/2026/09/2026-09-24#检索改造|9/24]]（来源：截图 `\(capture.id)`）\n"
            + "- 另一条引用编号抄错 [[Wiki/Topics/Missing]]。来源：截图 `\(typo)`")
        _ = try await store.snapshot()
        let (service, _) = await service(store)
        let page = try await call(service, ["query": "引用编号"])
        let hit = try XCTUnwrap(results(page).first { $0["path"] as? String == "Wiki/Projects/MyClip.md" })
        let snippet = try XCTUnwrap(hit["snippet"] as? String)
        XCTAssertTrue(snippet.contains("链接只显示标签 9/24"), snippet)
        XCTAssertTrue(snippet.contains("抄错 Missing。"), "An unlabelled link shows its page name: \(snippet)")
        XCTAssertFalse(snippet.contains("[[") || snippet.contains("`") || snippet.contains("来源"), snippet)
        XCTAssertEqual(hit["links"] as? [String], ["Daily/2026/09/2026-09-24.md#检索改造"], "Unresolved links are not offered to memory_get")
        XCTAssertEqual(hit["sourceIDs"] as? [String], [capture.id.uuidString], "A recorded citation joins the page's sources even when the file listed none")
        let section = try await call(service, ["path": "Daily/2026/09/2026-09-24.md#检索改造"], name: "memory_get")
        XCTAssertEqual(section["content"] as? String, "## 检索改造\n\n改了片段。")
        let report = try await store.memoryLint()
        XCTAssertEqual(report.unknownCitations, ["Wiki/Projects/MyClip.md（`\(typo.uuidString)`）"])
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("引用了没有记录的截图 ID") })
    }

    func testExistingLibraryRepairsCitedSourcesOnceAndKeepsTheEditTime() async throws {
        let capture = fixtureContext()
        try writeMemory(path: "Wiki/Topics/Notes.md", title: "Notes", body: "编译失败。来源：截图 `\(capture.id)`", updatedAt: 500)
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        // The page was indexed before the screenshot's record existed, as in a library saved by an older app.
        try await store.record(image: fixtureImage(), context: capture, agent: .codex, organize: false)
        let before = try await store.readMemory(path: "Wiki/Topics/Notes.md")
        XCTAssertEqual(before.sourceIDs, [])
        try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite")).script("PRAGMA user_version=14;")
        let migrated = try LibraryStore(root: root)
        _ = try await migrated.snapshot()
        let after = try await migrated.readMemory(path: "Wiki/Topics/Notes.md")
        XCTAssertEqual(after.sourceIDs, [capture.id])
        XCTAssertEqual(after.revision, before.revision + 1)
        XCTAssertEqual(after.updatedAt, before.updatedAt, "Only the evidence list changed")
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        XCTAssertEqual(try database.run("PRAGMA user_version").first?["user_version"], "15")
        XCTAssertTrue(try database.run("SELECT value FROM vault_meta WHERE key='source_repair'").isEmpty)
        _ = try await migrated.snapshot()
        let again = try await migrated.readMemory(path: "Wiki/Topics/Notes.md")
        XCTAssertEqual(again.revision, after.revision, "The repair runs once")
    }

    func testEdgeTextKeepsTheFactLineHeadingAndDate() async throws {
        let long = String(repeating: "背景说明很长。", count: 60) + "关键结论见 [[Wiki/Topics/JEV|JEV]]。后面还有别的话。"
        try writeMemory(path: "Wiki/Topics/JEV.md", title: "JEV", body: "模型。")
        let source = try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20", body: "# 当天\n\n## 工作\n\n- 讨论 [[Wiki/Topics/JEV|JEV]] 复刻\n\n" + long)
        let store = try LibraryStore(root: root)
        let neighborhood = try await store.memoryNeighborhood(source)
        XCTAssertEqual(neighborhood.links.map(\.fact), ["讨论 JEV 复刻", "关键结论见 JEV。"], "List markers go; long paragraphs keep the sentence around the link")
        XCTAssertEqual(neighborhood.links.map(\.section), ["工作", "工作"])
        XCTAssertEqual(neighborhood.links.first?.date.map { String($0.ISO8601Format().prefix(4)) }, "2026")
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        func count(_ sql: String) throws -> Int { Int(try database.run(sql)[0]["n"] ?? "") ?? -1 }
        let before = try count("SELECT count(*) AS n FROM memory_edge_search")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Memory/Daily/2026/09/2026-09-20.md"))
        _ = try await store.snapshot()
        XCTAssertEqual(before - (try count("SELECT count(*) AS n FROM memory_edge_search")), 2, "Deleting a page removes its edge text")
        XCTAssertEqual(try count("SELECT count(*) AS n FROM memory_edge_search WHERE rowid NOT IN (SELECT rowid FROM memory_links)"), 0)
    }

    func testGetReadsSectionsAndLineRangesAndListsNeighbours() async throws {
        let target = "Wiki/Projects/chat-bridge.md"
        try writeMemory(path: target, title: "chat-bridge", body: "# chat-bridge\n\n目录：[[Wiki/Projects/chat-bridge#路由|路由]]\n\n## 路由\n\n细节一。\n细节二。\n\n## 其他\n\n别的。")
        try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20", body: "讨论 JEV。详见 [[Wiki/Projects/chat-bridge#路由|chat-bridge]]。")
        try writeMemory(path: "Wiki/Archives/snapshot.md", title: "snapshot", body: "旧目录 [[Wiki/Projects/chat-bridge]]。")
        let store = try LibraryStore(root: root)
        let (service, initialize) = await service(store)
        XCTAssertTrue(initialize.contains("Start with memory_search"), initialize)
        let section = try await call(service, ["path": target + "#路由"], name: "memory_get")
        XCTAssertEqual(section["content"] as? String, "## 路由\n\n细节一。\n细节二。\n")
        let lines = try await call(service, ["path": target, "from": 5, "lines": 2], name: "memory_get")
        XCTAssertEqual(lines["content"] as? String, "## 路由\n")
        XCTAssertEqual(lines["nextFrom"] as? Int, 7)
        let whole = try await call(service, ["path": target], name: "memory_get")
        XCTAssertEqual((whole["links"] as? [[String: Any]])?.count, 0, "Links to the page's own sections are not relations")
        let backlinks = try XCTUnwrap(whole["backlinks"] as? [[String: Any]])
        XCTAssertEqual(backlinks.compactMap { $0["page"] as? String }, ["Daily/2026/09/2026-09-20.md"], "Archive snapshots stay out")
        XCTAssertTrue((backlinks.first?["fact"] as? String)?.contains("讨论 JEV") == true)
        let missing = try await rawCall(service, ["path": target + "#不存在"], name: "memory_get")
        XCTAssertEqual(missing["isError"] as? Bool, true)
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
        XCTAssertEqual(version, "15")
        XCTAssertTrue(try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite")).run("SELECT value FROM vault_meta WHERE key='search_rebuild'").isEmpty)
    }
}
