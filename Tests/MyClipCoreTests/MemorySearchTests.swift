import XCTest
@testable import MyClipCore

@MainActor
final class MemorySearchTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func writeMemory(title: String, body: String, updatedAt: TimeInterval = 100, sources: [UUID] = []) throws -> UUID {
        let id = UUID(), path = "Wiki/\(id.uuidString).md"
        let url = root.appendingPathComponent("Memory/\(path)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MemoryDocument.encode(id: id, title: title, body: body, revision: 1, agent: .codex, sourceIDs: sources, path: path,
                                  updatedAt: Date(timeIntervalSince1970: updatedAt)).write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    private func service(_ store: LibraryStore) async -> MemoryMCP {
        let service = MemoryMCP(store: store)
        _ = await service.respond("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}")
        return service
    }

    private func call(_ service: MemoryMCP, _ args: [String: Any], name: String = "search_memories") async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name, "arguments": args]])
        let reply = await service.respond(String(decoding: data, as: UTF8.self))
        let response = try XCTUnwrap(reply)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }

    private func memories(_ result: [String: Any]) throws -> [[String: Any]] {
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        return try XCTUnwrap(content["memories"] as? [[String: Any]])
    }

    func testExtraQueryWordDoesNotHideRelevantMemory() async throws {
        let store = try LibraryStore(root: root)
        let id = try writeMemory(title: "Shanghai meeting", body: "客户会议地点和出差行程。")
        let found = try await store.searchMemories(query: "Shanghai meeting transport")
        XCTAssertEqual(found.map(\.id), [id])
        let chinese = try await store.searchMemories(query: "客户会议 不存在词")
        XCTAssertEqual(chinese.map(\.id), [id])
    }

    func testRelevantTitleRanksAheadOfRecentIncidentalMentionAcrossAppAndMCP() async throws {
        let store = try LibraryStore(root: root)
        let relevant = try writeMemory(title: "Compiler troubleshooting", body: "清理缓存后重新构建。", updatedAt: 100)
        let incidental = try writeMemory(title: "Daily notes", body: "Read a compiler article today. " + String(repeating: "Other tasks. ", count: 50), updatedAt: 300)
        let found = try await store.searchMemories(query: "compiler")
        XCTAssertEqual(found.map(\.id), [relevant, incidental])
        let snapshot = try await store.snapshot(query: "compiler")
        XCTAssertEqual(snapshot.entries.map(\.id), [relevant, incidental])
        let service = await service(store)
        let first = try memories(await call(service, ["query": "compiler", "limit": 1]))
        let second = try memories(await call(service, ["query": "compiler", "limit": 1, "offset": 1]))
        XCTAssertEqual(first.first?["id"] as? String, relevant.uuidString)
        XCTAssertEqual(second.first?["id"] as? String, incidental.uuidString)
    }

    func testMatchingMoreTermsRanksAheadOfSingleTerm() async throws {
        let store = try LibraryStore(root: root)
        let relevant = try writeMemory(title: "Build investigation", body: "compiler failure caused by stale cache", updatedAt: 100)
        let partial = try writeMemory(title: "Reading", body: "compiler documentation for a different project", updatedAt: 300)
        let found = try await store.searchMemories(query: "compiler failure")
        XCTAssertEqual(found.map(\.id), [relevant, partial])
    }

    func testSearchSummaryContainsDeepMatchWithReadableCharacterOffset() async throws {
        let store = try LibraryStore(root: root)
        let body = String(repeating: "周记🏙️：今天处理日常工作。\n", count: 90) + "\n编译失败的原因是依赖版本不一致，需要更新依赖。\n" + String(repeating: "后续记录。", count: 90)
        let id = try writeMemory(title: "工作记录", body: body)
        let service = await service(store)
        let found = try memories(await call(service, ["query": "编译失败"]))
        let match = try XCTUnwrap(found.first)
        let excerpt = try XCTUnwrap(match["summary"] as? String)
        XCTAssertTrue(excerpt.contains("编译失败的原因是依赖版本不一致"))
        XCTAssertTrue(excerpt.hasPrefix("编译失败"), "A two-line preview must not start with unrelated preceding paragraphs")
        XCTAssertLessThanOrEqual(excerpt.count, 360)
        let offset = try XCTUnwrap(match["summaryOffset"] as? Int)
        XCTAssertGreaterThan(offset, 360)
        let read = try await call(service, ["id": id.uuidString, "offset": offset, "limit": excerpt.count], name: "read_memory")
        let content = try XCTUnwrap(read["structuredContent"] as? [String: Any])
        XCTAssertEqual(content["body"] as? String, excerpt)
    }

    func testSearchSummaryFollowsCaseAndDiacriticInsensitiveMatch() async throws {
        let store = try LibraryStore(root: root)
        try writeMemory(title: "Places", body: String(repeating: "Earlier notes. ", count: 90) + "Meet at Café demain.")
        let service = await service(store)
        let found = try memories(await call(service, ["query": "CAFE"]))
        XCTAssertTrue((found.first?["summary"] as? String)?.contains("Café demain") == true)
    }

    func testCapturedTimeAndAppMustMatchTheSameCitedScreenshot() async throws {
        let store = try LibraryStore(root: root)
        let old = fixtureContext(at: 100), current = fixtureContext(at: 250), boundary = fixtureContext(at: 300)
        let safari = CaptureContext(appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Meeting", windowID: 2, reason: .enter, date: Date(timeIntervalSince1970: 250))
        for context in [old, current, boundary, safari] {
            try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: false)
        }
        let stale = try writeMemory(title: "Meeting old", body: "旧会议", updatedAt: 1000, sources: [old.id])
        let mixed = try writeMemory(title: "Meeting mixed", body: "不同来源", updatedAt: 1000, sources: [old.id, safari.id])
        let expected = try writeMemory(title: "Meeting current", body: "区间内的会议", updatedAt: 1000, sources: [current.id])
        let end = try writeMemory(title: "Meeting later", body: "区间外的会议", updatedAt: 1000, sources: [boundary.id])
        let unknown = try writeMemory(title: "Meeting unknown", body: "没有截图时间", updatedAt: 1000)
        let service = await service(store)
        let args: [String: Any] = ["query": "meeting", "since": "1970-01-01T00:03:20Z", "until": "1970-01-01T00:05:00Z", "timeField": "captured", "app": "com.apple.Notes"]
        let captured = try memories(await call(service, args))
        XCTAssertEqual(captured.compactMap { $0["id"] as? String }, [expected.uuidString])
        let modified = try memories(await call(service, ["query": "meeting", "since": "1970-01-01T00:03:20Z"]))
        XCTAssertEqual(Set(modified.compactMap { $0["id"] as? String }), Set([stale, mixed, expected, end, unknown].map(\.uuidString)), "Existing since requests continue to filter file edit time")
    }

    func testTimeFiltersRejectUnknownMeaningAndInvalidRanges() async throws {
        let store = try LibraryStore(root: root)
        let service = await service(store)
        for extra: [String: Any] in [
            ["timeField": "happened"], ["until": "yesterday"],
            ["since": "2026-09-20T00:00:00Z", "until": "2026-09-19T00:00:00Z"]
        ] {
            let result = try await call(service, ["query": ""].merging(extra) { _, new in new })
            XCTAssertEqual(result["isError"] as? Bool, true, "Do not silently ignore invalid time filters: \(extra)")
        }
    }

    func testUpdatedTimeRangeAcceptsFractionalISO8601Bounds() async throws {
        let store = try LibraryStore(root: root)
        let first = try writeMemory(title: "Meeting A", body: "上午会议", updatedAt: 250)
        try writeMemory(title: "Meeting B", body: "下午会议", updatedAt: 300)
        let service = await service(store)
        let found = try memories(await call(service, ["query": "meeting", "since": "1970-01-01T00:03:20.000Z", "until": "1970-01-01T00:05:00.000Z", "timeField": "updated"]))
        XCTAssertEqual(found.compactMap { $0["id"] as? String }, [first.uuidString])
    }

    func testLiteralPunctuationDoesNotBecomeFTSOperators() async throws {
        let store = try LibraryStore(root: root)
        let id = try writeMemory(title: "Programming", body: "C++ uses operator symbols: ++")
        for query in ["C++", "++", "\"C++\"", "***"] {
            let results = try await store.searchMemories(query: query)
            XCTAssertEqual(results.map(\.id), query == "***" ? [] : [id])
        }
    }

    func testEmptyQueryKeepsRecentOrderWithoutTruncatingAppLibrary() async throws {
        let store = try LibraryStore(root: root)
        var ids: [UUID] = []
        for index in 0..<55 {
            ids.append(try writeMemory(title: "Note \(index)", body: "记忆内容", updatedAt: Double(100 + index)))
        }
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.entries.filter { !$0.isRootDocument }.map(\.id), ids.reversed())
        let page = try await store.searchMemories(query: "", limit: 2, offset: 1)
        XCTAssertEqual(page.map(\.id), Array(snapshot.entries.dropFirst().prefix(2).map(\.id)))
    }

    func testSearchCanExpandExplicitWikilinksWithoutPullingThemIntoMatches() async throws {
        let store = try LibraryStore(root: root)
        let hotel = try writeMemory(title: "Hotel reservation", body: "预订已确认。")
        let trip = try writeMemory(title: "Shanghai trip", body: "住宿：[[\(hotel.uuidString)|酒店]]。")
        let service = await service(store)
        let found = try memories(await call(service, ["query": "Shanghai"]))
        XCTAssertEqual(found.compactMap { $0["id"] as? String }, [trip.uuidString])
        let related = try await call(service, ["id": trip.uuidString], name: "get_related_memories")
        let links = try XCTUnwrap(related["structuredContent"] as? [String: Any])
        XCTAssertEqual((links["outgoing"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [hotel.uuidString])
    }

    func testCompleteBodyPhraseOutranksRepeatedScatteredWords() async throws {
        let store = try LibraryStore(root: root)
        let phrase = try writeMemory(title: "Project notes", body: "Confirm the release deadline with the team.", updatedAt: 100)
        let scattered = try writeMemory(title: "Project notes", body: String(repeating: "release planning deadline review ", count: 8), updatedAt: 300)
        let found = try await store.searchMemories(query: "release deadline")
        XCTAssertEqual(found.map(\.id), [phrase, scattered])
    }

    func testBestPassageKeepsItsOwnEvidenceAndExactBodyRange() async throws {
        let store = try LibraryStore(root: root)
        let first = UUID(), second = UUID()
        let important = "Compiler reports a dependency mismatch after the package update. 来源：截图 `\(second)`。"
        let body = "# Work log\n\nCompiler reading list. 来源：截图 `\(first)`。\n\n" + String(repeating: "普通周记🏙️。\n\n", count: 60) + important
        let id = try writeMemory(title: "Work log", body: body, sources: [first, second])
        let service = await service(store)
        let found = try memories(await call(service, ["query": "compiler dependency mismatch"]))
        let memory = try XCTUnwrap(found.first)
        let matches = try XCTUnwrap(memory["matches"] as? [[String: Any]])
        let best = try XCTUnwrap(matches.first)
        XCTAssertEqual(best["text"] as? String, important)
        XCTAssertEqual(best["sourceIDs"] as? [String], [second.uuidString])
        XCTAssertEqual(best["sourceScope"] as? String, "passage")
        XCTAssertEqual(best["path"] as? String, "Wiki/\(id).md")
        XCTAssertEqual(best["revision"] as? Int, 1)
        let start = try XCTUnwrap(best["startOffset"] as? Int), end = try XCTUnwrap(best["endOffset"] as? Int)
        XCTAssertEqual(String(body.dropFirst(start).prefix(end - start)), important)
        let read = try await call(service, ["id": id.uuidString, "offset": start, "limit": end - start, "revision": 1], name: "read_memory")
        XCTAssertEqual((read["structuredContent"] as? [String: Any])?["body"] as? String, important)
        let stale = try await call(service, ["id": id.uuidString, "offset": start, "revision": 999], name: "read_memory")
        XCTAssertEqual(stale["isError"] as? Bool, true, "Offsets must not silently read a different document revision")
    }

    func testUncitedPassageDoesNotInheritDocumentEvidence() async throws {
        let store = try LibraryStore(root: root)
        let source = UUID()
        try writeMemory(title: "Notes", body: "Compiler failure requires investigation.\n\n另一段的来源：截图 `\(source)`。", sources: [source])
        let service = await service(store)
        let found = try memories(await call(service, ["query": "compiler"]))
        let best = try XCTUnwrap((found.first?["matches"] as? [[String: Any]])?.first)
        XCTAssertEqual(best["sourceIDs"] as? [String], [])
        XCTAssertEqual(best["sourceScope"] as? String, "document")
        XCTAssertEqual(best["documentSourceIDs"] as? [String], [source.uuidString])
    }

    private func eventParagraph(_ date: String, text: String, source: UUID) -> String {
        let start = ISO8601DateFormatter().date(from: date + "T00:00:00+08:00")!
        let end = start.addingTimeInterval(86_400).ISO8601Format()
        return "<!-- myclip-event {\"start\":\"\(date)T00:00:00+08:00\",\"end\":\"\(end)\",\"precision\":\"day\",\"evidence\":\"\(date)\"} -->\n\(date)：\(text) 来源：截图 `\(source)`。"
    }

    func testEventTimeIsIndependentOfCaptureAndEditDates() async throws {
        let store = try LibraryStore(root: root)
        let source = fixtureContext(at: ISO8601DateFormatter().date(from: "2026-09-18T10:00:00+08:00")!.timeIntervalSince1970)
        try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: false)
        let id = try writeMemory(title: "项目记录", body: eventParagraph("2026-09-10", text: "预算审批已完成。", source: source.id),
                                 updatedAt: ISO8601DateFormatter().date(from: "2026-09-20T10:00:00+08:00")!.timeIntervalSince1970, sources: [source.id])
        let service = await service(store)
        for (field, day) in [("event", "10"), ("captured", "18"), ("updated", "20")] {
            let result = try memories(await call(service, ["query": "预算审批", "timeField": field, "since": "2026-09-\(day)T00:00:00+08:00", "until": "2026-09-\(day)T23:59:59+08:00"]))
            XCTAssertEqual(result.compactMap { $0["id"] as? String }, [id.uuidString])
        }
        let wrongDay = try memories(await call(service, ["query": "预算审批", "timeField": "event", "since": "2026-09-18T00:00:00+08:00"]))
        XCTAssertTrue(wrongDay.isEmpty)
        let eventResult = try memories(await call(service, ["query": "预算审批", "timeField": "event"]))
        let best = try XCTUnwrap((eventResult.first?["matches"] as? [[String: Any]])?.first)
        let time = try XCTUnwrap(best["eventTime"] as? [String: Any])
        XCTAssertEqual(time["precision"] as? String, "day")
        XCTAssertEqual(time["evidence"] as? String, "2026-09-10")
        XCTAssertEqual(time["timeZoneOffset"] as? String, "+08:00")
        XCTAssertFalse((best["text"] as? String)?.contains("myclip-event") == true)
    }

    func testEventDateQueryAndAppBelongToTheSamePassage() async throws {
        let store = try LibraryStore(root: root)
        let notes = fixtureContext(at: 100)
        let safari = CaptureContext(appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Budget", windowID: 2, reason: .enter, date: Date(timeIntervalSince1970: 200))
        for source in [notes, safari] { try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: false) }
        let body = eventParagraph("2026-09-10", text: "预算审批已完成。", source: safari.id) + "\n\n" + eventParagraph("2026-09-18", text: "发布部署已完成。", source: notes.id)
        let id = try writeMemory(title: "项目日志", body: body, sources: [notes.id, safari.id])
        let service = await service(store)
        let args: [String: Any] = ["query": "预算审批", "timeField": "event", "since": "2026-09-18T00:00:00+08:00", "until": "2026-09-19T00:00:00+08:00"]
        let wrongDate = try memories(await call(service, args))
        XCTAssertTrue(wrongDate.isEmpty)
        let wrongApp = try memories(await call(service, ["query": "预算审批", "timeField": "event", "app": "Notes"]))
        XCTAssertTrue(wrongApp.isEmpty)
        let correct = try memories(await call(service, ["query": "预算审批", "timeField": "event", "app": "Safari"]))
        XCTAssertEqual(correct.first?["id"] as? String, id.uuidString)
        XCTAssertEqual((correct.first?["matches"] as? [[String: Any]])?.count, 1)
    }

    func testUnknownMalformedAndExampleEventTimesAreNotInvented() async throws {
        let store = try LibraryStore(root: root)
        let source = UUID()
        let valid = eventParagraph("2026-09-10", text: "会议已结束。", source: source)
        for body in [
            "昨天会议结束。来源：截图 `\(source)`。",
            "```md\n\(valid)\n```",
            valid.replacingOccurrences(of: "2026-09-10T00:00:00+08:00", with: "yesterday"),
            valid.replacingOccurrences(of: "\"evidence\":\"2026-09-10\"", with: "\"evidence\":\"正文没有这个日期\""),
            valid.replacingOccurrences(of: "\n2026-09-10", with: "\n\n2026-09-10"),
            valid.replacingOccurrences(of: "来源：截图 `\(source)`。", with: "没有明确来源。")
        ] { try writeMemory(title: "会议", body: body, sources: [source]) }
        let service = await service(store)
        let event = try memories(await call(service, ["query": "会议", "timeField": "event"]))
        XCTAssertTrue(event.isEmpty)
        let ordinary = try memories(await call(service, ["query": "会议"]))
        XCTAssertEqual(ordinary.count, 6, "Undated and malformed notes remain searchable")
    }

    func testEventIntervalsUseOverlapAndExclusiveUpperBound() async throws {
        let store = try LibraryStore(root: root)
        let source = UUID()
        let id = try writeMemory(title: "会议", body: eventParagraph("2026-09-10", text: "客户会议。", source: source), sources: [source])
        let service = await service(store)
        let insideDay = try memories(await call(service, ["query": "会议", "timeField": "event", "since": "2026-09-10T12:00:00+08:00", "until": "2026-09-10T13:00:00+08:00"]))
        XCTAssertEqual(insideDay.first?["id"] as? String, id.uuidString)
        let before = try memories(await call(service, ["query": "会议", "timeField": "event", "until": "2026-09-10T00:00:00+08:00"]))
        let after = try memories(await call(service, ["query": "会议", "timeField": "event", "since": "2026-09-11T00:00:00+08:00"]))
        XCTAssertTrue(before.isEmpty)
        XCTAssertTrue(after.isEmpty)
    }

    func testEventIndexTracksExternalEditsDeletionAndVaultRestore() async throws {
        let store = try LibraryStore(root: root)
        let source = UUID()
        let id = try writeMemory(title: "会议", body: eventParagraph("2026-09-10", text: "客户会议。", source: source), sources: [source])
        let service = await service(store)
        let first = try memories(await call(service, ["query": "会议", "timeField": "event"]))
        XCTAssertEqual(first.first?["id"] as? String, id.uuidString)
        let url = root.appendingPathComponent("Memory/Wiki/\(id).md")
        let restoredRoot = root.appendingPathComponent("Restored")
        try FileManager.default.createDirectory(at: restoredRoot.appendingPathComponent("Memory"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: restoredRoot.appendingPathComponent("Memory/Meeting.md"))
        let restored = try LibraryStore(root: restoredRoot)
        let restoredService = await self.service(restored)
        let copied = try memories(await call(restoredService, ["query": "会议", "timeField": "event"]))
        XCTAssertEqual(copied.first?["id"] as? String, id.uuidString)
        let revised = try MemoryDocument.encode(id: id, title: "会议", body: "日期待确认。来源：截图 `\(source)`。", revision: 1, agent: .codex, sourceIDs: [source], path: "Wiki/\(id).md")
        try revised.write(to: url, atomically: true, encoding: .utf8)
        let edited = try memories(await call(service, ["query": "会议", "timeField": "event"]))
        XCTAssertTrue(edited.isEmpty)
        try await store.rebuildSearchIndex()
        try FileManager.default.removeItem(at: url)
        let deleted = try memories(await call(service, ["query": "会议"]))
        XCTAssertTrue(deleted.isEmpty)
    }

    func testOrganizerSeparatesObservationFromEventTime() {
        for prompt in [KnowledgeComposer.filePrompt(captures: []), KnowledgeComposer.prompt(captures: [], existing: [])] {
            XCTAssertFalse(prompt.contains("截图时间是事实发生的时间"))
            XCTAssertTrue(prompt.contains("myclip-event"))
            XCTAssertTrue(prompt.contains("相对日期"))
            XCTAssertTrue(prompt.contains("未知"))
        }
    }

    func testUUIDMentionDoesNotBecomePassageEvidence() async throws {
        let store = try LibraryStore(root: root)
        let source = UUID()
        try writeMemory(title: "Records", body: "Compiler log includes identifier `\(source)` as sample data.\n\n实际来源：截图 `\(source)`。", sources: [source])
        let service = await service(store)
        let found = try memories(await call(service, ["query": "compiler"]))
        let best = try XCTUnwrap((found.first?["matches"] as? [[String: Any]])?.first)
        XCTAssertEqual(best["sourceIDs"] as? [String], [])
        XCTAssertEqual(best["sourceScope"] as? String, "document")
    }

    func testInstantAndRangeEventBoundaries() async throws {
        let store = try LibraryStore(root: root)
        let source = UUID()
        let instant = "<!-- myclip-event {\"start\":\"2026-09-10T10:00:00+08:00\",\"precision\":\"instant\",\"evidence\":\"10:00\"} -->\n会议在 10:00 开始。来源：截图 `\(source)`。"
        let range = "<!-- myclip-event {\"start\":\"2026-09-10T11:00:00+08:00\",\"end\":\"2026-09-10T12:00:00+08:00\",\"precision\":\"range\",\"evidence\":\"11:00–12:00\"} -->\n会议时间为 11:00–12:00。来源：截图 `\(source)`。"
        let instantID = try writeMemory(title: "会议", body: instant, sources: [source])
        let rangeID = try writeMemory(title: "会议", body: range, sources: [source])
        let service = await service(store)
        let atStart = try memories(await call(service, ["query": "会议", "timeField": "event", "since": "2026-09-10T10:00:00+08:00", "until": "2026-09-10T11:00:00+08:00"]))
        XCTAssertEqual(atStart.first?["id"] as? String, instantID.uuidString)
        XCTAssertEqual(atStart.count, 1)
        let inside = try memories(await call(service, ["query": "会议", "timeField": "event", "since": "2026-09-10T11:30:00+08:00", "until": "2026-09-10T11:45:00+08:00"]))
        XCTAssertEqual(inside.first?["id"] as? String, rangeID.uuidString)
        let after = try memories(await call(service, ["query": "会议", "timeField": "event", "since": "2026-09-10T12:00:00+08:00"]))
        XCTAssertTrue(after.isEmpty)
    }

    func testMissingPassageIndexRebuildsWithoutChangingMarkdown() async throws {
        let store = try LibraryStore(root: root)
        let source = UUID()
        let id = try writeMemory(title: "会议", body: eventParagraph("2026-09-10", text: "客户会议。", source: source), sources: [source])
        let memory = try await store.readMemory(id)
        let before = try Data(contentsOf: memory.fileURL)
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        try database.run("DELETE FROM memory_passages")
        try database.run("DELETE FROM memory_passage_search")
        let reopened = try LibraryStore(root: root)
        let service = await service(reopened)
        let found = try memories(await call(service, ["query": "会议", "timeField": "event"]))
        XCTAssertEqual(found.first?["id"] as? String, id.uuidString)
        XCTAssertEqual(try Data(contentsOf: memory.fileURL), before)
        try await reopened.rebuildSearchIndex()
        let rebuilt = try memories(await call(service, ["query": "会议", "timeField": "event"]))
        XCTAssertEqual(rebuilt.first?["id"] as? String, id.uuidString)
    }

    func testHeadingMatchIncludesParagraphContext() async throws {
        let store = try LibraryStore(root: root)
        try writeMemory(title: "Compiler", body: "# Compiler\n\n依赖版本不一致，更新后构建恢复正常。")
        let service = await service(store)
        let found = try memories(await call(service, ["query": "compiler"]))
        let best = try XCTUnwrap((found.first?["matches"] as? [[String: Any]])?.first)
        XCTAssertEqual(best["text"] as? String, "依赖版本不一致，更新后构建恢复正常。")
    }

    func testImpossibleOrConflictingEventAnnotationsStayUnknown() async throws {
        let store = try LibraryStore(root: root)
        let source = UUID()
        let invalid = "<!-- myclip-event {\"start\":\"2026-02-30T00:00:00+08:00\",\"end\":\"2026-03-03T00:00:00+08:00\",\"precision\":\"day\",\"evidence\":\"2026-02-30\"} -->\n2026-02-30 会议。来源：截图 `\(source)`。"
        let first = eventParagraph("2026-09-10", text: "会议。", source: source).components(separatedBy: "\n")[0]
        let second = eventParagraph("2026-09-18", text: "会议。", source: source)
        for body in [invalid, first + "\n" + second] { try writeMemory(title: "会议", body: body, sources: [source]) }
        let service = await service(store)
        let found = try memories(await call(service, ["query": "会议", "timeField": "event"]))
        XCTAssertTrue(found.isEmpty, "Invalid dates and competing annotations must not silently pick a time")
    }

    func testEventAnnotationsAreHiddenInReaderButPreservedInCodeExamples() {
        let annotation = "<!-- myclip-event {\"start\":\"2026-09-10T00:00:00+08:00\"} -->"
        let body = "# 会议\n\n\(annotation)\n会议记录，参见 [[Wiki/项目]]。\n\n```markdown\n\(annotation)\n```\n"
        let rendered = Wikilink.markdown(body)
        XCTAssertFalse(rendered.contains(annotation + "\n会议记录"))
        XCTAssertTrue(rendered.contains("会议记录，参见 [Wiki/项目](myclip-memory:///"))
        XCTAssertTrue(rendered.contains("```markdown\n" + annotation + "\n```"))
        XCTAssertTrue(body.contains(annotation + "\n会议记录"), "Rendering does not mutate stored Markdown or body offsets")
    }

    func testHiddenEventMetadataDoesNotCountAsSearchContent() async throws {
        let store = try LibraryStore(root: root)
        let source = UUID()
        let id = try writeMemory(title: "会议", body: eventParagraph("2026-09-10", text: "客户会议。", source: source), sources: [source])
        let hidden = try await store.searchMemories(query: "precision")
        XCTAssertFalse(hidden.contains { $0.id == id })
        try await store.rebuildSearchIndex()
        let rebuilt = try await store.snapshot(query: "precision")
        XCTAssertFalse(rebuilt.entries.contains { $0.id == id })
    }
}
