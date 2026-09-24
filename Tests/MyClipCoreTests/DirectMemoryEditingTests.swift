import XCTest
@testable import MyClipCore

@MainActor
final class DirectMemoryEditingTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// A page written under an older, larger cap keeps working: the vault reads it, no batch fails or rolls it back,
    /// and the agent is told to trim it instead of the user being asked.
    func testPageOverALoweredCapStaysReadableAndBecomesAnAgentInstruction() async throws {
        let store = try LibraryStore(root: root)
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        let page = root.appendingPathComponent("Memory/Wiki/Archives/历史.md")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# 历史\n\n早期结论。".write(to: page, atomically: true, encoding: .utf8)
        _ = try await store.snapshot()
        let indexed = try await store.readMemory(path: "Wiki/Archives/历史.md")
        let historyPath = try XCTUnwrap(database.run("SELECT path FROM entries WHERE id=?", [indexed.id.uuidString]).first?["path"])
        // Simulate the old cap: the same oversized text sits on disk and in the last saved revision.
        let saved = try String(contentsOf: page, encoding: .utf8)
        let boundary = try XCTUnwrap(saved.range(of: "\n---\n"))
        let legacy = String(saved[..<boundary.upperBound]) + String(repeating: "旧", count: MemoryDocument.maxBodyBytes / 3 + 10)
        try legacy.write(to: page, atomically: true, encoding: .utf8)
        try legacy.write(to: root.appendingPathComponent(historyPath), atomically: true, encoding: .utf8)
        try database.run("UPDATE memory_files SET published_hash=? WHERE id=?", [LibraryStore.memoryHash(legacy), indexed.id.uuidString])

        let reopened = try LibraryStore(root: root)
        let snapshot = try await reopened.snapshot()
        XCTAssertTrue(snapshot.entries.contains { $0.id == indexed.id }, "History over the cap is still readable")
        XCTAssertEqual(snapshot.invalidMemoryFiles.count, 1)
        XCTAssertTrue(snapshot.invalidMemoryFiles[0].contains("Wiki/Archives/历史.md"), snapshot.invalidMemoryFiles.description)

        try await reopened.record(image: fixtureImage(), context: fixtureContext(), agent: .claude, organize: true)
        let claimed = try await reopened.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await reopened.beginMemoryEditing(jobID: job.id)
        try "# 另一页\n\n本批正常改动。".write(to: root.appendingPathComponent("Memory/Wiki/Topics/另一页.md"), atomically: true, encoding: .utf8)
        _ = try await reopened.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), legacy, "An untouched legacy page is not rolled back")
        XCTAssertEqual(try database.run("SELECT state FROM jobs WHERE id=?", [job.id.uuidString]).first?["state"], "completed")
        let handoff = try XCTUnwrap(database.run("SELECT value FROM vault_meta WHERE key='organization_handoff'").first?["value"])
        XCTAssertTrue(handoff.contains("必须先处理"), handoff)
        XCTAssertTrue(handoff.contains("Wiki/Archives/历史.md"), handoff)
        XCTAssertTrue(handoff.contains("超过 \(MemoryDocument.maxBodyBytes / 1000) KB 上限"), handoff)

        // Once the agent trims the page it is indexed again and the instruction disappears.
        try await reopened.record(image: fixtureImage(changed: true), context: fixtureContext(at: 300, windowID: 2), agent: .claude, organize: true)
        let secondClaimed = try await reopened.claimNextJob(immediately: true)
        let second = try XCTUnwrap(secondClaimed)
        let again = try await reopened.beginMemoryEditing(jobID: second.id)
        try (String(saved[..<boundary.upperBound]) + "# 历史\n\n只留结论。").write(to: page, atomically: true, encoding: .utf8)
        _ = try await reopened.finishMemoryEditing(jobID: second.id, previousRevisions: again)
        let repaired = try await reopened.snapshot()
        XCTAssertEqual(repaired.invalidMemoryFiles, [])
        let entry = try await reopened.readMemory(path: "Wiki/Archives/历史.md")
        XCTAssertEqual(entry.body, "# 历史\n\n只留结论。")
        let next = try XCTUnwrap(database.run("SELECT value FROM vault_meta WHERE key='organization_handoff'").first?["value"])
        XCTAssertFalse(next.contains("必须先处理"), next)
        XCTAssertTrue(next.contains("更新：Wiki/Archives/历史.md"), next)
    }

    func testHandoffOnlyReplacesPreviousSuccessAfterMemoryIsSaved() async throws {
        let store = try LibraryStore(root: root)
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        var successfulIDs: [UUID] = []
        for index in 0..<2 {
            try await store.record(image: fixtureImage(changed: true, x: index), context: fixtureContext(at: Double(index * 200)), agent: .codex, organize: true)
            let claimed = try await store.claimNextJob(immediately: true)
            let job = try XCTUnwrap(claimed)
            let before = try await store.beginMemoryEditing(jobID: job.id)
            let file = root.appendingPathComponent("Memory/Wiki/Topics/批次\(index).md")
            try "# 批次\(index)\n\n本批新事实。".write(to: file, atomically: true, encoding: .utf8)
            _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
            let handoff = try XCTUnwrap(database.run("SELECT value FROM vault_meta WHERE key='organization_handoff'").first?["value"])
            XCTAssertTrue(handoff.contains(job.id.uuidString))
            XCTAssertTrue(handoff.contains("Wiki/Topics/批次\(index).md"))
            XCTAssertFalse(handoff.contains("本批新事实"), "Handoff must not copy Memory bodies")
            for previous in successfulIDs { XCTAssertFalse(handoff.contains(previous.uuidString)) }
            XCTAssertLessThanOrEqual(handoff.utf8.count, 4096)
            successfulIDs.append(job.id)
        }
        let saved = try database.run("SELECT value FROM vault_meta WHERE key='organization_handoff'").first?["value"]
        let reopened = try LibraryStore(root: root)
        try await reopened.record(image: fixtureImage(changed: true, x: 4), context: fixtureContext(at: 500), agent: .codex, organize: true)
        let next = try await reopened.claimNextJob(immediately: true)
        let failed = try XCTUnwrap(next)
        let before = try await reopened.beginMemoryEditing(jobID: failed.id)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Memory/Profile.md"))
        do {
            _ = try await reopened.finishMemoryEditing(jobID: failed.id, previousRevisions: before)
            XCTFail("Publishing must fail when a required file is missing")
        } catch LibraryError.invalidResult { }
        try await reopened.finishJob(id: failed.id, state: .failed)
        XCTAssertEqual(try database.run("SELECT value FROM vault_meta WHERE key='organization_handoff'").first?["value"], saved)
    }

    func testAgentWrittenFileGetsIndexedWithScreenshotSources() async throws {
        let store = try LibraryStore(root: root)
        let capture = fixtureContext()
        try await store.record(image: fixtureImage(), context: capture, agent: .claude, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let file = root.appendingPathComponent("Memory/Wiki/Topics/直接整理.md")
        let body = "# 直接整理\n\n由 Agent 通过文件工具写入。参见 [[Now]]。来源：截图 `\(capture.id)`。"
        try body.write(to: file, atomically: true, encoding: .utf8)
        // An MCP read may import a file while the agent is still working.
        _ = try await store.snapshot()
        let count = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        let memory = try await store.readMemory(path: "Wiki/Topics/直接整理.md")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(memory.body, body)
        XCTAssertEqual(memory.sourceIDs, [capture.id])
        XCTAssertEqual(memory.agent, .claude)
        let found = try await store.searchMemories(query: "文件工具")
        XCTAssertEqual(found.count, 1)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.state, .completed)
    }

    func testNextBatchEditsExistingFileWithoutReplacingItsIdentity() async throws {
        let store = try LibraryStore(root: root)
        let first = fixtureContext()
        try await store.record(image: fixtureImage(), context: first, agent: .codex, organize: true)
        let initialClaim = try await store.claimNextJob(immediately: true)
        let firstJob = try XCTUnwrap(initialClaim)
        let baseline = try await store.beginMemoryEditing(jobID: firstJob.id)
        let file = root.appendingPathComponent("Memory/Wiki/Projects/项目.md")
        let originalBody = "# 项目\n\n第一批事实。来源：截图 `\(first.id)`。"
        try originalBody.write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.finishMemoryEditing(jobID: firstJob.id, previousRevisions: baseline)
        let original = try await store.readMemory(path: "Wiki/Projects/项目.md")

        let next = fixtureContext(at: 130)
        try await store.record(image: fixtureImage(changed: true), context: next, agent: .codex, organize: true)
        let nextClaim = try await store.claimNextJob(immediately: true)
        let nextJob = try XCTUnwrap(nextClaim)
        let before = try await store.beginMemoryEditing(jobID: nextJob.id)
        try (originalBody + "\n第二批补充。来源：截图 `\(next.id)`。").write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.finishMemoryEditing(jobID: nextJob.id, previousRevisions: before)
        let updated = try await store.readMemory(original.id)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(Set(updated.sourceIDs), [first.id, next.id])
        XCTAssertTrue(updated.body.contains("第二批补充"))
        XCTAssertGreaterThan(updated.revision, original.revision)
    }

    func testNoFileChangesCompletesWithoutInventingMemory() async throws {
        let store = try LibraryStore(root: root)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let count = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(snapshot.entries.count, 3)
        XCTAssertEqual(snapshot.jobs.first?.state, .completed)
    }

    func testRemovingRequiredRootFileDoesNotCompleteJob() async throws {
        let store = try LibraryStore(root: root)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Memory/Profile.md"))
        do {
            _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
            XCTFail("Required root documents must be preserved")
        } catch LibraryError.invalidResult { }
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.state, .running)
    }

    func testOnlyCitedScreenshotsBecomeEvidenceWhileBatchContextIsRetained() async throws {
        let store = try LibraryStore(root: root)
        let cited = fixtureContext(at: 100)
        var unrelated = fixtureContext(at: 200)
        unrelated.appName = "Unrelated App"
        unrelated.bundleID = "test.unrelated"
        for context in [cited, unrelated] {
            try await store.record(image: fixtureImage(), context: context, agent: .claude, organize: true)
        }
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let file = root.appendingPathComponent("Memory/Wiki/Topics/精确来源.md")
        try "# 精确来源\n\n已确认的事实。来源：截图 `\(cited.id)`。".write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.snapshot()
        _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        let memory = try await store.readMemory(path: "Wiki/Topics/精确来源.md")
        XCTAssertEqual(memory.sourceIDs, [cited.id])
        let unrelatedResults = try await store.searchMemories(query: "精确来源", app: unrelated.bundleID)
        XCTAssertTrue(unrelatedResults.isEmpty, "Batch context must not be indexed as evidence")
        XCTAssertTrue(memory.contextSourceIDs.contains(unrelated.id), "Keep batch provenance separate from citations")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("context_source_ids:"), "Batch context stays in the revision history, not the published file")
        XCTAssertFalse(text.contains(unrelated.id.uuidString))
        XCTAssertTrue(text.contains("\nsource_ids: [\(cited.id.uuidString)]\n"), "Cited evidence is still published")
    }

    func testUncitedFileDoesNotInventEvidenceFromTheBatch() async throws {
        let store = try LibraryStore(root: root)
        let capture = fixtureContext()
        try await store.record(image: fixtureImage(), context: capture, agent: .claude, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let file = root.appendingPathComponent("Memory/Wiki/Topics/未引用.md")
        try "# 未引用\n\n没有标明来源的内容。".write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        let memory = try await store.readMemory(path: "Wiki/Topics/未引用.md")
        XCTAssertTrue(memory.sourceIDs.isEmpty)
        XCTAssertEqual(memory.contextSourceIDs, [capture.id], "The audit context must remain recoverable")
    }

    func testOlderBatchCannotReplaceCurrentFocusButCanAddHistory() async throws {
        let store = try LibraryStore(root: root)
        let newer = fixtureContext(at: 300)
        let older = fixtureContext(at: 100)
        let focus = root.appendingPathComponent("Memory/Now.md")
        let current = "# Now\n\n验收已完成。来源：截图 `\(newer.id)`。"
        for capture in [newer, older] {
            try await store.record(image: fixtureImage(), context: capture, agent: .claude, organize: true)
            let claimed = try await store.claimNextJob(immediately: true)
            let job = try XCTUnwrap(claimed)
            let before = try await store.beginMemoryEditing(jobID: job.id)
            if capture.id == newer.id {
                try current.write(to: focus, atomically: true, encoding: .utf8)
            } else {
                let historical = "# 历史\n\n当时验收受阻。来源：截图 `\(older.id)`。"
                try historical.write(to: focus, atomically: true, encoding: .utf8)
                try historical.write(to: root.appendingPathComponent("Memory/Inbox/历史.md"), atomically: true, encoding: .utf8)
                _ = try await store.snapshot() // A UI or MCP read can import an in-progress edit.
            }
            _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        }
        let latest = try await store.readMemory(path: "Now.md")
        let history = try await store.readMemory(path: "Inbox/历史.md")
        XCTAssertEqual(latest.body, current)
        XCTAssertEqual(latest.sourceIDs, [newer.id])
        XCTAssertTrue(history.body.contains("当时验收受阻"))
        XCTAssertEqual(history.sourceIDs, [older.id])
    }

    func testEvidenceTimeIsSeparateFromFileUpdateTimeAndSurvivesVaultCopy() async throws {
        let store = try LibraryStore(root: root)
        let capture = fixtureContext(at: 100)
        try await store.record(image: fixtureImage(), context: capture, agent: .claude, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let file = root.appendingPathComponent("Memory/Wiki/Topics/时间.md")
        try "# 时间\n\n旧截图事实。来源：截图 `\(capture.id)`。".write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("observed_at: \(capture.date.ISO8601Format())\n"))
        let copy = root.appendingPathComponent("Restored")
        try FileManager.default.createDirectory(at: copy.appendingPathComponent("Memory"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: copy.appendingPathComponent("Memory/时间.md"))
        let restored = try LibraryStore(root: copy)
        let server = MemoryMCP(store: restored)
        _ = await server.respond("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}")
        let response = await server.respond("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_get\",\"arguments\":{\"path\":\"时间.md\"}}}")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(response).utf8)) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let document = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(document["observedAt"] as? String, capture.date.ISO8601Format())
        XCTAssertNotEqual(document["observedAt"] as? String, document["updatedAt"] as? String)
        // Citations travel in the body; screenshot metadata stays behind in a bare copy, so the summary counts none.
        XCTAssertTrue((document["content"] as? String)?.contains(capture.id.uuidString) == true)
        XCTAssertEqual((document["sources"] as? [String: Any])?["count"] as? Int, 0)
    }

    func testCitationExtractionIgnoresCodeExamplesAndMemoryLinks() throws {
        let actual = UUID(), example = UUID(), linkedMemory = UUID()
        let body = """
        已确认的事实。来源：截图 `\(actual)`。
        参考 [[\(linkedMemory)|相关记忆]]。
        ```json
        {"sourceID":"\(example)"}
        ```
        """
        XCTAssertEqual(try MemoryDocument.citedSourceIDs(in: body), [actual])
    }

    func testAgentMetadataCannotTurnUnknownIDsIntoEvidence() async throws {
        let store = try LibraryStore(root: root)
        let capture = fixtureContext(), unknown = UUID()
        try await store.record(image: fixtureImage(), context: capture, agent: .claude, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let path = "Wiki/Topics/未知来源.md"
        let file = root.appendingPathComponent("Memory/" + path)
        let text = try MemoryDocument.encode(id: UUID(), title: "未知来源", body: "来源：截图 `\(unknown)`。",
            revision: 1, agent: .claude, sourceIDs: [unknown], path: path)
        try text.write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        let result = try await store.readMemory(path: path)
        XCTAssertTrue(result.sourceIDs.isEmpty)
        XCTAssertEqual(result.contextSourceIDs, [capture.id])
    }

    func testNewerUnrelatedScreenshotCannotMakeOldFocusCurrent() async throws {
        let store = try LibraryStore(root: root)
        let current = fixtureContext(at: 300)
        try await store.record(image: fixtureImage(), context: current, agent: .claude, organize: true)
        let first = try await store.claimNextJob(immediately: true)
        let initial = try XCTUnwrap(first)
        let baseline = try await store.beginMemoryEditing(jobID: initial.id)
        let focus = root.appendingPathComponent("Memory/Now.md")
        let completed = "# Now\n\n已经完成。来源：截图 `\(current.id)`。"
        try completed.write(to: focus, atomically: true, encoding: .utf8)
        _ = try await store.finishMemoryEditing(jobID: initial.id, previousRevisions: baseline)
        let older = fixtureContext(at: 100), unrelated = fixtureContext(at: 500)
        for capture in [older, unrelated] {
            try await store.record(image: fixtureImage(), context: capture, agent: .claude, organize: true)
        }
        let next = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(next)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        try "# Now\n\n仍然受阻。来源：截图 `\(older.id)`。".write(to: focus, atomically: true, encoding: .utf8)
        _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        let result = try await store.readMemory(path: "Now.md")
        XCTAssertEqual(result.body, completed)
        XCTAssertEqual(result.sourceIDs, [current.id])
    }

    func testFilePromptProvidesLocalCaptureTimeAndTimeZoneForDailyGrouping() async throws {
        let store = try LibraryStore(root: root)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-16T18:22:40Z"))
        let capture = fixtureContext(at: date.timeIntervalSince1970)
        try await store.record(image: fixtureImage(), context: capture, agent: .claude, organize: false)
        let inputs = try await store.captures(ids: [capture.id])
        let prompt = KnowledgeComposer.filePrompt(captures: inputs)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        XCTAssertTrue(prompt.contains(formatter.string(from: date)), "Daily must use the local date even when UTC is the previous day")
        XCTAssertTrue(prompt.contains(TimeZone.current.identifier))
    }

    func testMixedPromptMapsOnlyActualAttachmentsAndIncludesOneHandoff() async throws {
        let store = try LibraryStore(root: root)
        var captures: [CaptureContext] = []
        for index in 0..<4 {
            var capture = fixtureContext(at: Double(index))
            capture.reason = index % 2 == 0 ? .clickAfterIdle : .enter
            captures.append(capture)
            try await store.record(image: fixtureImage(changed: true, x: index), context: capture,
                agent: .codex, organize: true, extractedText: "OCR \(index)\n\"quoted text\"")
        }
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let inputs = try await store.organizationInputs(jobID: job.id)
        let prompt = KnowledgeComposer.filePrompt(inputs: inputs, handoff: "previous-success-marker")
        let lines = prompt.components(separatedBy: "\n").filter { $0.hasPrefix("记录 ") }
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("content=ocr"))
        XCTAssertTrue(lines[1].contains("content=image · 图片附件 1"))
        XCTAssertTrue(lines[2].contains("content=ocr"))
        XCTAssertTrue(lines[3].contains("content=image · 图片附件 2"))
        for (index, capture) in captures.enumerated() {
            XCTAssertTrue(lines[index].contains(capture.id.uuidString))
            XCTAssertTrue(lines[index].contains("trigger=\(capture.reason.rawValue)"))
        }
        XCTAssertEqual(prompt.components(separatedBy: "previous-success-marker").count, 2)
        XCTAssertTrue(prompt.contains("独立的临时会话"))
        XCTAssertFalse(prompt.contains("OCR 1"), "Keyboard OCR must not be sent in addition to its image")
    }

    func testHandoffStaysWithinFourKiBEvenWithManyLongPaths() {
        let job = ClipJob(id: UUID(), agent: .codex, state: .completed, createdAt: Date(),
            sourceIDs: (0..<40).map { _ in UUID() }, error: nil)
        let handoff = OrganizationHandoff.make(job: job, captures: [],
            changedPaths: (0..<100).map { "Wiki/Topics/\($0)" + String(repeating: "长文件名", count: 60) + ".md" },
            deletedCount: 5, completedAt: Date())
        XCTAssertLessThanOrEqual(handoff.utf8.count, 4096)
        XCTAssertTrue(handoff.contains("其余文件路径已省略"))
        XCTAssertTrue(handoff.contains("删除 5 个文件"))
    }

    func testNewAgentFileWithOrdinaryYAMLFrontMatterGetsIndexed() async throws {
        let store = try LibraryStore(root: root)
        let capture = fixtureContext()
        try await store.record(image: fixtureImage(), context: capture, agent: .claude, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let file = root.appendingPathComponent("Memory/Daily/验收.md")
        let text = """
        ---
        title: "日记验收"
        metadata:
          type: daily
        ---
        # 日记验收

        今天完成验收。来源：截图 `\(capture.id)`。
        """
        try text.write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        let memory = try await store.readMemory(path: "Daily/验收.md")
        XCTAssertEqual(memory.title, "日记验收")
        XCTAssertTrue(memory.body.hasPrefix("# 日记验收"))
        XCTAssertEqual(memory.sourceIDs, [capture.id])
        let document = try MemoryDocument(String(contentsOf: file, encoding: .utf8))
        XCTAssertTrue(document.extraMetadata.contains("metadata:\n  type: daily"))
    }

    func testOversizedAgentEditIsRestoredAndReportedWhileOtherEditsAreKept() async throws {
        let store = try LibraryStore(root: root)
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .claude, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let page = root.appendingPathComponent("Memory/Wiki/Topics/项目页.md")
        try "# 项目页\n\n第一版结论。".write(to: page, atomically: true, encoding: .utf8)
        _ = try await store.snapshot()  // an MCP read imports the page mid-run, giving it history
        let lastGood = try String(contentsOf: page, encoding: .utf8)
        let boundary = try XCTUnwrap(lastGood.range(of: "\n---\n"))
        let oversized = String(lastGood[..<boundary.upperBound]) + String(repeating: "长", count: MemoryDocument.maxBodyBytes / 3 + 10)
        try oversized.write(to: page, atomically: true, encoding: .utf8)
        try "# 另一页\n\n同一批次的正常改动。".write(to: root.appendingPathComponent("Memory/Wiki/Topics/另一页.md"), atomically: true, encoding: .utf8)

        do {
            _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
            XCTFail("An oversized file must be reported")
        } catch LibraryError.rolledBack(let files) {
            XCTAssertTrue(files.contains("Wiki/Topics/项目页.md"), files)
            XCTAssertTrue(files.contains("KB 上限"), files)
            XCTAssertEqual(RetryPolicy.classify(LibraryError.rolledBack(files)), .transient, "The batch runs again on its own")
        }
        let onDisk = try MemoryDocument(String(contentsOf: page, encoding: .utf8))
        XCTAssertEqual(onDisk.body, "# 项目页\n\n第一版结论。", "The last good body is back on disk")
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.invalidMemoryFiles, [])
        let restoredPage = try await store.readMemory(path: "Wiki/Topics/项目页.md")
        XCTAssertEqual(restoredPage.body, "# 项目页\n\n第一版结论。")
        let otherPage = try await store.readMemory(path: "Wiki/Topics/另一页.md")
        XCTAssertEqual(otherPage.body, "# 另一页\n\n同一批次的正常改动。")
        XCTAssertEqual(try database.run("SELECT state FROM jobs WHERE id=?", [job.id.uuidString]).first?["state"], "running", "The caller decides the job state")
        XCTAssertTrue(try database.run("SELECT value FROM vault_meta WHERE key='organization_handoff'").isEmpty, "Only a completed batch writes a handoff")

        // The last allowed attempt writes the same oversized page again: the batch completes and the instruction moves to the handoff.
        try database.run("UPDATE jobs SET attempts=? WHERE id=?", [String(RetryPolicy.maxAttempts), job.id.uuidString])
        let again = try await store.beginMemoryEditing(jobID: job.id)
        try oversized.write(to: page, atomically: true, encoding: .utf8)
        _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: again)
        XCTAssertEqual(try database.run("SELECT state FROM jobs WHERE id=?", [job.id.uuidString]).first?["state"], "completed", "The user is never asked to act on a cap problem")
        let handoff = try XCTUnwrap(database.run("SELECT value FROM vault_meta WHERE key='organization_handoff'").first?["value"])
        XCTAssertTrue(handoff.contains("必须先处理"), handoff)
        XCTAssertTrue(handoff.contains("上一批写入 Wiki/Topics/项目页.md"), handoff)
        XCTAssertTrue(handoff.contains("先整理该页"), handoff)
        let afterwards = try MemoryDocument(String(contentsOf: page, encoding: .utf8))
        XCTAssertEqual(afterwards.body, "# 项目页\n\n第一版结论。")
    }

    func testRetryPromptCarriesThePreviousAttempt() {
        let note = LibraryError.rolledBack("Wiki/Projects/chat-bridge.md（Memory 正文 129 KB，超过 128 KB 上限。）").localizedDescription
        let prompt = KnowledgeComposer.filePrompt(inputs: [], handoff: nil, previousAttempt: note)
        XCTAssertTrue(prompt.contains("本批上次尝试未完成：已恢复上一版：Wiki/Projects/chat-bridge.md"), prompt)
        XCTAssertTrue(prompt.contains("先整理"), prompt)
        XCTAssertTrue(prompt.contains("仍然过长再按主题拆分"), prompt)
        XCTAssertFalse(KnowledgeComposer.filePrompt(inputs: []).contains("上次尝试"))
    }
}
