import XCTest
@testable import MyClipCore

@MainActor
final class WorkTaskReportTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testReportsUseLocalCalendarDaysMondayWeeksAndMonths() {
        let reference = date("2026-09-19T10:00:00+08:00")
        for (period, start, end) in [
            (WorkTaskReportPeriod.day, "2026-09-19T00:00:00+08:00", "2026-09-20T00:00:00+08:00"),
            (.week, "2026-09-14T00:00:00+08:00", "2026-09-21T00:00:00+08:00"),
            (.month, "2026-09-01T00:00:00+08:00", "2026-10-01T00:00:00+08:00")
        ] {
            let report = WorkTaskReport(period: period, containing: reference, tasks: [], events: [], now: reference, calendar: calendar)
            XCTAssertEqual(report.interval.start, date(start))
            XCTAssertEqual(report.interval.end, date(end))
            XCTAssertTrue(report.isEmpty)
        }
    }

    func testHistoricalReportReconstructsStatusAndExcludesNextPeriod() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let start = date("2026-09-18T00:00:00+08:00")
        let end = date("2026-09-19T00:00:00+08:00")
        let completed = try await store.createWorkTask(title: "发布新版", project: "MyClip", at: start)
        try await store.setWorkTaskStatus(completed, status: .done, at: start.addingTimeInterval(60))
        try await store.setWorkTaskStatus(completed, status: .doing, at: end)
        let carry = try await store.createWorkTask(title: "继续联调", at: start.addingTimeInterval(-7200))
        try await store.setWorkTaskStatus(carry, status: .doing, at: start.addingTimeInterval(-3600))
        let todo = try await store.createWorkTask(title: "准备验收", at: start.addingTimeInterval(10))
        _ = try await store.createWorkTask(title: "次日任务", at: end)
        let ignored = try await store.createWorkTask(title: "取消的工作", at: start)
        try await store.setWorkTaskStatus(ignored, status: .ignored, at: start.addingTimeInterval(20))
        let tasks = try await store.workTasks(), events = try await store.workTaskEvents()
        let report = WorkTaskReport(period: .day, containing: start, tasks: tasks, events: events, now: end.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(report.completed.map(\.id), [completed])
        XCTAssertEqual(report.doing.map(\.id), [carry])
        XCTAssertEqual(report.todo.map(\.id), [todo])
        XCTAssertEqual(report.added, 3)
        XCTAssertTrue(report.markdown.contains("发布新版"))
        XCTAssertFalse(report.markdown.contains("次日任务"))
        XCTAssertFalse(report.markdown.contains("取消的工作"))
    }

    func testReopeningIsNotCountedAsCompletedAndRepeatCompletionsAreDeduplicated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let start = date("2026-09-19T00:00:00+08:00")
        let id = try await store.createWorkTask(title: "导出测试", waitingReason: "等待测试环境", at: start)
        let waiting = try await store.createWorkTask(title: "确认交付", waitingReason: "等待客户反馈", at: start)
        try await store.setWorkTaskStatus(id, status: .done, at: start.addingTimeInterval(10))
        try await store.setWorkTaskStatus(id, status: .doing, at: start.addingTimeInterval(20))
        var tasks = try await store.workTasks(), events = try await store.workTaskEvents()
        let now = start.addingTimeInterval(100)
        var report = WorkTaskReport(period: .day, containing: start, tasks: tasks, events: events, now: now, calendar: calendar)
        XCTAssertTrue(report.completed.isEmpty)
        XCTAssertEqual(report.doing.map(\.id), [id])
        XCTAssertEqual(report.waiting.map(\.id), [waiting])
        try await store.setWorkTaskStatus(id, status: .done, at: start.addingTimeInterval(30))
        try await store.setWorkTaskStatus(id, status: .doing, at: start.addingTimeInterval(40))
        try await store.setWorkTaskStatus(id, status: .done, at: start.addingTimeInterval(50))
        tasks = try await store.workTasks(); events = try await store.workTaskEvents()
        report = WorkTaskReport(period: .day, containing: start, tasks: tasks, events: events, now: now, calendar: calendar)
        XCTAssertEqual(report.completed.map(\.id), [id])
        XCTAssertTrue(report.markdown.contains("等待客户反馈"))
        XCTAssertFalse(report.markdown.contains("等待测试环境"))
        let earlier = WorkTaskReport(period: .day, containing: start, tasks: tasks, events: events, now: start.addingTimeInterval(25), calendar: calendar)
        XCTAssertTrue(earlier.completed.isEmpty)
        XCTAssertEqual(earlier.doing.map(\.id), [id])
    }

    func testDayReportHandlesDaylightSavingWithoutFixedDurations() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = date("2026-03-08T12:00:00-07:00")
        let report = WorkTaskReport(period: .day, containing: now, tasks: [], events: [], now: now, calendar: calendar)
        XCTAssertEqual(report.interval.duration, 23 * 3600)
    }

    func testDocumentGroupsEachOutlineByProjectWithHistoricalProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let start = date("2026-09-18T00:00:00+08:00")
        let end = date("2026-09-19T00:00:00+08:00")
        let done = try await store.createWorkTask(title: "发布新版", project: "MyClip", at: start)
        try await store.setWorkTaskStatus(done, status: .done, at: start.addingTimeInterval(10))
        try await store.setWorkTaskStatus(done, status: .doing, at: end)
        let doing = try await store.createWorkTask(title: "联调", project: "MyClip", at: start)
        try await store.setWorkTaskStatus(doing, status: .doing, at: start)
        let todo = try await store.createWorkTask(title: "验收", project: "chat-bridge", waitingReason: "等待测试环境", at: start)
        let tasks = try await store.workTasks(), events = try await store.workTaskEvents()
        let document = WorkTaskReport(period: .day, containing: start, tasks: tasks, events: events,
                                      now: end.addingTimeInterval(60), calendar: calendar).document
        XCTAssertEqual(document.sections.map(\.title), ["一、今日工作与成果", "二、进行中的工作与问题", "三、明日工作计划"])
        XCTAssertEqual(document.sections[0].projects.map(\.name), ["MyClip"])
        XCTAssertEqual(document.sections[0].projects[0].items.map(\.status), [.done])
        XCTAssertEqual(document.sections[0].projects[0].progress, "完成 1 项")
        XCTAssertEqual(document.sections[1].projects.flatMap(\.items).map(\.id), [doing, todo])
        XCTAssertEqual(document.sections[2].projects.flatMap(\.items).map(\.status), [.doing, .todo])
        XCTAssertEqual(Set(document.taskIDs), [done, doing, todo])
        XCTAssertEqual(document.taskIDs.count, 3, "References deduplicate tasks repeated in the next-step outline")
        XCTAssertTrue(document.markdown.contains("## 一、今日工作与成果\n\n### MyClip"))
        XCTAssertTrue(document.markdown.contains("**发布新版**"))
        XCTAssertTrue(document.markdown.contains("等待测试环境"))
    }

    func testProgressUsesOnlyEvidenceKnownAtReportCutoff() {
        let start = date("2026-09-18T00:00:00+08:00")
        let end = date("2026-09-19T00:00:00+08:00")
        let id = UUID()
        let task = WorkTask(id: id, title: "联调", project: "MyClip", status: .done, suggestedStatus: nil,
                            createdAt: start, updatedAt: end, confirmedAt: start, completedAt: end,
                            evidence: [
                                WorkTaskEvidence(id: UUID(), body: "后来完成的验收", sourceIDs: [], memoryIDs: [], date: end),
                                WorkTaskEvidence(id: UUID(), body: "已完成接口联调，正在验证异常场景。", sourceIDs: [], memoryIDs: [], date: start.addingTimeInterval(10))
                            ])
        let events = [WorkTaskEvent(id: UUID(), taskID: id, from: nil, to: .doing, date: start, actor: .user)]
        let report = WorkTaskReport(period: .day, containing: start, tasks: [task], events: events, now: end, calendar: calendar)
        let item = report.document.sections[1].projects[0].items[0]
        XCTAssertEqual(item.status, .doing)
        XCTAssertEqual(item.body, "已完成接口联调，正在验证异常场景。")
        XCTAssertFalse(report.markdown.contains("后来完成"))
        let earlier = WorkTaskReport(period: .day, containing: start, tasks: [task], events: events, now: start, calendar: calendar)
        XCTAssertFalse(earlier.markdown.contains("接口联调"))
    }

    func testReportEditsPersistByPeriodWithoutChangingTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let start = date("2026-09-18T00:00:00+08:00")
        _ = try await store.createWorkTask(title: "原任务", project: "MyClip", at: start)
        let tasks = try await store.workTasks(), events = try await store.workTaskEvents()
        func report(_ period: WorkTaskReportPeriod, _ date: Date) -> WorkTaskReport {
            WorkTaskReport(period: period, containing: date, tasks: tasks, events: events, now: start, calendar: calendar)
        }
        let day = report(.day, start), week = report(.week, start), next = report(.day, start.addingTimeInterval(86400))
        var edited = day.document
        edited.sections[2].projects[0].items[0].title = "整理后的工作安排"
        edited.sections[2].projects[0].items[0].body = "先确认验收范围，再安排联调。"
        try await store.saveWorkTaskReport(edited)
        let reopened = try LibraryStore(root: root)
        let loaded = try await reopened.savedWorkTaskReport(for: day)
        let weekly = try await reopened.savedWorkTaskReport(for: week)
        let nextDay = try await reopened.savedWorkTaskReport(for: next)
        XCTAssertEqual(loaded, edited)
        XCTAssertNil(weekly)
        XCTAssertNil(nextDay)
        XCTAssertTrue(try XCTUnwrap(loaded).markdown.contains("先确认验收范围"))
        let unchanged = try await reopened.workTasks()
        XCTAssertEqual(unchanged.first?.title, "原任务")
        XCTAssertEqual(unchanged.first?.status, .todo)
        for (period, title) in [(WorkTaskReportPeriod.week, "三、下周工作计划"), (.month, "三、下月工作计划")] {
            XCTAssertEqual(report(period, start).document.sections.last?.title, title)
        }
    }

    func testSharedFormatsDropMarkdownSyntaxAndEscapeHTML() {
        let start = date("2026-09-18T00:00:00+08:00")
        let id = UUID()
        let task = WorkTask(id: id, title: "修复 <Slack> & 飞书分享", project: "MyClip", status: .doing, suggestedStatus: nil,
                            createdAt: start, updatedAt: start, confirmedAt: start, completedAt: nil,
                            evidence: [WorkTaskEvidence(id: UUID(), body: "已复制富文本\n待验证钉钉", sourceIDs: [], memoryIDs: [], date: start)])
        let events = [WorkTaskEvent(id: UUID(), taskID: id, from: nil, to: .doing, date: start, actor: .user)]
        let document = WorkTaskReport(period: .day, containing: start, tasks: [task], events: events,
                                      now: start.addingTimeInterval(60), calendar: calendar).document
        let text = document.plainText
        XCTAssertTrue(text.hasPrefix("工作日报\n"))
        XCTAssertTrue(text.contains("\n一、今日工作与成果\n暂无记录。\n"))
        XCTAssertTrue(text.contains("MyClip · 推进中 1 项\n- [进行中] 修复 <Slack> & 飞书分享：已复制富文本\n  待验证钉钉"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("#"))
        let html = document.html
        XCTAssertTrue(html.hasPrefix("<meta charset=\"utf-8\"><h1>工作日报</h1>"))
        XCTAssertTrue(html.contains("<li>[进行中] <b>修复 &lt;Slack&gt; &amp; 飞书分享</b>：已复制富文本<br>待验证钉钉</li>"))
        XCTAssertEqual(document.shareSubject, "工作日报 · \(document.dateTitle)")
    }

    func testShareDestinationsPreferInstalledAppsAndOneLarkBuild() {
        let installed: Set<String> = ["com.electron.lark", "com.tinyspeck.slackmacgap"]
        let chinese = ReportShareDestination.available(language: .chinese) { installed.contains($0) }
        XCTAssertEqual(chinese, [.gmail, .notion, .feishu, .dingTalk, .slack], "WeCom and WeChat have no web client")
        let english = ReportShareDestination.available(language: .english) { installed.contains($0) }
        XCTAssertEqual(english, chinese, "An installed Feishu app replaces the Lark web version")
        XCTAssertEqual(ReportShareDestination.available(language: .english) { _ in false }, [.gmail, .notion, .lark, .dingTalk, .slack])
        XCTAssertEqual(ReportShareDestination.available(language: .chinese) { _ in true }, ReportShareDestination.allCases)
        let gmail = ReportShareDestination.gmail.webURL(subject: "工作日报 · A&B+C")!.absoluteString
        XCTAssertEqual(gmail, "https://mail.google.com/mail/?view=cm&fs=1&su=%E5%B7%A5%E4%BD%9C%E6%97%A5%E6%8A%A5%20%C2%B7%20A%26B%2BC")
    }
}
