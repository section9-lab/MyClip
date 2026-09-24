import XCTest
@testable import MyClipCore

final class MemoryPromptTests: XCTestCase {
    func testRetryPromptCarriesThePreviousAttempt() {
        let note = LibraryError.rolledBack("Wiki/Projects/chat-bridge.md（Memory 正文 129 KB，超过 128 KB 上限。）").localizedDescription
        let prompt = MemoryPrompt.filePrompt(inputs: [], handoff: nil, previousAttempt: note)
        XCTAssertTrue(prompt.contains("本批上次尝试未完成：已恢复上一版：Wiki/Projects/chat-bridge.md"), prompt)
        XCTAssertTrue(prompt.contains("先整理"), prompt)
        XCTAssertTrue(prompt.contains("仍然过长再按主题拆分"), prompt)
        XCTAssertFalse(MemoryPrompt.filePrompt(inputs: []).contains("上次尝试"))
    }

    func testConsolidationPromptStaysWithinScopeAndAddsNoFacts() {
        let plan = ConsolidationPlan(changed: ["Wiki/Projects/MyClip.md"], neighbours: ["Wiki/Topics/ACP.md"], weekly: nil)
        let prompt = MemoryPrompt.consolidationPrompt(plan: plan, handoff: "整理提示：……")
        XCTAssertTrue(prompt.contains("- Wiki/Projects/MyClip.md（今天改动）"))
        XCTAssertTrue(prompt.contains("- Wiki/Topics/ACP.md（相邻页面）"))
        XCTAssertTrue(prompt.contains("不新增事实"))
        XCTAssertTrue(prompt.contains("不直接写入 Profile.md"))
        XCTAssertTrue(prompt.contains("整理提示：……"))
        XCTAssertFalse(prompt.contains("周汇总"))
        XCTAssertFalse(prompt.contains("{\"tasks\""), "The review returns no task JSON")
    }

    func testOrganizingPromptNamesNewFoldersAliasesAndDailySplit() {
        let prompt = MemoryPrompt.filePrompt(inputs: [])
        for phrase in ["Wiki/People 只放与用户有实际往来的人", "- Wiki/Reading：外部文章", "aliases: [名称一, 名称二]", "Daily/YYYY/MM/YYYY-MM-DD/主题.md", "外部观点和浏览记录不进 Inbox"] {
            XCTAssertTrue(prompt.contains(phrase), phrase)
        }
        XCTAssertTrue(MemoryPrompt.coldStartPrompt(files: []).contains("人物放 Wiki/People"))
    }

    func testOrganizingPromptIsGroupedByWhatTheAgentDecides() {
        let prompt = MemoryPrompt.organizeBatchPrompt(inputs: [], handoff: "交接", tasks: [])
        let sections = ["【任务】", "【处理流程】", "【底线原则】", "【什么值得写进 Memory】", "【每类页面】", "【通用写法】", "【示例】", "【交接记录】", "【本批资料】", "【返回】"]
        let lines = prompt.components(separatedBy: "\n")
        let positions = sections.map { section -> Int in
            let headers = lines.indices.filter { lines[$0].hasPrefix(section) }
            XCTAssertEqual(headers.count, 1, "\(section) heads exactly one block")
            return headers.first ?? -1
        }
        XCTAssertEqual(positions, positions.sorted(), "Sections follow the working order")
        XCTAssertTrue(prompt.contains("优先于其他所有规则"), "The principles say they win conflicts")
        XCTAssertFalse(prompt.contains("不要返回代写文件的 JSON"), "The reply carries only the task JSON, stated once")
        XCTAssertEqual(prompt.components(separatedBy: "Now.md：只列当前重点").count, 2, "Each page type is described in one place")
        let dream = MemoryPrompt.consolidationPrompt(plan: ConsolidationPlan(misfiled: [], changed: ["Now.md"], neighbours: []), handoff: nil)
        XCTAssertTrue(dream.contains("【每类页面】") && !dream.contains("【返回】"), "Reviews share the rules but return no task JSON")
        XCTAssertTrue(MemoryPrompt.coldStartPrompt(files: []).contains("本次资料是文件而不是截图"), "Cold start maps screenshot wording to its files")
    }

    func testEntityPagesUseDatedFactLinesAndEditsStayLocal() {
        let prompt = MemoryPrompt.filePrompt(inputs: [])
        XCTAssertTrue(prompt.contains("[[Daily/2026/09/2026-09-20#路由超时排查|9/20]]"), "Fact lines link the Daily section that holds the details")
        XCTAssertTrue(prompt.contains("约 120 字以内") && prompt.contains("约 \(GraphConstants.excerptLimit * GraphConstants.passagesPerHit) 字"), "One fact per line, sized for snippets")
        XCTAssertTrue(prompt.contains("Wiki/Projects/项目名/主题.md"), "Work streams get their own pages instead of one hub")
        XCTAssertTrue(prompt.contains("只替换受影响的 ## 小节"), "Edits replace sections, not whole pages")
        let dream = MemoryPrompt.consolidationPrompt(plan: ConsolidationPlan(misfiled: [], changed: ["Daily/2026/09/2026-09-20.md"], neighbours: []), handoff: nil)
        XCTAssertTrue(dream.contains("补实体页"), "Dreams build pages for names mentioned in several places")
    }

    func testOrganizerSeparatesObservationFromEventTime() {
        let prompt = MemoryPrompt.filePrompt(captures: [])
        XCTAssertFalse(prompt.contains("截图时间是事实发生的时间"))
        XCTAssertTrue(prompt.contains("myclip-event"))
        XCTAssertTrue(prompt.contains("相对日期"))
        XCTAssertTrue(prompt.contains("未知"))
    }

    func testScreenshotOrganizationAlsoRequestsTaskEvidence() {
        let prompt = MemoryPrompt.filePrompt(captures: [])
        XCTAssertTrue(prompt.contains("\"tasks\""))
        XCTAssertTrue(prompt.contains("suggestedStatus"))
        XCTAssertTrue(prompt.contains("evidence"))
    }
}
