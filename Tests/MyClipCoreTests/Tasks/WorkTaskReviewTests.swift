import XCTest
@testable import MyClipCore

@MainActor
final class WorkTaskReviewTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testUndoRestoresCandidateAndRemovesReviewFromReports() async throws {
        let store = try LibraryStore(root: root)
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        for status in [WorkTaskStatus.todo, .doing, .done, .ignored] {
            let task = try await candidate(in: store, title: "Review \(status.rawValue)")
            try await store.updateWorkTask(task.id, title: task.title, project: task.project, waitingReason: "等待确认")
            let before = try database.run("SELECT * FROM work_tasks WHERE id=?", [task.id.uuidString])
            let history = try await store.workTaskEvents(task.id)
            let review = try await store.reviewWorkTask(task.id, status: status)
            let reviewed = try await store.workTasks().first { $0.id == task.id }
            XCTAssertEqual(reviewed?.status, status)
            XCTAssertNil(reviewed?.suggestedStatus)

            try await store.undoWorkTaskReview(review)

            XCTAssertEqual(try database.run("SELECT * FROM work_tasks WHERE id=?", [task.id.uuidString]), before)
            let reopened = try LibraryStore(root: root)
            let restored = try await reopened.workTasks().first { $0.id == task.id }
            let restoredHistory = try await reopened.workTaskEvents(task.id)
            XCTAssertEqual(restored?.status, .candidate)
            XCTAssertEqual(restored?.suggestedStatus, .doing)
            XCTAssertEqual(restored?.waitingReason, "等待确认")
            XCTAssertEqual(restored?.evidence.map(\.id), task.evidence.map(\.id))
            XCTAssertEqual(restoredHistory.map(\.id), history.map(\.id))
        }
        let statistics = try await store.workTaskStatistics(days: 7)
        XCTAssertEqual(statistics.added, 0)
        XCTAssertEqual(statistics.completed, 0)
        XCTAssertEqual(statistics.unfinished, 0)
    }

    func testUndoDoesNotOverwriteALaterEdit() async throws {
        let store = try LibraryStore(root: root)
        let task = try await candidate(in: store)
        let review = try await store.reviewWorkTask(task.id, status: .doing)
        try await store.updateWorkTask(task.id, title: "Updated task", project: "New project")
        let history = try await store.workTaskEvents(task.id)

        do {
            try await store.undoWorkTaskReview(review)
            XCTFail("Undo must not replace a task that has changed since review")
        } catch LibraryError.invalidResult { }

        let current = try await store.workTasks().first
        let currentHistory = try await store.workTaskEvents(task.id)
        XCTAssertEqual(current?.title, "Updated task")
        XCTAssertEqual(current?.project, "New project")
        XCTAssertEqual(current?.status, .doing)
        XCTAssertEqual(currentHistory.map(\.id), history.map(\.id))
    }

    func testUndoRejectsLaterTransitionsEvenWithTheSameTimestampAndStatus() async throws {
        let store = try LibraryStore(root: root)
        let task = try await candidate(in: store)
        let date = Date()
        let review = try await store.reviewWorkTask(task.id, status: .todo, at: date)
        try await store.setWorkTaskStatus(task.id, status: .doing, at: date)
        try await store.setWorkTaskStatus(task.id, status: .todo, at: date)

        do {
            try await store.undoWorkTaskReview(review)
            XCTFail("Undo must not erase later status transitions")
        } catch LibraryError.invalidResult { }

        let current = try await store.workTasks().first
        let history = try await store.workTaskEvents(task.id)
        XCTAssertEqual(current?.status, .todo)
        XCTAssertEqual(history.count, 4)
    }

    func testReviewOnlyAcceptsCandidatesAndConfirmedOrIgnoredDestinations() async throws {
        let store = try LibraryStore(root: root)
        let task = try await candidate(in: store)
        do {
            _ = try await store.reviewWorkTask(task.id, status: .candidate)
            XCTFail("A review must confirm or ignore a candidate")
        } catch LibraryError.invalidResult { }

        _ = try await store.reviewWorkTask(task.id, status: .done)
        do {
            _ = try await store.reviewWorkTask(task.id, status: .todo)
            XCTFail("A stale candidate row must not change an already confirmed task")
        } catch LibraryError.invalidResult { }

        let current = try await store.workTasks().first
        let history = try await store.workTaskEvents(task.id)
        XCTAssertEqual(current?.status, .done)
        XCTAssertEqual(history.count, 2)
    }

    private func candidate(in store: LibraryStore, title: String = "Review task") async throws -> WorkTask {
        let snapshot = try await store.snapshot()
        let memory = try XCTUnwrap(snapshot.entries.first)
        try await store.ingestTaskSuggestions([
            WorkTaskDraft(title: title, project: "MyClip", suggestedStatus: .doing, evidence: "正在验证界面", memoryIDs: [memory.id])
        ], allowedSourceIDs: [], allowedMemoryIDs: [memory.id])
        let tasks = try await store.workTasks()
        return try XCTUnwrap(tasks.first { $0.title == title })
    }
}
