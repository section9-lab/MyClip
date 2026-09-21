import XCTest
@testable import MyClipCore

@MainActor
final class MemoryLayoutTests: XCTestCase {
    func testPlainMarkdownFilesAreImportedAndSearchable() async throws {
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let file = root.appendingPathComponent("Memory/Wiki/Topics/普通文件.md")
        try "# 普通文件\n\nAgent 直接写入的记忆，参见 [[Now]]。".write(to: file, atomically: true, encoding: .utf8)
        let result = try await store.snapshot(query: "直接写入")
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.relativePath, "Wiki/Topics/普通文件.md")
        XCTAssertEqual(entry.title, "普通文件")
        XCTAssertTrue(entry.body.contains("[[Now]]"))
        let reopened = try LibraryStore(root: root)
        let imported = try await reopened.readMemory(path: entry.relativePath)
        XCTAssertEqual(imported.id, entry.id)
    }

    func testPlainMarkdownOverwritePreservesIdentityAndSources() async throws {
        let store = try LibraryStore(root: root)
        let previous = try await seed(store)
        try "# 修改后的标题\n\n通过 Bash 修改的正文。".write(to: previous.fileURL, atomically: true, encoding: .utf8)
        let current = try await store.readMemory(path: previous.relativePath)
        XCTAssertEqual(current.id, previous.id)
        XCTAssertEqual(current.sourceIDs, previous.sourceIDs)
        XCTAssertGreaterThan(current.revision, previous.revision)
        XCTAssertEqual(current.title, "修改后的标题")
        XCTAssertTrue(current.body.contains("通过 Bash 修改"))
    }

    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func seed(_ store: LibraryStore) async throws -> KnowledgeEntry {
        let source = fixtureContext()
        try await store.record(image: fixtureImage(), context: source, agent: .codex, organize: true)
        let job = try await store.claimNextJob(immediately: true)
        try await store.commit(jobID: XCTUnwrap(job).id, drafts: [KnowledgeDraft(kind: .memory, title: "截图规则", body: "应用焦点截图。", sourceIDs: [source.id])])
        let notes = try await store.snapshot().entries
        return try XCTUnwrap(notes.first { !$0.isRootDocument })
    }

    func testNewLibraryCreatesThreeRootDocumentsAndFolders() async throws {
        let store = try LibraryStore(root: root)
        let snapshot = try await store.snapshot()
        for name in ["Memory.md", "Profile.md", "Now.md", "Wiki/Projects", "Wiki/Topics", "Wiki/Workflows", "Daily", "Inbox"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Memory/" + name).path), name)
        }
        XCTAssertEqual(Set(snapshot.entries.map { $0.fileURL.lastPathComponent }), ["Memory.md", "Profile.md", "Now.md"])
        let again = try await store.snapshot()
        XCTAssertEqual(Set(snapshot.entries.map(\.id)), Set(again.entries.map(\.id)))
    }

    func testSnapshotReflectsEmptyFoldersAndExternalDirectoryChanges() async throws {
        let store = try LibraryStore(root: root)
        let directory = root.appendingPathComponent("Memory")
        let custom = directory.appendingPathComponent("Wiki/Research/Empty")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(Set(snapshot.memoryFolders), Set(MemoryLayout.folders + ["Wiki/Research", "Wiki/Research/Empty"]))

        try FileManager.default.removeItem(at: custom.deletingLastPathComponent())
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Wiki/Topics"))
        let updated = try await store.snapshot(query: "不存在的关键词")
        XCTAssertEqual(Set(updated.memoryFolders), Set(MemoryLayout.folders.filter { $0 != "Wiki/Topics" }))
    }

    func testExternalMoveAndDeleteDoNotResurrectOldFiles() async throws {
        let store = try LibraryStore(root: root)
        let old = try await seed(store)
        let id = old.id
        let destination = root.appendingPathComponent("Memory/Wiki/Projects/重新命名.md")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old.fileURL, to: destination)
        let moved = try await store.readMemory(id)
        XCTAssertEqual(moved.fileURL, destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.fileURL.path))
        try FileManager.default.removeItem(at: destination)
        let snapshot = try await store.snapshot()
        XCTAssertFalse(snapshot.entries.contains { $0.id == id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Entries/\(id.uuidString)/1.md").path))
    }

    func testMCPReadsRootAndNestedPagesByRelativePath() async throws {
        let store = try LibraryStore(root: root)
        let entry = try await seed(store)
        let service = MemoryMCP(store: store)
        _ = await service.respond("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")
        let paths = ["Memory.md", "Profile.md", "Now.md", "Wiki/" + entry.fileURL.lastPathComponent]
        for path in paths {
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "read_memory", "arguments": ["path": path]]]
            let response = await service.respond(String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!)
            let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(response).utf8)) as? [String: Any])
            let result = try XCTUnwrap(decoded["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false, path)
            XCTAssertEqual((result["structuredContent"] as? [String: Any])?["path"] as? String, path)
        }
    }

    func testAgentRoutesNewPagesAndCannotMoveExistingPages() async throws {
        let store = try LibraryStore(root: root)
        let note = try await seed(store)
        try await store.enqueue(sourceIDs: note.sourceIDs, agent: .codex)
        let job = try await store.claimNextJob(immediately: true)
        try await store.commit(jobID: XCTUnwrap(job).id, drafts: [KnowledgeDraft(kind: .memory, title: "项目", body: "引用 [[Memory]]", sourceIDs: note.sourceIDs, path: "Wiki/Projects/MyClip.md")])
        let created = try await store.snapshot().entries.first { $0.title == "项目" }
        XCTAssertEqual(created?.relativePath, "Wiki/Projects/MyClip.md")
        try await store.enqueue(sourceIDs: note.sourceIDs, agent: .codex)
        let update = try await store.claimNextJob(immediately: true)
        do {
            try await store.commit(jobID: XCTUnwrap(update).id, drafts: [KnowledgeDraft(entryID: note.id, expectedRevision: note.revision, kind: .memory, title: note.title, body: "新内容", sourceIDs: note.sourceIDs, path: "Inbox/偷偷移动.md")])
            XCTFail("An Agent update must keep the existing path")
        } catch LibraryError.invalidResult { }
    }

    func testAgentRejectsUnsafePathsWithoutWritingPartialBatch() async throws {
        let store = try LibraryStore(root: root)
        let note = try await seed(store)
        try await store.enqueue(sourceIDs: note.sourceIDs, agent: .codex)
        let job = try await store.claimNextJob(immediately: true)
        for path in ["../escape.md", "/tmp/escape.md", "Wiki/../escape.md", "Wiki//empty.md", "Wiki/test.txt", "Profile.md"] {
            do {
                try await store.commit(jobID: XCTUnwrap(job).id, drafts: [KnowledgeDraft(kind: .memory, title: "拒绝", body: "不应保存", sourceIDs: note.sourceIDs, path: path)])
                XCTFail("Reject \(path)")
            } catch { }
        }
        let notes = try await store.snapshot().entries.filter { !$0.isRootDocument }
        XCTAssertEqual(notes.map(\.id), [note.id])
    }

    func testProfileIsProtectedBeforeFirstManualEdit() async throws {
        let store = try LibraryStore(root: root)
        let note = try await seed(store)
        let profile = try await store.readMemory(path: "Profile.md")
        try await store.enqueue(sourceIDs: note.sourceIDs, agent: .codex)
        let job = try await store.claimNextJob(immediately: true)
        do {
            try await store.commit(jobID: XCTUnwrap(job).id, drafts: [KnowledgeDraft(entryID: profile.id, expectedRevision: profile.revision, kind: .memory, title: profile.title, body: "未经确认的身份", sourceIDs: note.sourceIDs, path: "Profile.md")])
            XCTFail("Profile changes need review")
        } catch LibraryError.conflict { }
        let unchanged = try await store.readMemory(path: "Profile.md")
        XCTAssertEqual(unchanged.body, profile.body)
        let proposals = try await store.proposals()
        XCTAssertEqual(proposals.count, 1)
    }

    func testExternalRenameRepairsPathLinksAndBacklinksButNotCode() async throws {
        let store = try LibraryStore(root: root)
        let note = try await seed(store)
        let index = try await store.readMemory(path: "Memory.md")
        let link = String(note.relativePath.dropLast(3))
        try await store.updateEntry(id: index.id, title: index.title, body: "[[\(link)|截图]]\n\n`[[\(link)]]`", expectedRevision: index.revision)
        let movedPath = "Wiki/Topics/窗口截图.md"
        try FileManager.default.moveItem(at: note.fileURL, to: root.appendingPathComponent("Memory/" + movedPath))
        let moved = try await store.readMemory(note.id)
        XCTAssertEqual(moved.relativePath, movedPath)
        let current = try await store.readMemory(index.id)
        XCTAssertEqual(current.body, "[[Wiki/Topics/窗口截图|截图]]\n\n`[[\(link)]]`")
        let relations = try await store.relations(note.id)
        XCTAssertEqual(relations.incoming.map(\.id), [index.id])
        let oldLink = try await store.resolveMemoryLink(link)
        XCTAssertEqual(oldLink.id, note.id)
    }

    func testDuplicateIDsAndSymlinksFailWithoutChangingIndex() async throws {
        let store = try LibraryStore(root: root)
        let note = try await seed(store)
        let copied = root.appendingPathComponent("Memory/Inbox/copy.md")
        try FileManager.default.copyItem(at: note.fileURL, to: copied)
        do { _ = try await store.snapshot(); XCTFail("Duplicate IDs must be rejected") }
        catch LibraryError.invalidResult { }
        try FileManager.default.removeItem(at: copied)
        try FileManager.default.createSymbolicLink(at: copied, withDestinationURL: note.fileURL)
        do { _ = try await store.readMemory(path: "Inbox/copy.md"); XCTFail("Symlinks must not be followed") }
        catch LibraryError.invalidResult { }
        try FileManager.default.removeItem(at: copied)
        let current = try await store.readMemory(note.id)
        XCTAssertEqual(current.revision, note.revision)
    }

    func testComposerDescribesFolderRolesAndPathLinks() throws {
        let prompt = KnowledgeComposer.prompt(captures: [], existing: [])
        for path in ["Memory.md", "Profile.md", "Now.md", "Wiki/Projects", "Wiki/Topics", "Wiki/Workflows", "Daily", "Inbox"] {
            XCTAssertTrue(prompt.contains(path), path)
        }
        XCTAssertTrue(prompt.contains("\"path\""))
    }

    func testMoveKeepsIdentityRepairsLinksAndRejectsStaleVersionOrRoot() async throws {
        let store = try LibraryStore(root: root)
        let note = try await seed(store)
        let index = try await store.readMemory(path: "Memory.md")
        try await store.updateEntry(id: index.id, title: index.title, body: "[[\(note.relativePath)|截图]]", expectedRevision: index.revision)
        try await store.moveMemory(note.id, to: "Wiki/Projects/新名称.md", expectedRevision: note.revision)
        let moved = try await store.readMemory(note.id)
        XCTAssertEqual(moved.relativePath, "Wiki/Projects/新名称.md")
        XCTAssertEqual(moved.body, note.body)
        XCTAssertEqual(moved.sourceIDs, note.sourceIDs)
        XCTAssertEqual(moved.revision, note.revision + 1)
        XCTAssertTrue(try String(contentsOf: moved.fileURL, encoding: .utf8).contains("type: project\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
        let updatedIndex = try await store.readMemory(index.id)
        XCTAssertEqual(updatedIndex.body, "[[Wiki/Projects/新名称.md|截图]]")
        try await store.updateEntry(id: moved.id, title: moved.title, body: "人工修订", expectedRevision: moved.revision)
        do { try await store.moveMemory(moved.id, to: "Inbox/stale.md", expectedRevision: moved.revision); XCTFail("Stale move") }
        catch LibraryError.conflict { }
        let profile = try await store.readMemory(path: "Profile.md")
        do { try await store.moveMemory(profile.id, to: "Inbox/Profile.md", expectedRevision: profile.revision); XCTFail("Root file must stay at root") }
        catch LibraryError.invalidResult { }
    }

    func testRejectedBatchLeavesNoPublishedPages() async throws {
        let store = try LibraryStore(root: root)
        let note = try await seed(store)
        try await store.enqueue(sourceIDs: note.sourceIDs, agent: .codex)
        let job = try await store.claimNextJob(immediately: true)
        do {
            try await store.commit(jobID: XCTUnwrap(job).id, drafts: [
                KnowledgeDraft(kind: .memory, title: "有效", body: "正文", sourceIDs: note.sourceIDs, path: "Inbox/未提交.md"),
                KnowledgeDraft(kind: .memory, title: "无效", body: "正文", sourceIDs: note.sourceIDs, path: "../逃逸.md")
            ])
            XCTFail("Invalid batch must fail")
        } catch LibraryError.invalidResult { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Memory/Inbox/未提交.md").path))
        let found = try await store.searchMemories(query: "有效")
        XCTAssertTrue(found.isEmpty)
    }

    func testExternalMetadataSurvivesManualEdit() async throws {
        let store = try LibraryStore(root: root)
        let note = try await seed(store)
        let text = try String(contentsOf: note.fileURL, encoding: .utf8)
        try text.replacingOccurrences(of: "\n---\n", with: "\ntags: [capture, personal]\ncustom:\n  value: example\n---\n").write(to: note.fileURL, atomically: true, encoding: .utf8)
        let imported = try await store.readMemory(note.id)
        try await store.updateEntry(id: note.id, title: note.title, body: "新的正文", expectedRevision: imported.revision)
        let updated = try String(contentsOf: note.fileURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("tags: [capture, personal]\ncustom:\n  value: example"))
        let reloaded = try await store.readMemory(note.id)
        XCTAssertEqual(reloaded.revision, imported.revision + 1)
    }

    func testInitializationCannotCreateFoldersThroughSymlinks() async throws {
        for path in ["Memory", "Memory/Wiki"] {
            let library = root.appendingPathComponent(UUID().uuidString)
            let outside = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let link = library.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let store = try LibraryStore(root: library)
            do { _ = try await store.snapshot(); XCTFail("Symlinked directories must be rejected") }
            catch LibraryError.invalidResult { }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, path)
        }
    }

    func testInvalidFileKeepsLastIndexAndDoesNotBlockTheVault() async throws {
        let store = try LibraryStore(root: root)
        let previous = try await seed(store)
        let text = try String(contentsOf: previous.fileURL, encoding: .utf8)
        let boundary = try XCTUnwrap(text.range(of: "\n---\n"))
        let header = String(text[..<boundary.upperBound])
        try (header + "\n  \n").write(to: previous.fileURL, atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("Memory/Inbox/空白.md"), atomically: true, encoding: .utf8)

        let snapshot = try await store.snapshot(query: "焦点")
        XCTAssertEqual(snapshot.invalidMemoryFiles, ["Inbox/空白.md（Memory 正文为空。）", "\(previous.relativePath)（Memory 正文为空。）"])
        let kept = try await store.readMemory(path: previous.relativePath)
        XCTAssertEqual(kept.body, previous.body, "The last good revision stays searchable")
        XCTAssertEqual(snapshot.entries.map(\.id), [previous.id])
        let lint = try await store.memoryLint()
        XCTAssertTrue(lint.invalidFiles.contains("Inbox/空白.md（Memory 正文为空。）"), lint.invalidFiles.description)

        try (header + "修好的正文。\n").write(to: previous.fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Memory/Inbox/空白.md"))
        let repaired = try await store.snapshot()
        XCTAssertEqual(repaired.invalidMemoryFiles, [])
        let fixed = try await store.readMemory(path: previous.relativePath)
        XCTAssertEqual(fixed.body, "修好的正文。\n")
    }

    func testDisplayMarkdownCompactsCitationLinesOnly() {
        let body = """
        # 页面

        结论一。来源：截图 `721EBDBB-76BA-424D-BE5B-236AA99FA154`（2026-09-18T11:13:56Z）、`C9ED70FE-8E1B-41E8-9BD5-DF2BC6C10AC8`。
        正文提到 ID 721EBDBB-76BA-424D-BE5B-236AA99FA154 保持原样。
        ```
        来源：截图 `721EBDBB-76BA-424D-BE5B-236AA99FA154` 代码块不动
        ```
        - 来源: 58B93C99-1949-483E-9025-63B7B6175776 (2026-09-18)
        """
        let shown = MemoryDocument.displayMarkdown(body)
        XCTAssertTrue(shown.contains("结论一。来源：截图 `721EBDBB`、`C9ED70FE`。"), shown)
        XCTAssertTrue(shown.contains("正文提到 ID 721EBDBB-76BA-424D-BE5B-236AA99FA154 保持原样。"))
        XCTAssertTrue(shown.contains("`721EBDBB-76BA-424D-BE5B-236AA99FA154` 代码块不动"))
        XCTAssertTrue(shown.contains("- 来源: `58B93C99`"), shown)
    }
}
