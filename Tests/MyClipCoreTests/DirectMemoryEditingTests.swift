import XCTest
@testable import MyClipCore

@MainActor
final class DirectMemoryEditingTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testAgentWrittenFileGetsIndexedWithScreenshotSources() async throws {
        let store = try LibraryStore(root: root)
        let capture = fixtureContext()
        try await store.record(image: fixtureImage(), context: capture, agent: .claude, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let file = root.appendingPathComponent("Memory/Wiki/Topics/直接整理.md")
        let body = "# 直接整理\n\n由 Agent 通过文件工具写入。参见 [[Now]]。"
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
        try "# 项目\n\n第一批事实。".write(to: file, atomically: true, encoding: .utf8)
        _ = try await store.finishMemoryEditing(jobID: firstJob.id, previousRevisions: baseline)
        let original = try await store.readMemory(path: "Wiki/Projects/项目.md")

        let next = fixtureContext(at: 130)
        try await store.record(image: fixtureImage(changed: true), context: next, agent: .codex, organize: true)
        let nextClaim = try await store.claimNextJob(immediately: true)
        let nextJob = try XCTUnwrap(nextClaim)
        let before = try await store.beginMemoryEditing(jobID: nextJob.id)
        try "# 项目\n\n第一批事实。\n第二批补充。".write(to: file, atomically: true, encoding: .utf8)
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
}
