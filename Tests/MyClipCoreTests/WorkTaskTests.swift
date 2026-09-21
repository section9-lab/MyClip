import XCTest
@testable import MyClipCore

@MainActor
final class WorkTaskTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testTaskStorageIsSeparateFromProcessingJobs() async throws {
        let store = try LibraryStore(root: root)
        let snapshot = try await store.snapshot()
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        let tables = try database.run("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] }
        XCTAssertTrue(tables.contains("work_tasks"))
        XCTAssertTrue(tables.contains("work_task_events"))
        XCTAssertEqual(snapshot.entries.count, 3)
        XCTAssertTrue(snapshot.jobs.isEmpty)
    }

    func testScreenshotOrganizationAlsoRequestsTaskEvidence() {
        let prompt = KnowledgeComposer.filePrompt(captures: [])
        XCTAssertTrue(prompt.contains("\"tasks\""))
        XCTAssertTrue(prompt.contains("suggestedStatus"))
        XCTAssertTrue(prompt.contains("evidence"))
    }

    func testSuggestionsAreCandidatesAndReplayDoesNotDuplicateEvidence() async throws {
        let store = try LibraryStore(root: root)
        let source = fixtureContext()
        try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: false)
        let draft = WorkTaskDraft(title: "验证截图", project: "MyClip", suggestedStatus: .done, evidence: "测试已通过", sourceIDs: [source.id])
        for _ in 0..<2 { try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [source.id], allowedMemoryIDs: []) }
        let tasks = try await store.workTasks()
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(task.status, .candidate)
        XCTAssertEqual(task.suggestedStatus, .done)
        XCTAssertNil(task.confirmedAt)
        XCTAssertEqual(task.evidence.count, 1)
        XCTAssertEqual(task.evidence.first?.sourceIDs, [source.id])
        let stats = try await store.workTaskStatistics(days: 7)
        XCTAssertEqual(stats.added, 0)
        XCTAssertEqual(stats.completed, 0)
    }

    func testNewEvidenceAdvancesConfirmedTasksAndPreservesIgnoredStateAcrossRestart() async throws {
        let store = try LibraryStore(root: root)
        let source = fixtureContext(at: 300)
        try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: false)
        var draft = WorkTaskDraft(title: "Review API", project: "MyClip", evidence: "需要检查 API", sourceIDs: [source.id])
        try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [source.id], allowedMemoryIDs: [])
        let initial = try await store.workTasks()
        let id = try XCTUnwrap(initial.first?.id)
        try await store.setWorkTaskStatus(id, status: .doing, at: Date(timeIntervalSince1970: 200))
        draft.title = "  review   api  "
        draft.project = "myclip"
        draft.evidence = "API 验证已完成"
        draft.suggestedStatus = .done
        try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [source.id], allowedMemoryIDs: [])
        let tasks = try await store.workTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.status, .done)
        XCTAssertNil(tasks.first?.suggestedStatus)
        XCTAssertEqual(tasks.first?.evidence.count, 2)
        try await store.setWorkTaskStatus(id, status: .ignored)
        let reopened = try LibraryStore(root: root)
        try await reopened.ingestTaskSuggestions([draft], allowedSourceIDs: [source.id], allowedMemoryIDs: [])
        let restored = try await reopened.workTasks()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.status, .ignored)
    }

    func testAIProgressIsRecordedAndOldEvidenceCannotUndoManualCorrection() async throws {
        let store = try LibraryStore(root: root)
        let id = try await store.createWorkTask(title: "验证导出", waitingReason: "等待环境", at: Date(timeIntervalSince1970: 100))
        let source = fixtureContext(at: 200)
        try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: false)
        var draft = WorkTaskDraft(taskID: id, title: "验证导出", suggestedStatus: .doing, evidence: "正在执行导出测试", sourceIDs: [source.id])
        try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [source.id], allowedMemoryIDs: [], at: Date(timeIntervalSince1970: 210))
        var tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.status, .doing)
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        let events = try database.run("SELECT * FROM work_task_events WHERE task_id=? ORDER BY created_at", [id.uuidString])
        XCTAssertEqual(events.last?["actor"], "ai")

        try await store.setWorkTaskStatus(id, status: .todo, at: Date(timeIntervalSince1970: 220))
        draft.evidence = "重新措辞的旧线索：测试已完成"
        draft.suggestedStatus = .done
        try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [source.id], allowedMemoryIDs: [], at: Date(timeIntervalSince1970: 230))
        tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.status, .todo)
        XCTAssertNil(tasks.first?.suggestedStatus)

        let fresh = fixtureContext(at: 300)
        try await store.record(image: fixtureImage(), context: fresh, agent: .codex, organize: false)
        draft.sourceIDs = [fresh.id]
        draft.evidence = "导出回归测试全部通过"
        for _ in 0..<2 {
            try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [fresh.id], allowedMemoryIDs: [], at: Date(timeIntervalSince1970: 310))
        }
        tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.status, .done)
        XCTAssertEqual(tasks.first?.completedAt, Date(timeIntervalSince1970: 310))
        XCTAssertEqual(tasks.first?.waitingReason, "")
        let history = try await store.workTaskEvents(id)
        XCTAssertEqual(history.count, 4)
    }

    func testAIRegressionRemainsAReviewableSuggestion() async throws {
        let store = try LibraryStore(root: root)
        let id = try await store.createWorkTask(title: "验收发布", at: Date(timeIntervalSince1970: 100))
        try await store.setWorkTaskStatus(id, status: .done, at: Date(timeIntervalSince1970: 200))
        let source = fixtureContext(at: 300)
        try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: false)
        let draft = WorkTaskDraft(taskID: id, title: "验收发布", suggestedStatus: .doing, evidence: "新发现的问题需要继续排查", sourceIDs: [source.id])
        try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [source.id], allowedMemoryIDs: [], at: Date(timeIntervalSince1970: 310))
        let tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.status, .done)
        XCTAssertEqual(tasks.first?.suggestedStatus, .doing)
        try await store.setWorkTaskStatus(id, status: .doing, at: Date(timeIntervalSince1970: 320))
        let updated = try await store.workTasks()
        XCTAssertNil(updated.first?.completedAt)
    }

    func testUndatedMemoryRequiresReviewInsteadOfAutomaticCompletion() async throws {
        let store = try LibraryStore(root: root)
        let id = try await store.createWorkTask(title: "验证交付", at: Date(timeIntervalSince1970: 100))
        let snapshot = try await store.snapshot()
        let memory = try XCTUnwrap(snapshot.entries.first { $0.relativePath == "Now.md" })
        XCTAssertNil(memory.observedAt)
        let draft = WorkTaskDraft(taskID: id, title: "验证交付", suggestedStatus: .done, evidence: "未标明发生时间的完成记录", memoryIDs: [memory.id])
        try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [], allowedMemoryIDs: [memory.id])
        let tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.status, .todo)
        XCTAssertEqual(tasks.first?.suggestedStatus, .done)
    }

    func testInvalidBatchRollsBackAutomaticStatusChanges() async throws {
        let store = try LibraryStore(root: root)
        let id = try await store.createWorkTask(title: "核对结果", at: Date(timeIntervalSince1970: 100))
        let source = fixtureContext(at: 200)
        try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: false)
        let valid = WorkTaskDraft(taskID: id, title: "核对结果", suggestedStatus: .done, evidence: "核对通过", sourceIDs: [source.id])
        let invalid = WorkTaskDraft(title: "不存在的来源", evidence: "来源无效", sourceIDs: [UUID()])
        do {
            try await store.ingestTaskSuggestions([valid, invalid], allowedSourceIDs: [source.id], allowedMemoryIDs: [])
            XCTFail("Invalid provenance must reject the complete batch")
        } catch LibraryError.invalidResult { }
        let tasks = try await store.workTasks(), events = try await store.workTaskEvents(id)
        XCTAssertEqual(tasks.first?.status, .todo)
        XCTAssertTrue(tasks.first?.evidence.isEmpty == true)
        XCTAssertEqual(events.count, 1)
    }

    func testDelayedBatchesAdvanceUsingObservationTimeInsteadOfProcessingTime() async throws {
        let store = try LibraryStore(root: root)
        let started = fixtureContext(at: 200), finished = fixtureContext(at: 300)
        for source in [started, finished] {
            try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: false)
        }
        for separateBatches in [true, false] {
            let id = try await store.createWorkTask(title: separateBatches ? "分批处理" : "同批处理", at: Date(timeIntervalSince1970: 100))
            let doing = WorkTaskDraft(taskID: id, title: "更新任务", suggestedStatus: .doing, evidence: "正在测试", sourceIDs: [started.id])
            let done = WorkTaskDraft(taskID: id, title: "更新任务", suggestedStatus: .done, evidence: "测试通过", sourceIDs: [finished.id])
            if separateBatches {
                try await store.ingestTaskSuggestions([doing], allowedSourceIDs: [started.id], allowedMemoryIDs: [], at: Date(timeIntervalSince1970: 1000))
            }
            try await store.ingestTaskSuggestions(separateBatches ? [done] : [doing, done], allowedSourceIDs: [started.id, finished.id], allowedMemoryIDs: [], at: Date(timeIntervalSince1970: 1001))
            var tasks = try await store.workTasks()
            XCTAssertEqual(tasks.first(where: { $0.id == id })?.status, .done)
            XCTAssertEqual(tasks.first(where: { $0.id == id })?.completedAt, Date(timeIntervalSince1970: 1001))
            var old = doing
            old.evidence = "重读旧的测试中记录"
            try await store.ingestTaskSuggestions([old], allowedSourceIDs: [started.id], allowedMemoryIDs: [], at: Date(timeIntervalSince1970: 1002))
            tasks = try await store.workTasks()
            XCTAssertNil(tasks.first(where: { $0.id == id })?.suggestedStatus)
        }
    }

    func testInventedSourcesRejectWholeBatch() async throws {
        let store = try LibraryStore(root: root)
        let source = fixtureContext()
        try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: false)
        let good = WorkTaskDraft(title: "真实任务", evidence: "需要确认", sourceIDs: [source.id])
        let bad = WorkTaskDraft(title: "伪造任务", evidence: "无来源", sourceIDs: [UUID()])
        do {
            try await store.ingestTaskSuggestions([good, bad], allowedSourceIDs: [source.id], allowedMemoryIDs: [])
            XCTFail("An out-of-batch source must reject the batch")
        } catch LibraryError.invalidResult { }
        let tasks = try await store.workTasks()
        XCTAssertTrue(tasks.isEmpty)
    }

    func testMemoryDiscoveryKeepsEvidenceAfterSourceDeletion() async throws {
        let store = try LibraryStore(root: root)
        let snapshot = try await store.snapshot()
        let memory = try XCTUnwrap(snapshot.entries.first { $0.relativePath == "Now.md" })
        let draft = WorkTaskDraft(title: "整理资料", evidence: "下一步整理资料", memoryIDs: [memory.id])
        try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [], allowedMemoryIDs: [memory.id])
        let tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.evidence.first?.memoryIDs, [memory.id])
        // Removing a source index must not cascade-delete the user's task or its quoted evidence.
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        try database.run("PRAGMA foreign_keys=ON")
        try database.run("DELETE FROM entries WHERE id=?", [memory.id.uuidString])
        let retained = try await store.workTasks()
        XCTAssertEqual(retained.first?.evidence.first?.body, "下一步整理资料")
    }

    func testStateHistoryStatisticsIncludeReopeningAndZeroDays() async throws {
        let store = try LibraryStore(root: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_789_689_600)
        let id = try await store.createWorkTask(title: "验证发布", project: "MyClip", at: start)
        try await store.setWorkTaskStatus(id, status: .doing, at: start.addingTimeInterval(3600))
        try await store.setWorkTaskStatus(id, status: .done, at: start.addingTimeInterval(7200))
        try await store.setWorkTaskStatus(id, status: .done, at: start.addingTimeInterval(7300))
        try await store.setWorkTaskStatus(id, status: .doing, at: start.addingTimeInterval(86400))
        let stats = try await store.workTaskStatistics(days: 7, now: start.addingTimeInterval(86401), calendar: calendar)
        XCTAssertEqual(stats.days.count, 7)
        XCTAssertEqual(stats.added, 1)
        XCTAssertEqual(stats.completed, 1)
        XCTAssertEqual(stats.unfinished, 1)
        XCTAssertEqual(stats.backlogChange, 1)
        XCTAssertEqual(stats.days.filter { $0.added == 0 && $0.completed == 0 }.count, 6)
        let events = try await store.workTaskEvents(id)
        XCTAssertEqual(events.count, 4)
        let tasks = try await store.workTasks()
        XCTAssertNil(tasks.first?.completedAt)
        XCTAssertEqual(tasks.first?.confirmedAt, start)
    }

    func testTaskEditingAndExplicitIdentityPreventSemanticDuplicates() async throws {
        let store = try LibraryStore(root: root)
        let id = try await store.createWorkTask(title: "修改文档", project: "MyClip")
        try await store.updateWorkTask(id, title: "补充使用说明", project: "文档")
        let source = fixtureContext()
        try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: false)
        let draft = WorkTaskDraft(taskID: id, title: "完善操作说明", project: "MyClip", evidence: "正在补充说明", sourceIDs: [source.id])
        try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [source.id], allowedMemoryIDs: [])
        let tasks = try await store.workTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "补充使用说明")
        XCTAssertEqual(tasks.first?.project, "文档")
        XCTAssertEqual(tasks.first?.status, .todo)
    }

    func testTaskResponseParsingRejectsProseAndAllowsFinalEnvelope() throws {
        let json = "{\"tasks\":[{\"title\":\"确认方案\",\"project\":\"MyClip\",\"suggestedStatus\":\"todo\",\"evidence\":\"待确认\",\"sourceIDs\":[],\"memoryIDs\":[]}]}"
        XCTAssertEqual(try TaskComposer.parse("整理完成。\n" + json).first?.title, "确认方案")
        XCTAssertEqual(try TaskComposer.parse("```json\n" + json + "\n```").count, 1)
        XCTAssertTrue(try TaskComposer.parse("{\"tasks\":[]}").isEmpty)
        XCTAssertThrowsError(try TaskComposer.parse("已经完成"))
        XCTAssertThrowsError(try TaskComposer.parse(json + "尾部说明"))
    }

    func testWaitingReasonIsEditableWithoutChangingStatus() async throws {
        let store = try LibraryStore(root: root)
        let id = try await store.createWorkTask(title: "确认字段", waitingReason: "等待客户反馈")
        var tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.waitingReason, "等待客户反馈")
        try await store.updateWorkTask(id, title: "确认字段", project: "客户协作", waitingReason: "")
        tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.waitingReason, "")
        XCTAssertEqual(tasks.first?.status, .todo)
    }

    func testVersionFourLibraryMigratesWithoutLosingMemoryOrCapture() async throws {
        let original = try LibraryStore(root: root)
        try await original.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: false)
        let before = try await original.snapshot()
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        try database.script("DROP TABLE work_task_evidence; DROP TABLE work_task_events; DROP TABLE work_tasks; PRAGMA user_version=4;")
        let upgraded = try LibraryStore(root: root)
        let after = try await upgraded.snapshot()
        XCTAssertEqual(after.captures.map(\.id), before.captures.map(\.id))
        XCTAssertEqual(after.entries.map(\.id), before.entries.map(\.id))
        XCTAssertEqual(try database.run("PRAGMA user_version").first?["user_version"], "11")
        _ = try await upgraded.createWorkTask(title: "升级后的新任务")
        let tasks = try await upgraded.workTasks()
        XCTAssertEqual(tasks.count, 1)
    }

    func testVersionSixTaskHistoryMigratesWithoutLosingEvents() async throws {
        let store = try LibraryStore(root: root)
        let id = try await store.createWorkTask(title: "保留已有任务")
        let snapshot = try await store.snapshot()
        let memory = try XCTUnwrap(snapshot.entries.first)
        try await store.ingestTaskSuggestions([WorkTaskDraft(title: "历史候选任务", evidence: "需要确认的工作", memoryIDs: [memory.id])], allowedSourceIDs: [], allowedMemoryIDs: [memory.id])
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        if try database.run("PRAGMA table_info(work_tasks)").contains(where: { $0["name"] == "status_observed_at" }) {
            try database.script("ALTER TABLE work_tasks DROP COLUMN status_observed_at;")
        }
        try database.script("""
            CREATE TABLE legacy_events AS SELECT id,task_id,from_status,to_status,created_at FROM work_task_events;
            DROP TABLE work_task_events;
            ALTER TABLE legacy_events RENAME TO work_task_events;
            PRAGMA user_version=6;
            """)
        let upgraded = try LibraryStore(root: root)
        let tasks = try await upgraded.workTasks()
        let events = try await upgraded.workTaskEvents(id)
        XCTAssertEqual(tasks.first(where: { $0.id == id })?.title, "保留已有任务")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(try database.run("SELECT * FROM work_task_events WHERE task_id=?", [id.uuidString]).first?["actor"], "user")
        XCTAssertEqual(try database.run("SELECT * FROM work_task_events WHERE to_status='candidate'").first?["actor"], "ai")
        let migrated = try XCTUnwrap(database.run("SELECT * FROM work_tasks WHERE id=?", [id.uuidString]).first)
        XCTAssertEqual(migrated["status_observed_at"], migrated["updated_at"])
    }

    func testMissingEvidenceAndInventedMemoryAreRejected() async throws {
        let store = try LibraryStore(root: root)
        for draft in [WorkTaskDraft(title: "无依据", evidence: "猜测"), WorkTaskDraft(title: "伪造来源", evidence: "猜测", memoryIDs: [UUID()])] {
            do {
                try await store.ingestTaskSuggestions([draft], allowedSourceIDs: [], allowedMemoryIDs: Set(draft.memoryIDs))
                XCTFail("Missing provenance must not create a task")
            } catch LibraryError.invalidResult { }
        }
        let tasks = try await store.workTasks()
        XCTAssertTrue(tasks.isEmpty)
    }
}
