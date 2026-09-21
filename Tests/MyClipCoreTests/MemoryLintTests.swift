import XCTest
@testable import MyClipCore

@MainActor
final class MemoryLintTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func writeMemory(path: String, title: String, body: String) throws {
        let url = root.appendingPathComponent("Memory/\(path)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MemoryDocument.encode(id: UUID(), title: title, body: body, revision: 1, agent: .codex, sourceIDs: [], path: path).write(to: url, atomically: true, encoding: .utf8)
    }

    func testLintReportsBrokenLinksUnlinkedMentionsCandidatesAndOversizedPages() async throws {
        try writeMemory(path: "Wiki/Projects/chat-bridge.md", title: "chat-bridge", body: "桥接项目。" + String(repeating: "过程记录。", count: 2_500))
        try writeMemory(path: "Wiki/Projects/MyClip.md", title: "MyClip", body: "截图应用。参见 [[Wiki/Topics/不存在的页面#章节|旧页]]。")
        for day in ["18", "19", "20"] {
            try writeMemory(path: "Daily/2026/09/2026-09-\(day).md", title: "2026-09-\(day)",
                            body: "今天用 JEV 做路由测试，顺便看了 chat-bridge 的问题；GitHub 上的 README 没改。链接：[[Wiki/Projects/MyClip|MyClip]]。")
        }
        try writeMemory(path: "Wiki/Archives/old.md", title: "old", body: "JEV JEV JEV，chat-bridge 旧记录。")
        let store = try LibraryStore(root: root)
        let now = try await store.readMemory(path: "Now.md")
        try await store.updateEntry(id: now.id, title: now.title, body: String(repeating: "当前重点。", count: 1_300), expectedRevision: now.revision)
        let report = try await store.memoryLint()
        XCTAssertEqual(report.brokenLinks, ["Wiki/Topics/不存在的页面#章节 ← Wiki/Projects/MyClip.md"])
        XCTAssertEqual(report.unlinkedMentions.count, 1)
        XCTAssertTrue(report.unlinkedMentions[0].hasPrefix("chat-bridge ← Daily/2026/09/2026-09-18.md"), report.unlinkedMentions[0])
        XCTAssertEqual(report.candidateEntities, ["JEV（3 个文件）"], "Archives, stop words, titles and linked pages are not candidates")
        XCTAssertEqual(report.oversized.count, 2)
        XCTAssertTrue(report.oversized.contains { $0.hasPrefix("Now.md（") })
        XCTAssertTrue(report.oversized.contains { $0.hasPrefix("Wiki/Projects/chat-bridge.md（") })
        XCTAssertEqual(report.lines.count, 4)
    }

    func testPagesNearTheCapBecomeMandatorySplitInstructions() async throws {
        try writeMemory(path: "Wiki/Projects/huge.md", title: "huge", body: String(repeating: "过程记录。", count: 7_000))
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let report = try await store.memoryLint()
        XCTAssertEqual(report.mustSplit, ["Wiki/Projects/huge.md（105 KB）"])
        XCTAssertFalse(report.oversized.contains { $0.hasPrefix("Wiki/Projects/huge.md") }, "One page gets one instruction, not two")
        XCTAssertEqual(report.mandatoryLines.count, 1)
        XCTAssertTrue(report.mandatoryLines.first?.contains("接近 128 KB 上限") == true, report.mandatoryLines.description)
    }

    func testCleanVaultProducesEmptyReport() async throws {
        try writeMemory(path: "Wiki/Projects/MyClip.md", title: "MyClip", body: "截图应用。")
        try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20", body: "继续做 [[Wiki/Projects/MyClip|MyClip]]。")
        let store = try LibraryStore(root: root)
        let report = try await store.memoryLint()
        XCTAssertTrue(report.isEmpty, "\(report)")
        XCTAssertTrue(report.lines.isEmpty)
    }

    func testHandoffCarriesLintFindingsWithinBudget() throws {
        let job = ClipJob(id: UUID(), agent: .codex, state: .completed, createdAt: Date(), sourceIDs: [], error: nil)
        var report = MemoryLintReport()
        report.candidateEntities = ["JEV（3 个文件）"]
        let handoff = OrganizationHandoff.make(job: job, captures: [], changedPaths: ["Wiki/Projects/MyClip.md"], deletedCount: 0, completedAt: Date(), lint: report)
        XCTAssertTrue(handoff.contains("整理提示"))
        XCTAssertTrue(handoff.contains("JEV（3 个文件）"))
        XCTAssertTrue(handoff.contains("更新：Wiki/Projects/MyClip.md"))
        var nearCap = MemoryLintReport()
        nearCap.mustSplit = ["Wiki/Projects/chat-bridge.md（125 KB）"]
        let urgent = OrganizationHandoff.make(job: job, captures: [], changedPaths: [], deletedCount: 0, completedAt: Date(), lint: nearCap,
            rolledBack: ["Wiki/Projects/big.md（Memory 正文 130 KB，超过 128 KB 上限。）"])
        let mandatoryStart = try XCTUnwrap(urgent.range(of: "必须先处理"))
        let softStart = try XCTUnwrap(urgent.range(of: "整理提示"))
        XCTAssertLessThan(mandatoryStart.lowerBound, softStart.lowerBound, "Instructions come before soft hints")
        XCTAssertTrue(urgent.contains("Wiki/Projects/chat-bridge.md（125 KB） 接近 128 KB 上限"), urgent)
        XCTAssertTrue(urgent.contains("上一批写入 Wiki/Projects/big.md"), urgent)
        var huge = MemoryLintReport()
        huge.unlinkedMentions = (0..<200).map { "名称\($0) ← " + String(repeating: "Daily/2026/09/2026-09-20.md, ", count: 3) }
        let bounded = OrganizationHandoff.make(job: job, captures: [], changedPaths: [], deletedCount: 0, completedAt: Date(), lint: huge)
        XCTAssertLessThanOrEqual(bounded.utf8.count, 6_000)
    }
}
