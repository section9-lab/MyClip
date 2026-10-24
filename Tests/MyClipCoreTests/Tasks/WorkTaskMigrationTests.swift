import XCTest
@testable import MyClipCore

@MainActor
final class WorkTaskMigrationTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testUpgradeMovesCandidatesIntoAIStatusesAndPreservesEvidenceAndHistory() async throws {
        let store = try LibraryStore(root: root)
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        let snapshot = try await store.snapshot()
        let memory = try XCTUnwrap(snapshot.entries.first)
        let statuses: [WorkTaskStatus] = [.todo, .doing, .done]
        var ids: [WorkTaskStatus: UUID] = [:]
        for status in statuses {
            let title = "Legacy \(status.rawValue)"
            try await store.ingestTaskSuggestions([WorkTaskDraft(title: title, suggestedStatus: status, evidence: "保留的原文", memoryIDs: [memory.id])],
                allowedSourceIDs: [], allowedMemoryIDs: [memory.id], at: Date(timeIntervalSince1970: 100))
            let tasks = try await store.workTasks()
            let id = try XCTUnwrap(tasks.first { $0.title == title }?.id)
            ids[status] = id
            try database.run("UPDATE work_tasks SET status='candidate',suggested_status=?,confirmed_at=NULL,completed_at=NULL,waiting_reason='等待环境' WHERE id=?", [status.rawValue, id.uuidString])
            try database.run("UPDATE work_task_events SET to_status='candidate' WHERE task_id=?", [id.uuidString])
        }
        let evidence = try database.run("SELECT * FROM work_task_evidence ORDER BY id")
        try database.script("PRAGMA user_version=15;")
        let before = Date()
        let upgraded = try LibraryStore(root: root)
        let after = Date()
        let tasks = try await upgraded.workTasks()
        for status in statuses {
            let id = try XCTUnwrap(ids[status])
            let task = try XCTUnwrap(tasks.first { $0.id == id })
            XCTAssertEqual(task.status, status)
            XCTAssertEqual(task.createdAt, Date(timeIntervalSince1970: 100))
            XCTAssertEqual(task.statusObservedAt, Date(timeIntervalSince1970: 100), "Upgrading is not a new observation")
            let entered = try XCTUnwrap(task.confirmedAt)
            XCTAssertTrue(entered >= before && entered <= after)
            XCTAssertEqual(task.completedAt, status == .done ? entered : nil)
            XCTAssertEqual(task.waitingReason, status == .done ? "" : "等待环境")
            let events = try await upgraded.workTaskEvents(id)
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events.first?.to, .candidate, "Keep history so past reports do not gain unconfirmed work")
            XCTAssertEqual(events.last?.from, .candidate)
            XCTAssertEqual(events.last?.to, status)
            XCTAssertEqual(events.last?.actor, .ai)
        }
        XCTAssertEqual(try database.run("SELECT * FROM work_task_evidence ORDER BY id"), evidence)
        XCTAssertEqual(try database.run("PRAGMA user_version").first?["user_version"], "16")
        let history = try await upgraded.workTaskEvents()
        let reopened = try LibraryStore(root: root)
        let repeatedHistory = try await reopened.workTaskEvents()
        XCTAssertEqual(repeatedHistory.map(\.id), history.map(\.id), "Migration must not run twice")
        let historical = WorkTaskReport(period: .day, containing: Date(timeIntervalSince1970: 100), tasks: tasks,
            events: history, now: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(historical.isEmpty)
    }

    func testMigrationDefaultsCandidatesToTodoAndKeepsIgnoredTasksOffBoard() async throws {
        let store = try LibraryStore(root: root)
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        for suggestion in [nil, "candidate", "ignored", "unknown"] as [String?] {
            let id = try await store.createWorkTask(title: "Fallback \(suggestion ?? "nil")")
            try database.run("UPDATE work_tasks SET status='candidate',suggested_status=?,confirmed_at=NULL WHERE id=?", [suggestion, id.uuidString])
            try database.run("UPDATE work_task_events SET to_status='candidate',actor='ai' WHERE task_id=?", [id.uuidString])
        }
        let ignored = try await store.createWorkTask(title: "Keep ignored")
        try await store.setWorkTaskStatus(ignored, status: .ignored)
        try database.run("UPDATE work_tasks SET suggested_status='doing' WHERE id=?", [ignored.uuidString])
        try database.script("PRAGMA user_version=15;")
        let upgraded = try LibraryStore(root: root)
        let tasks = try await upgraded.workTasks()
        XCTAssertEqual(tasks.filter { $0.status == .todo }.count, 4)
        XCTAssertEqual(tasks.first { $0.id == ignored }?.status, .ignored)
        XCTAssertTrue(try database.run("SELECT id FROM work_tasks WHERE suggested_status IS NOT NULL").isEmpty)
    }

    func testLegacyCandidateCannotBeSelectedOrReintroduced() async throws {
        XCTAssertEqual(WorkTaskStatus.allCases, [.todo, .doing, .done, .ignored])
        let store = try LibraryStore(root: root)
        let id = try await store.createWorkTask(title: "保持直接入板")
        do {
            try await store.setWorkTaskStatus(id, status: .candidate)
            XCTFail("Candidate is a history-only status")
        } catch LibraryError.invalidResult { }
        let tasks = try await store.workTasks()
        XCTAssertEqual(tasks.first?.status, .todo)
    }
}
