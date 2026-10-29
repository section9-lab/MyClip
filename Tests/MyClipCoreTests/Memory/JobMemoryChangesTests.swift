import XCTest
@testable import MyClipCore

@MainActor
final class JobMemoryChangesTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func claim(_ store: LibraryStore) async throws -> ClipJob {
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .workbuddy, organize: true)
        let job = try await store.claimNextJob(immediately: true)
        return try XCTUnwrap(job)
    }

    func testDiskWritesAndDeletionAreRecordedWithoutToolReportsAndSurviveReopening() async throws {
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let removedURL = root.appendingPathComponent("Memory/Wiki/Topics/Removed.md")
        try "# Removed\n\nOld page.".write(to: removedURL, atomically: true, encoding: .utf8)
        let removed = try await store.readMemory(path: "Wiki/Topics/Removed.md")
        let job = try await claim(store)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        try "# Now\n\nUpdated through a command.".write(to: root.appendingPathComponent("Memory/Now.md"), atomically: true, encoding: .utf8)
        try "# New page\n\nCreated through a command.".write(to: root.appendingPathComponent("Memory/Wiki/Topics/New.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: removedURL)
        _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)

        let reopened = try LibraryStore(root: root)
        let snapshot = try await reopened.snapshot()
        let changes = try XCTUnwrap(snapshot.jobs.first?.memoryChanges)
        XCTAssertEqual(changes.written.map(\.path), ["Now.md", "Wiki/Topics/New.md"])
        XCTAssertEqual(changes.deletedIDs, [removed.id])
        XCTAssertEqual(changes.count, 3)
        for file in changes.written {
            XCTAssertTrue(snapshot.entries.contains { $0.id == file.id && $0.relativePath == file.path })
        }
        let tools = try await reopened.executionRecords(jobID: job.id)
        XCTAssertTrue(tools.isEmpty, "Actual results do not depend on ACP edit events")
    }

    func testReadOnlyRunIsDistinctFromAnOldJobWithNoRecordedResult() async throws {
        let store = try LibraryStore(root: root)
        let job = try await claim(store)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let legacy = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        try legacy.script("DROP TABLE job_memory_changes;")
        let reopened = try LibraryStore(root: root)
        let oldSnapshot = try await reopened.snapshot()
        XCTAssertNil(oldSnapshot.jobs.first?.memoryChanges)
        _ = try String(contentsOf: root.appendingPathComponent("Memory/Now.md"), encoding: .utf8)
        _ = try await reopened.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.memoryChanges?.count, 0)
    }

    func testRejectedFileIsExcludedAndValidWritesSurviveARetry() async throws {
        let store = try LibraryStore(root: root)
        let job = try await claim(store)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let rejected = root.appendingPathComponent("Memory/Profile.md")
        let saved = try String(contentsOf: rejected, encoding: .utf8)
        try "".write(to: rejected, atomically: true, encoding: .utf8)
        try "# Accepted\n\nA valid change.".write(to: root.appendingPathComponent("Memory/Wiki/Topics/Accepted.md"), atomically: true, encoding: .utf8)
        do {
            _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
            XCTFail("The invalid edit must be rolled back")
        } catch LibraryError.rolledBack { }
        XCTAssertEqual(try String(contentsOf: rejected, encoding: .utf8), saved)
        let again = try await store.beginMemoryEditing(jobID: job.id)
        _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: again)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.state, .completed)
        XCTAssertEqual(snapshot.jobs.first?.memoryChanges?.written.map(\.path), ["Wiki/Topics/Accepted.md"])
    }

    func testDreamRecordsSavedFilesToo() async throws {
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let queued = try await store.enqueueDreamNow(agent: .workbuddy)
        let dream = try XCTUnwrap(queued)
        _ = try await store.claimNextJob(immediately: true, jobID: dream.id)
        let before = try await store.beginConsolidation()
        try "# Dream\n\nSaved by consolidation.".write(to: root.appendingPathComponent("Memory/Wiki/Topics/Dream.md"), atomically: true, encoding: .utf8)
        _ = try await store.finishDream(jobID: dream.id, previousRevisions: before)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.jobs.first?.memoryChanges?.written.map(\.path), ["Wiki/Topics/Dream.md"])
    }
}
