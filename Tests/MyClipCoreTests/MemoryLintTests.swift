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
                            body: "今天用 JEV 做路由测试，顺便看了 chat-bridge 的问题；GitHub 上的 README 没改，Claude Code 的 App 也没动。链接：[[Wiki/Projects/MyClip|MyClip]]。")
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
        XCTAssertEqual(report.longLines, ["Wiki/Projects/chat-bridge.md（1 行）"], "Root files are checked for size only")
        XCTAssertEqual(report.lines.count, 5)
    }

    func testLintNamesHubPagesAndLinesASnippetWouldCut() async throws {
        try writeMemory(path: "Wiki/Projects/Big.md", title: "Big", body: "项目概览。")
        for day in 1...MemoryLint.hubPages {
            try writeMemory(path: "Daily/2026/08/2026-08-\(String(format: "%02d", day)).md", title: "2026-08-\(day)", body: "推进 [[Wiki/Projects/Big|Big]]。")
        }
        for topic in ["检索", "发布"] {
            try writeMemory(path: "Wiki/Projects/Big/\(topic).md", title: topic, body: "属于 [[Wiki/Projects/Big|Big]]。")
        }
        try writeMemory(path: "Wiki/Archives/old.md", title: "old", body: "旧 [[Wiki/Projects/Big]]。")
        try writeMemory(path: "Wiki/Projects/Small.md", title: "Small", body: "由 [[Wiki/Projects/Big/检索|检索]] 引用。")
        let citation = " [[Daily/2026/08/2026-08-01#一个很长的小节标题用来凑长度|8/1]] 来源：截图 `\(UUID())`、`\(UUID())`"
        try writeMemory(path: "Wiki/Topics/Lines.md", title: "Lines", body: "- " + String(repeating: "短", count: 290) + citation
            + "\n- " + String(repeating: "长", count: 320) + citation + "\n\n```\n" + String(repeating: "x", count: 400) + "\n```")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let report = try await store.memoryLint()
        XCTAssertEqual(report.hubs, ["Wiki/Projects/Big.md（\(MemoryLint.hubPages) 个页面链接）"], "Sub-pages, archives and small pages do not count")
        XCTAssertEqual(report.longLines, ["Wiki/Topics/Lines.md（1 行）"], "Only what a snippet shows counts: links as labels, no citations, no code")
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("被大量页面链接的枢纽页") })
    }

    func testDeclaredAliasCountsAsAnUnlinkedMention() async throws {
        let url = root.appendingPathComponent("Memory/Wiki/Topics/ACP.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MemoryDocument.encode(id: UUID(), title: "ACP", body: "编辑器与 Agent 之间的协议。", revision: 1, agent: .codex, sourceIDs: [], path: "Wiki/Topics/ACP.md",
                                  extraMetadata: "aliases: [代理客户端协议]\n").write(to: url, atomically: true, encoding: .utf8)
        try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20", body: "读了代理客户端协议的文档。")
        try writeMemory(path: "Daily/2026/09/2026-09-21.md", title: "2026-09-21", body: "继续看 [[Wiki/Topics/ACP|代理客户端协议]]。")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let report = try await store.memoryLint()
        XCTAssertEqual(report.unlinkedMentions, ["ACP ← Daily/2026/09/2026-09-20.md"], "A linked mention is fine; an alias without a link is reported")
    }

    func testPagesNearTheCapBecomeMandatorySplitInstructions() async throws {
        let unit = "过程记录。"
        let count = (MemoryDocument.maxBodyBytes * 3 / 4 + 4_000) / unit.utf8.count
        let body = String(repeating: unit, count: count)
        try writeMemory(path: "Wiki/Projects/huge.md", title: "huge", body: body)
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let report = try await store.memoryLint()
        XCTAssertEqual(report.mustSplit, ["Wiki/Projects/huge.md（\(body.utf8.count / 1000) KB）"])
        XCTAssertFalse(report.oversized.contains { $0.hasPrefix("Wiki/Projects/huge.md") }, "One page gets one instruction, not two")
        XCTAssertEqual(report.mandatoryLines.count, 1)
        XCTAssertTrue(report.mandatoryLines.first?.contains("接近 \(MemoryDocument.maxBodyBytes / 1000) KB 上限") == true, report.mandatoryLines.description)
    }

    func testCleanVaultProducesEmptyReport() async throws {
        try writeMemory(path: "Wiki/Projects/MyClip.md", title: "MyClip", body: "截图应用。")
        try writeMemory(path: "Daily/2026/09/2026-09-20.md", title: "2026-09-20", body: "继续做 [[Wiki/Projects/MyClip|MyClip]]。")
        let store = try LibraryStore(root: root)
        let report = try await store.memoryLint()
        XCTAssertTrue(report.isEmpty, "\(report)")
        XCTAssertTrue(report.lines.isEmpty)
    }

    func testLintMovesReadingRecordsOutOfTopicsAndInbox() async throws {
        try writeMemory(path: "Wiki/Topics/Hoy for macOS产品页浏览.md", title: "Hoy for macOS产品页浏览", body: "看了产品页。")
        try writeMemory(path: "Wiki/Topics/赵家驹UTMB访谈（四）.md", title: "赵家驹UTMB访谈（四）", body: "访谈内容。")
        try writeMemory(path: "Inbox/X上的AI Agent交易收益说法.md", title: "X上的AI Agent交易收益说法", body: "未核实。")
        try writeMemory(path: "Wiki/Topics/Cursor.md", title: "Cursor", body: "编辑器。")
        try writeMemory(path: "Wiki/Reading/某篇报道.md", title: "某篇报道", body: "已在正确位置。")
        try writeMemory(path: "Inbox/MyClip权限与采集状态.md", title: "MyClip权限与采集状态", body: "需要确认。")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let report = try await store.memoryLint()
        XCTAssertEqual(report.misfiled, ["Inbox/X上的AI Agent交易收益说法.md", "Wiki/Topics/Hoy for macOS产品页浏览.md", "Wiki/Topics/赵家驹UTMB访谈（四）.md"])
        XCTAssertTrue(report.lines.contains { $0.contains("移到 Wiki/Reading") })
        XCTAssertTrue(report.mandatoryLines.isEmpty, "Misfiled pages are a hint, not a blocking instruction")
    }

    func testLintFlagsPastEventsOnlyInsideCurrentState() async throws {
        let past = #"<!-- myclip-event {"start":"2026-09-10T00:00:00+08:00","end":"2026-09-11T00:00:00+08:00","precision":"day","evidence":"9月10日"} -->"#
        let future = #"<!-- myclip-event {"start":"2026-10-10T00:00:00+08:00","end":"2026-10-11T00:00:00+08:00","precision":"day","evidence":"10月10日"} -->"#
        let source = UUID(), cite = "来源：截图 `\(source)`。"
        func write(_ path: String, _ title: String, _ body: String) throws {
            let url = root.appendingPathComponent("Memory/\(path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MemoryDocument.encode(id: UUID(), title: title, body: body, revision: 1, agent: .codex, sourceIDs: [source], path: path).write(to: url, atomically: true, encoding: .utf8)
        }
        try write("Now.md", "Now", "# Now\n\n## 下一步\n\n\(past)\n计划 9月10日 提交审核。\(cite)\n\n\(future)\n计划 10月10日 发布。\(cite)\n\n计划 9月10日 前修好（无标注）。\n")
        try write("Wiki/Projects/MyClip.md", "MyClip", "应用。\n\n## 当前状态\n\n\(past)\n9月10日 开始内测。\(cite)\n\n## 关键背景\n\n\(past)\n9月10日 确定了名字。\(cite)\n")
        try write("Daily/2026/09/2026-09-10.md", "2026-09-10", "\(past)\n9月10日 的记录。\(cite)\n")
        let now = ISO8601DateFormatter().date(from: "2026-09-23T00:00:00Z")!
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let report = try await store.memoryLint(now: now)
        XCTAssertEqual(report.expired.count, 2, "\(report.expired)")
        XCTAssertTrue(report.expired[0].hasPrefix("Now.md「计划 9月10日 提交审核。"), report.expired[0])
        XCTAssertTrue(report.expired[1].hasPrefix("Wiki/Projects/MyClip.md「9月10日 开始内测。"), report.expired[1])
        XCTAssertTrue(report.lines.first?.hasPrefix("当前状态里的事件时间已过") == true, "\(report.lines)")
    }

    func testLintNamesSensitiveValuesWithoutRepeatingThem() async throws {
        try writeMemory(path: "Inbox/登录.md", title: "登录", body: "收到验证码 482913，已登录。")
        try writeMemory(path: "Wiki/Topics/OpenRouter.md", title: "OpenRouter", body: "配置了 sk-or-v1-abcdefghijklmnopqrstuvwxyz0123。")
        try writeMemory(path: "Wiki/Topics/安全.md", title: "安全", body: "验证码已发送。来源：截图 `1234abcd-0000-4000-8000-000000000000`。版本 2026。")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let report = try await store.memoryLint()
        XCTAssertEqual(report.sensitive, ["Inbox/登录.md（验证码）", "Wiki/Topics/OpenRouter.md（密钥）"])
        let instructions = report.lines.joined(separator: "\n")
        XCTAssertTrue(report.lines.first?.hasPrefix("疑似保存了验证码或密钥") == true)
        XCTAssertFalse(instructions.contains("482913"))
        XCTAssertFalse(instructions.contains("abcdefghijklmnop"))
    }

    func testDeclaredAliasCountsAsAKnownName() async throws {
        let url = root.appendingPathComponent("Memory/Wiki/Topics/JEV.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MemoryDocument.encode(id: UUID(), title: "JEV", body: "路由框架。", revision: 1, agent: .codex, sourceIDs: [], path: "Wiki/Topics/JEV.md",
                                  extraMetadata: "aliases: [TypeSafe-Router]\n").write(to: url, atomically: true, encoding: .utf8)
        for day in ["18", "19", "20"] {
            try writeMemory(path: "Daily/2026/09/2026-09-\(day).md", title: "2026-09-\(day)", body: "测试 TypeSafe-Router 路由。")
        }
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let report = try await store.memoryLint()
        XCTAssertFalse(report.candidateEntities.contains { $0.hasPrefix("TypeSafe-Router") }, "\(report.candidateEntities)")
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
        nearCap.mustSplit = ["Wiki/Projects/chat-bridge.md（60 KB）"]
        let urgent = OrganizationHandoff.make(job: job, captures: [], changedPaths: [], deletedCount: 0, completedAt: Date(), lint: nearCap,
            rolledBack: ["Wiki/Projects/big.md（Memory 正文 70 KB，超过 64 KB 上限。）"])
        let mandatoryStart = try XCTUnwrap(urgent.range(of: "必须先处理"))
        let softStart = try XCTUnwrap(urgent.range(of: "整理提示"))
        XCTAssertLessThan(mandatoryStart.lowerBound, softStart.lowerBound, "Instructions come before soft hints")
        XCTAssertTrue(urgent.contains("Wiki/Projects/chat-bridge.md（60 KB） 接近 \(MemoryDocument.maxBodyBytes / 1000) KB 上限"), urgent)
        XCTAssertTrue(urgent.contains("上一批写入 Wiki/Projects/big.md"), urgent)
        var huge = MemoryLintReport()
        huge.unlinkedMentions = (0..<200).map { "名称\($0) ← " + String(repeating: "Daily/2026/09/2026-09-20.md, ", count: 3) }
        let bounded = OrganizationHandoff.make(job: job, captures: [], changedPaths: [], deletedCount: 0, completedAt: Date(), lint: huge)
        XCTAssertLessThanOrEqual(bounded.utf8.count, 6_000)
    }
}
