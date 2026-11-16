import XCTest
@testable import MyClipCore

/// The two pipelines: the batch records the day, the hourly digest turns it into knowledge.
@MainActor
final class PipelinePromptTests: XCTestCase {
    func testRealTimePipelineOnlyWritesDaily() {
        let prompt = DayPrompt.daily(captures: [])
        XCTAssertTrue(prompt.contains("Daily/YYYY/MM/YYYY-MM-DD.md"))
        XCTAssertTrue(prompt.contains("Daily/YYYY/MM/YYYY-MM-DD/主题.md"))
        XCTAssertTrue(prompt.contains("不要修改 Wiki/ 下的任何页面、Memory.md、Profile.md、Now.md"))
        XCTAssertTrue(prompt.contains("不要调用看板或日历工具"))
        XCTAssertFalse(prompt.contains("{\"tasks\""), "The batch no longer returns task JSON")
        XCTAssertFalse(prompt.contains("calendar_add"))
        XCTAssertTrue(prompt.contains("来源：截图"), "Facts still cite screenshots")
    }

    func testDigestPipelineWritesKnowledgeAndCallsBothTools() {
        let card = WorkTask(id: UUID(), title: "准备评审材料", project: "MyClip", status: .todo,
                            createdAt: Date(), updatedAt: Date(), confirmedAt: nil, completedAt: nil,
                            waitingReason: "", statusObservedAt: nil, evidence: [])
        let event = CalendarEvent(id: UUID(), title: "周会", notes: "", location: "会议室", project: "",
                                  kind: .meeting, start: Date(timeIntervalSince1970: 1_793_000_000),
                                  end: Date(timeIntervalSince1970: 1_793_003_600), isAllDay: false, origin: .memory)
        let prompt = DayPrompt.digest(dailies: ["Daily/2026/11/2026-11-16.md", "Daily/2026/11/2026-11-16/周会.md"],
                                      board: [card], calendar: [event])
        XCTAssertTrue(prompt.contains("- Daily/2026/11/2026-11-16.md"))
        XCTAssertTrue(prompt.contains("- Daily/2026/11/2026-11-16/周会.md"))
        XCTAssertTrue(prompt.contains("Wiki/Projects"))
        XCTAssertTrue(prompt.contains("Memory.md"))
        XCTAssertTrue(prompt.contains("Profile.md：记录用户的个人信息"))
        for tool in ["board_list", "board_add", "board_update", "board_delete",
                     "calendar_list", "calendar_add", "calendar_update", "calendar_delete"] {
            XCTAssertTrue(prompt.contains(tool), tool)
        }
        XCTAssertTrue(prompt.contains("只在这条整理链路里出现"), "Only the digest touches the board and the calendar")
        XCTAssertTrue(prompt.contains("只写不读"))
        XCTAssertTrue(prompt.contains(card.id.uuidString), "Existing cards arrive with the prompt, so no list call is needed")
        XCTAssertTrue(prompt.contains(event.id.uuidString), "Existing events arrive with the prompt")
        XCTAssertTrue(prompt.contains("周会"))
        XCTAssertTrue(prompt.contains("myclip-event"), "It is told not to double-annotate a line it put on the calendar")
    }

    func testDiaryPlanRunsASingleDigestTurn() {
        let plan = ConsolidationPlan(changed: [], neighbours: [], weekly: nil, dailies: ["Daily/2026/11/2026-11-16.md"])
        let turns = MemoryPrompt.dreamTurns(plan: plan, handoff: nil)
        XCTAssertEqual(turns.count, 1, "A digest owns its dailies and never runs the review turns")
        XCTAssertTrue(turns[0].text.contains("board_add"))
        XCTAssertFalse(turns[0].text.contains("巡检"), "No patrol in a digest")
    }

    func testDreamPlanWithoutDailiesKeepsTheReviewTurns() {
        let plan = ConsolidationPlan(changed: ["Wiki/Projects/MyClip.md"], neighbours: [], weekly: nil)
        let turns = MemoryPrompt.dreamTurns(plan: plan, handoff: nil)
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(turns[0].text.contains("你在帮助 MyClip 做梦"))
    }
}
