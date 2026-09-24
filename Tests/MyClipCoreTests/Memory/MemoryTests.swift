import XCTest
@testable import MyClipCore

@MainActor
final class MemoryTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func seed(_ store: LibraryStore) async throws -> KnowledgeEntry {
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        try await store.commit(jobID: XCTUnwrap(claimed).id, drafts: [KnowledgeDraft(kind: .wiki, title: "截图规则", body: "回车记录焦点窗口。", sourceIDs: [context.id])])
        let snapshot = try await store.snapshot()
        return try XCTUnwrap(snapshot.entries.first)
    }

    func testLegacyWikiBecomesMemoryWithStableMarkdownPath() async throws {
        let store = try LibraryStore(root: root)
        let entry = try await seed(store)
        XCTAssertEqual(entry.kind, .memory)
        XCTAssertEqual(entry.fileURL.deletingLastPathComponent().lastPathComponent, "Wiki")
        try await store.updateEntry(id: entry.id, title: "新的标题", body: entry.body, expectedRevision: entry.revision)
        let updated = try await store.snapshot().entries.first
        XCTAssertEqual(updated?.fileURL, entry.fileURL, "Renaming must preserve Wikilink targets")
        XCTAssertEqual(updated?.revision, 2)
    }

    func testExternalMarkdownEditIsSearchableAndAdvancesRevision() async throws {
        let store = try LibraryStore(root: root)
        let entry = try await seed(store)
        let original = try String(contentsOf: entry.fileURL, encoding: .utf8)
        try original.replacingOccurrences(of: "回车记录焦点窗口。", with: "人工修订后的重要信息").write(to: entry.fileURL, atomically: true, encoding: .utf8)
        let found = try await store.snapshot(query: "人工修订")
        XCTAssertEqual(found.entries.count, 1)
        XCTAssertEqual(found.entries.first?.revision, 2)
    }

    func testAgentCannotOverwriteManuallyEditedMemory() async throws {
        let store = try LibraryStore(root: root)
        let entry = try await seed(store)
        try await store.updateEntry(id: entry.id, title: entry.title, body: "人工确认的内容", expectedRevision: 1)
        try await store.enqueue(sourceIDs: entry.sourceIDs, agent: .claude)
        let claimed = try await store.claimNextJob(immediately: true)
        do {
            try await store.commit(jobID: XCTUnwrap(claimed).id, drafts: [KnowledgeDraft(entryID: entry.id, expectedRevision: 2, kind: .memory, title: entry.title, body: "Agent 替换的内容", sourceIDs: entry.sourceIDs)])
            XCTFail("Human edits must become a reviewable proposal, not be overwritten")
        } catch LibraryError.conflict { }
        let current = try await store.snapshot().entries.first
        XCTAssertEqual(current?.body, "人工确认的内容")
    }

    func testGeneratedLinksCannotPointAtInventedMemory() async throws {
        let store = try LibraryStore(root: root)
        let entry = try await seed(store)
        try await store.enqueue(sourceIDs: entry.sourceIDs, agent: .codex)
        let claimed = try await store.claimNextJob(immediately: true)
        do {
            try await store.commit(jobID: XCTUnwrap(claimed).id, drafts: [KnowledgeDraft(kind: .memory, title: "关联", body: "参见 [[不存在的记忆]]", sourceIDs: entry.sourceIDs)])
            XCTFail("Agent must not invent link targets")
        } catch LibraryError.invalidResult { }
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.entries.filter { !$0.isRootDocument }.count, 1)
    }

    func testWikilinksIgnoreCodeAndKeepBacklinksAfterTitleChange() async throws {
        let store = try LibraryStore(root: root)
        let target = try await seed(store)
        try await store.enqueue(sourceIDs: target.sourceIDs, agent: .codex)
        let claimed = try await store.claimNextJob(immediately: true)
        try await store.commit(jobID: XCTUnwrap(claimed).id, drafts: [KnowledgeDraft(kind: .memory, title: "关联规则", body: "参考 [[\(target.id.uuidString)|规则]]\n\n`[[不是链接]]`\n\n```md\n[[代码示例]]\n```", sourceIDs: target.sourceIDs)])
        try await store.updateEntry(id: target.id, title: "新规则标题", body: target.body, expectedRevision: 1)
        let relation = try await store.relations(target.id)
        XCTAssertEqual(relation.incoming.map(\.title), ["关联规则"])
        let other = try XCTUnwrap(relation.incoming.first)
        let outgoing = try await store.relations(other.id)
        XCTAssertEqual(outgoing.outgoing.map(\.id), [target.id])
        XCTAssertTrue(outgoing.unresolved.isEmpty)
    }

    func testUnclosedCodeFenceDoesNotCreateMemoryLinks() {
        XCTAssertTrue(Wikilink.parse("```md\n[[example]]").isEmpty)
    }

    func testProposalApprovalChecksTheVersionActuallyReviewed() async throws {
        let store = try LibraryStore(root: root)
        let entry = try await seed(store)
        try await store.updateEntry(id: entry.id, title: entry.title, body: "人工确认", expectedRevision: 1)
        try await store.enqueue(sourceIDs: entry.sourceIDs, agent: .claude)
        let claimed = try await store.claimNextJob(immediately: true)
        let id = try XCTUnwrap(claimed).id
        do { try await store.commit(jobID: id, drafts: [KnowledgeDraft(entryID: entry.id, expectedRevision: 2, kind: .memory, title: entry.title, body: "建议的新版本", sourceIDs: entry.sourceIDs)]) }
        catch LibraryError.conflict { }
        let proposals = try await store.proposals()
        XCTAssertEqual(proposals.count, 1)
        try await store.updateEntry(id: entry.id, title: entry.title, body: "后来又编辑", expectedRevision: 2)
        do { try await store.acceptProposal(id, revisions: [entry.id: 2]); XCTFail("Stale approval must not overwrite a newer edit") }
        catch LibraryError.conflict { }
        try await store.acceptProposal(id, revisions: [entry.id: 3])
        let final = try await store.readMemory(entry.id)
        XCTAssertEqual(final.body, "建议的新版本")
        XCTAssertEqual(final.revision, 4)
        let remaining = try await store.proposals()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testStatisticsUseAllRecordsAndRespectTimeRange() async throws {
        let store = try LibraryStore(root: root)
        for date in [100.0, 120.0, 300.0] { try await store.record(image: fixtureImage(), context: fixtureContext(at: date), agent: .codex, organize: false) }
        let all = try await store.statistics()
        XCTAssertEqual(all.captures, 3)
        XCTAssertEqual(all.uniqueImages, 1)
        XCTAssertEqual(all.applications.first?.count, 3)
        let recent = try await store.statistics(since: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(recent.captures, 1)
        XCTAssertEqual(recent.uniqueImages, 1)
        XCTAssertGreaterThan(recent.storageBytes, 0)
        XCTAssertNil(recent.averageSeconds)
    }

    func testPublishedFilesLeaveBatchContextInHistoryAndLegacyFilesAreSlimmedOnce() async throws {
        let id = UUID(), cited = UUID(), context = (0..<50).map { _ in UUID() }
        let url = root.appendingPathComponent("Memory/Wiki/Archives/旧版.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = try MemoryDocument.encode(id: id, title: "旧版", body: "事实。来源：截图 `\(cited)`。", revision: 3, agent: .codex, sourceIDs: [cited],
                                               path: "Inbox/旧版.md", contextSourceIDs: context)
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        _ = try await LibraryStore(root: root).snapshot()
        // Simulate a library written before v12: the published file still carries the full frontmatter.
        let database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        let stored = try XCTUnwrap(database.run("SELECT path FROM entries WHERE id=?", [id.uuidString]).first?["path"])
        let full = try String(contentsOf: root.appendingPathComponent(stored), encoding: .utf8)
        try full.write(to: url, atomically: true, encoding: .utf8)
        try database.run("UPDATE memory_files SET published_hash=?,pending=0 WHERE id=?", [LibraryStore.memoryHash(full), id.uuidString])
        try database.script("PRAGMA user_version=11;")

        let store = try LibraryStore(root: root)
        let before = try await store.readMemory(id)
        let published = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(published.contains("context_source_ids"), "Migration rewrites every file once without the batch context")
        XCTAssertTrue(published.contains("\nsource_ids: [\(cited.uuidString)]\n"))
        XCTAssertTrue(published.contains("\ntype: archive\n"), "The type follows the folder")
        XCTAssertEqual(Set(before.contextSourceIDs), Set(context), "The history keeps the context")
        let reread = try await store.readMemory(id)
        XCTAssertEqual(before.revision, reread.revision, "Slimming is not an edit")
        let protected = try database.run("SELECT id FROM protected_entries WHERE id=?", [id.uuidString])
        XCTAssertEqual(protected.count, 1, "Imported files were protected before; slimming must not change that")

        // An external edit of the slim file keeps the context the file no longer shows.
        try published.replacingOccurrences(of: "事实。", with: "修改后的事实。").write(to: url, atomically: true, encoding: .utf8)
        let edited = try await store.readMemory(id)
        XCTAssertTrue(edited.body.contains("修改后的事实"))
        XCTAssertEqual(edited.revision, before.revision + 1)
        XCTAssertEqual(Set(edited.contextSourceIDs), Set(context))
        XCTAssertEqual(edited.sourceIDs, [cited])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("context_source_ids"))
    }

    func testRebuiltIndexRecoversContextFromHistory() async throws {
        let store = try LibraryStore(root: root)
        let memory = try await seed(store)
        let url = memory.fileURL
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("context_source_ids"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Library.sqlite"))
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: root.appendingPathComponent("Library.sqlite" + suffix)) }
        let rebuilt = try LibraryStore(root: root)
        let recovered = try await rebuilt.readMemory(memory.id)
        XCTAssertEqual(recovered.sourceIDs, memory.sourceIDs)
        XCTAssertEqual(recovered.contextSourceIDs, memory.contextSourceIDs)
    }

    func testMarkdownVaultCanRebuildMemoryIndexInFreshLibrary() async throws {
        let store = try LibraryStore(root: root)
        let memory = try await seed(store)
        let restoredRoot = root.appendingPathComponent("Restored")
        try FileManager.default.createDirectory(at: restoredRoot.appendingPathComponent("Memory"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: memory.fileURL, to: restoredRoot.appendingPathComponent("Memory/\(memory.id.uuidString).md"))
        let restored = try LibraryStore(root: restoredRoot)
        let snapshot = try await restored.snapshot(query: "回车")
        XCTAssertEqual(snapshot.entries.first?.id, memory.id)
        XCTAssertEqual(snapshot.entries.first?.body, memory.body)
        XCTAssertEqual(snapshot.entries.first?.sourceIDs, memory.sourceIDs, "Keep provenance IDs even when images are not included in the vault backup")
        let service = MemoryMCP(store: restored)
        _ = await service.respond("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}")
        let response = await service.respond("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_get\",\"arguments\":{\"path\":\"\(memory.id.uuidString).md\"}}}")
        XCTAssertTrue(response?.contains("\"isError\":false") == true, "Missing source metadata must not fail the whole retrieval")
        XCTAssertTrue(response?.contains("\"count\":0") == true, "Missing source metadata is reported as no recorded screenshots")
    }
}
