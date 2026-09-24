import XCTest
import CoreGraphics
@testable import MyClipCore

@MainActor
final class LibraryStoreTests: XCTestCase {
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testScreenshotTextSearchPreservesRepeatedOccurrences() async throws {
        let store = try LibraryStore(root: directory)
        let image = try fixtureImage()
        try await store.record(image: image, context: fixtureContext(), agent: .codex, organize: false, extractedText: "上海出差，整理客户会议纪要。")
        try await store.record(image: image, context: fixtureContext(at: 120), agent: .codex, organize: false)
        let results = try await store.snapshot(query: "出差")
        XCTAssertEqual(results.captures.count, 2)
        let needsIndex = try await store.imageNeedsTextIndex(image.fingerprint)
        XCTAssertFalse(needsIndex)
    }

    func testRecordedTextCreatesUTF8DocumentBesideOriginal() async throws {
        let store = try LibraryStore(root: directory)
        let image = try fixtureImage()
        let text = "上海客户会议\nMyClip screenshot notes"
        try await store.record(image: image, context: fixtureContext(), agent: .codex, organize: false, extractedText: text)
        let document = directory.appendingPathComponent("Images/\(image.fingerprint).txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), text)
    }

    func testBackgroundIndexCreatesDocumentForRepeatedCaptures() async throws {
        let store = try LibraryStore(root: directory)
        let image = try fixtureImage()
        try await store.record(image: image, context: fixtureContext(), agent: .codex, organize: false)
        try await store.record(image: image, context: fixtureContext(at: 200), agent: .codex, organize: false)
        try await store.indexImageText(id: image.fingerprint, text: "后台提取\nShared document")
        let document = directory.appendingPathComponent("Images/\(image.fingerprint).txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "后台提取\nShared document")
        let files = try FileManager.default.contentsOfDirectory(at: document.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "txt" }.count, 1)
    }

    func testBlankScreenshotStillHasAnEmptyDocument() async throws {
        let store = try LibraryStore(root: directory)
        let image = try fixtureImage()
        try await store.record(image: image, context: fixtureContext(), agent: .codex, organize: false)
        try await store.indexImageText(id: image.fingerprint, text: "")
        let document = directory.appendingPathComponent("Images/\(image.fingerprint).txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "")
        let pending = try await store.nextImageForTextIndex()
        XCTAssertNil(pending)
    }

    func testReopeningLibraryRestoresDocumentsFromExistingOCRIndex() async throws {
        let store = try LibraryStore(root: directory)
        let image = try fixtureImage()
        try await store.record(image: image, context: fixtureContext(), agent: .codex, organize: false, extractedText: "旧截图的文字")
        let document = directory.appendingPathComponent("Images/\(image.fingerprint).txt")
        if FileManager.default.fileExists(atPath: document.path) { try FileManager.default.removeItem(at: document) }
        _ = try LibraryStore(root: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "旧截图的文字")
    }

    func testExpirationRemovesOCRDocumentAndLateIndexCannotRestoreIt() async throws {
        let store = try LibraryStore(root: directory)
        let image = try fixtureImage()
        try await store.record(image: image, context: fixtureContext(), agent: .codex, organize: false, extractedText: "临时内容")
        let document = directory.appendingPathComponent("Images/\(image.fingerprint).txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
        try await store.expireImages(before: Date(timeIntervalSince1970: 500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.path))
        try await store.indexImageText(id: image.fingerprint, text: "过期结果")
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.path))
    }

    func testIndexRebuildReadsAuthoritativeMarkdown() async throws {
        let store = try LibraryStore(root: directory)
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        try await store.commit(jobID: job.id, drafts: [KnowledgeDraft(kind: .wiki, title: "文档", body: "初始正文", sourceIDs: [context.id])])
        let snapshot = try await store.snapshot()
        let entry = try XCTUnwrap(snapshot.entries.first)
        let original = try String(contentsOf: entry.fileURL, encoding: .utf8)
        try original.replacingOccurrences(of: "初始正文", with: "更新后的中文检索内容").write(to: entry.fileURL, atomically: true, encoding: .utf8)
        try await store.rebuildSearchIndex()
        let found = try await store.snapshot(query: "检索")
        XCTAssertEqual(found.entries.count, 1)
    }

    func testImageExpirationAlsoRemovesRawRecognizedText() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: false, extractedText: "原图中的临时信息")
        try await store.expireImages(before: Date(timeIntervalSince1970: 500))
        let found = try await store.snapshot(query: "临时信息")
        XCTAssertTrue(found.captures.isEmpty)
        let all = try await store.snapshot()
        XCTAssertEqual(all.captures.count, 1)
    }

    func testRetentionNeverRemovesUnexpiredScreenshotsAcrossRestart() async throws {
        let store = try LibraryStore(root: directory)
        let image = try fixtureImage()
        try await store.record(image: image, context: fixtureContext(at: 1000), agent: .codex, organize: false)
        try await store.expireImages(before: Date(timeIntervalSince1970: 900))
        let reopened = try LibraryStore(root: directory)
        try await reopened.expireImages(before: Date(timeIntervalSince1970: 900))
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.imageCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(snapshot.captures.first).imageURL.path))
    }

    func testBackgroundTextIndexResumesAndCannotReviveExpiredText() async throws {
        let store = try LibraryStore(root: directory)
        let image = try fixtureImage()
        try await store.record(image: image, context: fixtureContext(), agent: .codex, organize: false)
        let pending = try await store.nextImageForTextIndex()
        XCTAssertEqual(pending?.id, image.fingerprint)
        try await store.indexImageText(id: image.fingerprint, text: "后台识别")
        let indexed = try await store.snapshot(query: "后台")
        XCTAssertEqual(indexed.captures.count, 1)
        let next = try await store.nextImageForTextIndex()
        XCTAssertNil(next)
        try await store.expireImages(before: Date(timeIntervalSince1970: 500))
        try await store.indexImageText(id: image.fingerprint, text: "不应恢复过期文本")
        let expired = try await store.snapshot(query: "过期")
        XCTAssertTrue(expired.captures.isEmpty)
    }

    func testOnePixelChangeIsPreserved() throws {
        let a = try fixtureImage()
        let b = try fixtureImage(changed: true)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
        XCTAssertFalse(a.pngData.isEmpty)
    }

    func testDuplicatePixelsShareStorageButPreserveEveryOccurrence() async throws {
        let store = try LibraryStore(root: directory)
        let image = try fixtureImage()
        try await store.record(image: image, context: fixtureContext(), agent: .codex, organize: true)
        try await store.record(image: image, context: fixtureContext(at: 103), agent: .codex, organize: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.captures.count, 2)
        XCTAssertEqual(snapshot.imageCount, 1)
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertEqual(snapshot.queue.pendingCount, 1)
        if snapshot.captures.count == 2 {
            XCTAssertEqual(snapshot.captures[0].imageURL, snapshot.captures[1].imageURL)
        }
    }

    func testRevisitingTomorrowIsANewEventAndProcessingJob() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        try await store.record(image: fixtureImage(), context: fixtureContext(at: 86_500), agent: .claude, organize: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.imageCount, 1)
        XCTAssertEqual(snapshot.captures.count, 2)
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertEqual(snapshot.queue.pendingCounts, [.codex: 1, .claude: 1])
    }

    func testQueueDoesNotCancelRunningJobAndSurvivesRestart() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        let first = try await store.claimNextJob(immediately: true)
        XCTAssertNotNil(first)
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 105), agent: .claude, organize: true)
        let live = try await store.snapshot()
        XCTAssertEqual(live.jobs.filter { $0.state == .running }.count, 1)
        XCTAssertEqual(live.queue.pendingCount, 1)
        let reopened = try LibraryStore(root: directory)
        try await reopened.recoverInterruptedJobs()
        let recovered = try await reopened.snapshot()
        XCTAssertEqual(recovered.captures.count, 2)
        // The interrupted batch keeps its sources and waits for an automatic retry; nothing is lost or paused.
        XCTAssertEqual(recovered.jobs.filter(\.isAwaitingRetry).count, 1)
        XCTAssertEqual(recovered.jobs.filter { $0.state == .failed }.count, 0)
        XCTAssertEqual(recovered.queue.pendingCount, 2)
        XCTAssertFalse(recovered.queue.paused)
        let resumed = try await reopened.claimNextJob(immediately: true, jobID: first?.id)
        XCTAssertEqual(resumed?.id, first?.id)
        XCTAssertEqual(resumed?.attempts, 2)
    }

    func testCommitCreatesMarkdownAndChineseShortWordSearchWithSources() async throws {
        let store = try LibraryStore(root: directory)
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        try await store.commit(jobID: job.id, drafts: [KnowledgeDraft(kind: .wiki, title: "焦点窗口", body: "回车触发截图，只保存当前应用。", sourceIDs: [context.id])])
        let results = try await store.snapshot(query: "回车")
        XCTAssertEqual(results.entries.count, 1)
        let entry = try XCTUnwrap(results.entries.first)
        XCTAssertEqual(entry.sourceIDs, [context.id])
        XCTAssertTrue(try String(contentsOf: entry.fileURL, encoding: .utf8).contains("回车触发截图"))
        let all = try await store.snapshot()
        XCTAssertEqual(all.jobs.first?.state, .completed)
    }

    func testCommitRejectsInventedSourceAndKeepsJobUncommitted() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        do {
            try await store.commit(jobID: job.id, drafts: [KnowledgeDraft(kind: .memory, title: "偏好", body: "不可验证", sourceIDs: [UUID()])])
            XCTFail("Invented sources must be rejected")
        } catch LibraryError.invalidResult { }
        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.entries.filter { !$0.isRootDocument }.isEmpty)
        XCTAssertEqual(snapshot.jobs.first?.state, .running)
    }

    func testExpiredImagesKeepKnowledgeAndSearchableProvenance() async throws {
        let store = try LibraryStore(root: directory)
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        try await store.commit(jobID: job.id, drafts: [KnowledgeDraft(kind: .memory, title: "焦点窗口", body: "只截窗口。", sourceIDs: [context.id])])
        try await store.expireImages(before: Date(timeIntervalSince1970: 200))
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.entries.filter { !$0.isRootDocument }.count, 1)
        XCTAssertEqual(snapshot.captures.count, 1)
        let capture = try XCTUnwrap(snapshot.captures.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.imageURL.path))
    }

    func testPendingScreenshotsBatchWithoutChangingProviderOrActiveInput() async throws {
        let store = try LibraryStore(root: directory)
        for index in 0..<3 {
            try await store.record(image: fixtureImage(changed: true, x: index), context: fixtureContext(at: 100 + Double(index)), agent: .codex, organize: true)
        }
        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertEqual(snapshot.queue.pendingCount, 3)
        let claimed = try await store.claimNextJob(immediately: true)
        let running = try XCTUnwrap(claimed)
        try await store.record(image: fixtureImage(changed: true, x: 8), context: fixtureContext(at: 104), agent: .codex, organize: true)
        let active = try await store.snapshot()
        XCTAssertEqual(active.jobs.first { $0.id == running.id }?.sourceIDs.count, 3)
        XCTAssertEqual(active.queue.pendingCount, 1)
    }

    func testManualQueueAndFailureRetryPreserveSources() async throws {
        let store = try LibraryStore(root: directory)
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: false)
        try await store.enqueue(sourceIDs: [context.id], agent: .claude)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        let sources = try await store.captures(ids: job.sourceIDs)
        XCTAssertEqual(sources.map(\.id), [context.id])
        try await store.finishJob(id: job.id, state: .failed, error: "Offline")
        try await store.retryJob(id: job.id)
        let retried = try await store.claimNextJob(immediately: true)
        XCTAssertEqual(retried?.id, job.id)
        XCTAssertEqual(retried?.agent, .claude)
    }

    func testRetentionDoesNotDeletePendingInput() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(), agent: .codex, organize: true)
        try await store.expireImages(before: Date(timeIntervalSince1970: 200))
        let snapshot = try await store.snapshot()
        let capture = try XCTUnwrap(snapshot.captures.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.imageURL.path))
    }

    func testEditingChecksRevisionAndDeletingRemovesSearchResult() async throws {
        let store = try LibraryStore(root: directory)
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        try await store.commit(jobID: job.id, drafts: [KnowledgeDraft(kind: .memory, title: "语言偏好", body: "中文", sourceIDs: [context.id])])
        let first = try await store.snapshot()
        let entry = try XCTUnwrap(first.entries.first)
        try await store.updateEntry(id: entry.id, title: entry.title, body: "中文与英文", expectedRevision: 1)
        do {
            try await store.updateEntry(id: entry.id, title: entry.title, body: "过期编辑", expectedRevision: 1)
            XCTFail("Stale edits must not overwrite newer content")
        } catch LibraryError.conflict { }
        let revised = try await store.snapshot(query: "英文")
        XCTAssertEqual(revised.entries.first?.revision, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path))
        try await store.deleteEntry(id: entry.id)
        let deleted = try await store.snapshot(query: "英文")
        XCTAssertTrue(deleted.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.fileURL.path))
    }
}

