import XCTest
import CoreGraphics
@testable import MyClipCore

func fixtureImage(changed: Bool = false, x: Int = 4) throws -> CapturedImage {
    let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    if changed {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: x, y: 4, width: 1, height: 1))
    }
    return try CapturedImage(image: XCTUnwrap(context.makeImage()))
}

func fixtureContext(at time: TimeInterval = 100, windowID: UInt32 = 1) -> CaptureContext {
    CaptureContext(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "窗口采集规则", windowID: windowID, reason: .pointerIdle, date: Date(timeIntervalSince1970: time))
}

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
        XCTAssertEqual(recovered.jobs.filter { $0.state == .failed }.count, 1)
        XCTAssertEqual(recovered.queue.pendingCount, 1)
        XCTAssertTrue(recovered.queue.paused)
        try await reopened.retryJob(id: XCTUnwrap(first).id)
        let resumed = try await reopened.claimNextJob(immediately: true, jobID: first?.id)
        XCTAssertEqual(resumed?.id, first?.id)
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