/// A 320×320 "window" with text lines; `cursor` adds a caret, `scrolled` shifts the lines, `dark` repaints everything.
func sceneFixtureImage(cursor: Bool = false, scrolled: Bool = false, dark: Bool = false) throws -> CapturedImage {
    let size = 320
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: dark ? 0.1 : 0.96, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(CGColor(gray: dark ? 0.9 : 0.15, alpha: 1))
    for line in stride(from: 30, to: size - 30, by: 20) {
        let offset = scrolled ? 10 : 0
        context.fill(CGRect(x: 20, y: line + offset, width: 120 + (line * 7) % 160, height: 8))
    }
    if cursor { context.fill(CGRect(x: 160, y: 150, width: 2, height: 12)) }
    return try CapturedImage(image: XCTUnwrap(context.makeImage()))
}

@MainActor
final class SceneFoldingTests: XCTestCase {
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCursorBlinkReusesImageAndIsNotQueuedTwice() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: sceneFixtureImage(), context: fixtureContext(at: 100), agent: .claude, organize: true)
        try await store.record(image: sceneFixtureImage(cursor: true), context: fixtureContext(at: 140), agent: .claude, organize: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.captures.count, 2, "Every occurrence stays on record")
        XCTAssertEqual(snapshot.imageCount, 1, "The second frame adds nothing, so it shares the first image")
        XCTAssertEqual(snapshot.captures[0].imageID, snapshot.captures[1].imageID)
        XCTAssertEqual(snapshot.captures[0].sceneID, snapshot.captures[1].sceneID)
        XCTAssertEqual(snapshot.queue.pendingCount, 1, "The Agent sees the picture once")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Images").path).filter { $0.hasSuffix(".png") }.count, 1)
    }

    func testScrolledContentStoresANewImageInsideTheSameScene() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: sceneFixtureImage(), context: fixtureContext(at: 100), agent: .claude, organize: true)
        try await store.record(image: sceneFixtureImage(scrolled: true), context: fixtureContext(at: 160), agent: .claude, organize: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.imageCount, 2)
        XCTAssertEqual(snapshot.queue.pendingCount, 2)
        XCTAssertEqual(snapshot.captures[0].sceneID, snapshot.captures[1].sceneID, "Same window, a minute apart: one scene for the Timeline")
    }

    func testManualScreenshotsAlwaysKeepTheirOwnQueueEntry() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: sceneFixtureImage(), context: fixtureContext(at: 100), agent: .claude, organize: true)
        var manual = fixtureContext(at: 130)
        manual.reason = .manual
        try await store.record(image: sceneFixtureImage(cursor: true), context: manual, agent: .claude, organize: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.imageCount, 2)
        XCTAssertEqual(snapshot.queue.pendingCount, 2)
    }

    func testGapAndOtherWindowStartNewScenes() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: sceneFixtureImage(), context: fixtureContext(at: 100), agent: .claude, organize: true)
        try await store.record(image: sceneFixtureImage(cursor: true), context: fixtureContext(at: 100 + LibraryStore.sceneGap + 1), agent: .claude, organize: true)
        try await store.record(image: sceneFixtureImage(cursor: true), context: fixtureContext(at: 100 + LibraryStore.sceneGap + 30, windowID: 2), agent: .claude, organize: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(Set(snapshot.captures.map(\.sceneID)).count, 3)
        XCTAssertEqual(snapshot.imageCount, 2, "After the gap the cursor frame is compared to nothing and stored")
        XCTAssertEqual(snapshot.queue.pendingCount, 3)
    }

    func testTinyImagesKeepPixelExactComparison() async throws {
        let store = try LibraryStore(root: directory)
        try await store.record(image: fixtureImage(), context: fixtureContext(at: 100), agent: .claude, organize: true)
        try await store.record(image: fixtureImage(changed: true), context: fixtureContext(at: 110), agent: .claude, organize: true)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.imageCount, 2)
        XCTAssertEqual(snapshot.queue.pendingCount, 2)
    }

    func testLegacyCapturesAreGroupedIntoScenesOnMigration() async throws {
        let store = try LibraryStore(root: directory)
        for offset in [0.0, 40, 80, 500, 540] {
            try await store.record(image: fixtureImage(changed: true, x: Int(offset) % 60), context: fixtureContext(at: 1000 + offset), agent: .claude, organize: false)
        }
        try await store.record(image: fixtureImage(changed: true, x: 3), context: fixtureContext(at: 1010, windowID: 9), agent: .claude, organize: false)
        let database = try SQLiteConnection(url: directory.appendingPathComponent("Library.sqlite"))
        try database.script("UPDATE captures SET scene_id=NULL; PRAGMA user_version=10;")
        let migrated = try LibraryStore(root: directory)
        let snapshot = try await migrated.snapshot()
        let byWindow = Dictionary(grouping: snapshot.captures, by: \.windowID)
        XCTAssertEqual(Set(byWindow[1]!.map(\.sceneID)).count, 2, "A 7 minute gap splits the window into two scenes")
        XCTAssertEqual(Set(byWindow[9]!.map(\.sceneID)).count, 1)
        XCTAssertEqual(try database.run("PRAGMA user_version").first?["user_version"], "15")
    }
}
