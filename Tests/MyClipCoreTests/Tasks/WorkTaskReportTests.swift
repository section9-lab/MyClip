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
        XCTAssertEqual(document.sections.map(\.title), ["一、今日工作与成果", "二、问题与风险", "三、明日工作计划"])
        XCTAssertEqual(document.sections[0].projects.map(\.name), ["MyClip"])
        XCTAssertEqual(document.sections[0].projects[0].items.map(\.id), [done, doing])
        XCTAssertEqual(document.sections[0].projects[0].items.map(\.status), [.done, .doing])
        XCTAssertEqual(document.sections[0].projects[0].progress, "完成 1 项 · 推进中 1 项")
        XCTAssertEqual(document.sections[1].projects.flatMap(\.items).map(\.id), [todo])
        XCTAssertEqual(document.sections[1].projects[0].items[0].body, "等待测试环境")
        XCTAssertTrue(document.sections[2].projects.isEmpty)
        XCTAssertEqual(Set(document.taskIDs), [done, doing, todo])
        XCTAssertEqual(document.sections.flatMap(\.projects).flatMap(\.items).count, 3)
        XCTAssertTrue(document.markdown.contains("## 一、今日工作与成果\n\n### MyClip"))
        XCTAssertTrue(document.markdown.contains("**发布新版**"))
        XCTAssertTrue(document.markdown.contains("等待测试环境"))
    }

    func testProgressUsesOnlyEvidenceKnownAtReportCutoff() {
        let start = date("2026-09-18T00:00:00+08:00")
        let end = date("2026-09-19T00:00:00+08:00")
        let id = UUID()
        let task = WorkTask(id: id, title: "联调", project: "MyClip", status: .done,
                            createdAt: start, updatedAt: end, confirmedAt: start, completedAt: end,
                            evidence: [
                                WorkTaskEvidence(id: UUID(), body: "后来完成的验收", sourceIDs: [], memoryIDs: [], date: end),
                                WorkTaskEvidence(id: UUID(), body: "已完成接口联调，正在验证异常场景。", sourceIDs: [], memoryIDs: [], date: start.addingTimeInterval(10))
                            ])
        let events = [WorkTaskEvent(id: UUID(), taskID: id, from: nil, to: .doing, date: start, actor: .user)]
        let report = WorkTaskReport(period: .day, containing: start, tasks: [task], events: events, now: end, calendar: calendar)
        let item = report.document.sections[0].projects[0].items[0]
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
        let id = try await store.createWorkTask(title: "原任务", project: "MyClip", at: start)
        let tasks = try await store.workTasks(), events = try await store.workTaskEvents()
        func report(_ period: WorkTaskReportPeriod, _ date: Date) -> WorkTaskReport {
            WorkTaskReport(period: period, containing: date, tasks: tasks, events: events, now: start, calendar: calendar)
        }
        let day = report(.day, start), week = report(.week, start), next = report(.day, start.addingTimeInterval(86400))
        XCTAssertTrue(day.document.taskIDs.isEmpty, "Creating a todo does not invent progress or a next-period plan")
        XCTAssertEqual(day.referenceTaskIDs, [id])
        XCTAssertEqual(day.added, 1)
        var edited = day.document
        edited.sections[2].projects = [.init(name: "MyClip", items: [
            .init(id: id, status: .todo, title: "整理后的工作安排", body: "先确认验收范围，再安排联调。")
        ])]
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
        let task = WorkTask(id: id, title: "修复 <Slack> & 飞书分享", project: "MyClip", status: .doing,
                            createdAt: start, updatedAt: start, confirmedAt: start, completedAt: nil,
                            evidence: [WorkTaskEvidence(id: UUID(), body: "已复制富文本\n待验证钉钉", sourceIDs: [], memoryIDs: [], date: start)])
        let events = [WorkTaskEvent(id: UUID(), taskID: id, from: nil, to: .doing, date: start, actor: .user)]
        let document = WorkTaskReport(period: .day, containing: start, tasks: [task], events: events,
                                      now: start.addingTimeInterval(60), calendar: calendar).document
        let text = document.plainText
        XCTAssertTrue(text.hasPrefix("工作日报\n"))
        XCTAssertTrue(text.contains("\n二、问题与风险\n暂无记录。\n"))
        XCTAssertTrue(text.contains("\n三、明日工作计划\n尚未安排。"))
        XCTAssertTrue(text.contains("MyClip · 推进中 1 项\n- [进行中] 修复 <Slack> & 飞书分享：已复制富文本\n  待验证钉钉"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("#"))
        let html = document.html
        XCTAssertTrue(html.hasPrefix("<meta charset=\"utf-8\"><h1>工作日报</h1>"))
        XCTAssertTrue(html.contains("<li>[进行中] <b>修复 &lt;Slack&gt; &amp; 飞书分享</b>：已复制富文本<br>待验证钉钉</li>"))
        XCTAssertEqual(document.shareSubject, "工作日报 · \(document.dateTitle)")
    }

    func testUnchangedBacklogStaysInReferencesWithoutBecomingProgressOrPlans() {
        let start = date("2026-09-18T00:00:00+08:00")
        let end = date("2026-09-19T00:00:00+08:00")
        let now = start.addingTimeInterval(60)
        let before = start.addingTimeInterval(-60)
        let doing = WorkTask(id: UUID(), title: "昨日联调", project: "MyClip", status: .doing,
                             createdAt: before, updatedAt: before, confirmedAt: before, completedAt: nil,
                             evidence: [
                                .init(id: UUID(), body: "昨日的进展", sourceIDs: [], memoryIDs: [], date: before),
                                .init(id: UUID(), body: "尚未发生的进展", sourceIDs: [], memoryIDs: [], date: now.addingTimeInterval(1)),
                                .init(id: UUID(), body: "下一期的进展", sourceIDs: [], memoryIDs: [], date: end)
                             ])
        let todo = WorkTask(id: UUID(), title: "积压待办", project: "MyClip", status: .todo,
                            createdAt: before, updatedAt: before, confirmedAt: before, completedAt: nil, evidence: [])
        let tasks = [doing, todo]
        let events = tasks.map { WorkTaskEvent(id: UUID(), taskID: $0.id, from: nil, to: $0.status, date: before, actor: .user) }
        let report = WorkTaskReport(period: .day, containing: start, tasks: tasks, events: events, now: now, calendar: calendar)
        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(report.document.sections.allSatisfy { $0.projects.isEmpty })
        XCTAssertEqual(report.referenceTaskIDs, [doing.id, todo.id])
        XCTAssertTrue(report.document.taskIDs.isEmpty)
        for exported in [report.markdown, report.document.plainText, report.document.html] {
            XCTAssertFalse(exported.contains("昨日"))
            XCTAssertFalse(exported.contains("积压待办"))
            XCTAssertFalse(exported.contains("尚未发生"))
            XCTAssertFalse(exported.contains("下一期的进展"))
            XCTAssertFalse(exported.contains("下一步安排待补充"))
            XCTAssertTrue(exported.contains("尚未安排。"))
        }
    }

    func testEachPeriodCombinesDistinctEvidenceAndDeduplicatesByTaskID() {
        let reference = date("2026-09-19T10:00:00+08:00")
        for period in WorkTaskReportPeriod.allCases {
            let interval = WorkTaskReport(period: period, containing: reference, tasks: [], events: [], now: reference, calendar: calendar).interval
            let before = interval.start.addingTimeInterval(-1)
            let id = UUID()
            let task = WorkTask(id: id, title: "接口联调", project: "MyClip", status: .doing,
                                createdAt: before, updatedAt: reference, confirmedAt: before, completedAt: nil,
                                evidence: [
                                    .init(id: UUID(), body: " 补充异常场景 ", sourceIDs: [], memoryIDs: [], date: reference),
                                    .init(id: UUID(), body: "完成接口联调", sourceIDs: [], memoryIDs: [], date: interval.start.addingTimeInterval(1)),
                                    .init(id: UUID(), body: " 完成接口联调\n", sourceIDs: [], memoryIDs: [], date: interval.start),
                                    .init(id: UUID(), body: "旧进展", sourceIDs: [], memoryIDs: [], date: before),
                                    .init(id: UUID(), body: "未来进展", sourceIDs: [], memoryIDs: [], date: interval.end),
                                    .init(id: UUID(), body: "接口联调", sourceIDs: [], memoryIDs: [], date: interval.start),
                                    .init(id: UUID(), body: "  \n", sourceIDs: [], memoryIDs: [], date: interval.start)
                                ])
            let sameTitle = WorkTask(id: UUID(), title: task.title, project: task.project, status: .doing,
                                     createdAt: interval.start, updatedAt: interval.start, confirmedAt: interval.start,
                                     completedAt: nil, evidence: [])
            let events = [
                WorkTaskEvent(id: UUID(), taskID: id, from: nil, to: .doing, date: before, actor: .user),
                WorkTaskEvent(id: UUID(), taskID: sameTitle.id, from: .todo, to: .doing, date: interval.start, actor: .user)
            ]
            let report = WorkTaskReport(period: period, containing: reference, tasks: [task, sameTitle, task], events: events,
                                        now: reference, calendar: calendar)
            let items = report.document.sections[0].projects.flatMap(\.items)
            XCTAssertEqual(items.count, 2, "\(period): different IDs with the same title stay separate")
            XCTAssertEqual(items.first { $0.id == id }?.body, "完成接口联调\n补充异常场景")
            XCTAssertEqual(report.doing.count, 2)
            XCTAssertEqual(report.added, 1)
            XCTAssertTrue(report.document.sections[1].projects.isEmpty)
            XCTAssertTrue(report.document.sections[2].projects.isEmpty)
        }
    }

    func testIssuesContainOnlyBlockersWithoutRepeatingProgressEvidence() {
        let start = date("2026-09-18T00:00:00+08:00")
        let before = start.addingTimeInterval(-60)
        let task = WorkTask(id: UUID(), title: "接口验收", project: "MyClip", status: .doing,
                            createdAt: before, updatedAt: start, confirmedAt: before, completedAt: nil,
                            waitingReason: "等待测试环境", evidence: [
                                .init(id: UUID(), body: "完成接口联调", sourceIDs: [], memoryIDs: [], date: start),
                                .init(id: UUID(), body: "等待测试环境", sourceIDs: [], memoryIDs: [], date: start)
                            ])
        let blocked = WorkTask(id: UUID(), title: "等待确认", project: "MyClip", status: .todo,
                               createdAt: before, updatedAt: before, confirmedAt: before, completedAt: nil,
                               waitingReason: "等待客户反馈", evidence: [
                                .init(id: UUID(), body: "等待客户反馈", sourceIDs: [], memoryIDs: [], date: start)
                               ])
        let futureReason = WorkTask(id: UUID(), title: "后来阻塞", project: "MyClip", status: .doing,
                                    createdAt: before, updatedAt: start.addingTimeInterval(120), confirmedAt: before,
                                    completedAt: nil, waitingReason: "尚未发生的问题", evidence: [])
        let tasks = [task, blocked, futureReason]
        let events = tasks.map { WorkTaskEvent(id: UUID(), taskID: $0.id, from: nil, to: $0.status, date: before, actor: .user) }
        let document = WorkTaskReport(period: .day, containing: start, tasks: tasks, events: events,
                                      now: start.addingTimeInterval(60), calendar: calendar).document
        let outcomes = document.sections[0].projects.flatMap(\.items)
        let issues = document.sections[1].projects.flatMap(\.items)
        XCTAssertEqual(outcomes.map(\.id), [task.id])
        XCTAssertEqual(outcomes[0].body, "完成接口联调")
        XCTAssertEqual(Set(issues.map(\.id)), [task.id, blocked.id])
        XCTAssertEqual(Set(issues.map(\.body)), ["等待测试环境", "等待客户反馈"])
        XCTAssertFalse(document.markdown.contains("尚未发生的问题"))
        XCTAssertTrue(document.sections[2].projects.isEmpty)
    }

    func testLoadingLegacyPlansDropsOnlyGeneratedRowsAndKeepsConcreteEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let start = date("2026-09-18T00:00:00+08:00")
        let report = WorkTaskReport(period: .day, containing: start, tasks: [], events: [], now: start, calendar: calendar)
        var legacy = report.document
        let concrete = WorkTaskReportDocument.Item(id: UUID(), status: .doing, title: "安装 Node.js", body: "验证安装结果。")
        let edited = WorkTaskReportDocument.Item(id: UUID(), status: .todo, title: "确认验收", body: "下一步安排待补充。\n先和客户确认验收范围。")
        let blockedID = UUID()
        let copiedIssue = "等待与问题：等待权限\n等待测试环境"
        legacy.sections[1].projects = [.init(name: "MyClip", items: [
            .init(id: blockedID, status: .doing, title: "准备验收", body: "已完成联调\n" + copiedIssue)
        ])]
        legacy.sections[2].projects = [
            .init(name: "自动生成", items: [
                .init(id: UUID(), status: .doing, title: "旧任务", body: "下一步安排待补充。"),
                .init(id: UUID(), status: .todo, title: "旧阻塞", body: "下一步安排待补充。\n等待与问题：等待测试环境"),
                .init(id: UUID(), status: .doing, title: "Old task", body: "Next steps to be added."),
                .init(id: UUID(), status: .todo, title: "Old issue", body: "Next steps to be added.\nWaiting on / Issues: Waiting for approval"),
                .init(id: blockedID, status: .doing, title: "准备验收", body: "下一步安排待补充。\n" + copiedIssue)
            ]),
            .init(name: "MyClip", items: [concrete, edited,
                .init(id: blockedID, status: .doing, title: "准备验收", body: "下一步安排待补充。\n" + copiedIssue + "\n明早确认环境和验收时间。")
            ])
        ]
        try await store.saveWorkTaskReport(legacy)
        let url = root.appendingPathComponent("Reports/\(legacy.id).json")
        let original = try Data(contentsOf: url)
        let loaded = try await store.savedWorkTaskReport(for: report)
        let document = try XCTUnwrap(loaded)
        XCTAssertEqual(document.sections[2].projects.map(\.name), ["MyClip"])
        let items = document.sections[2].projects.flatMap(\.items)
        XCTAssertEqual(items.map(\.id), [concrete.id, edited.id, blockedID])
        XCTAssertEqual(items[0], concrete)
        XCTAssertEqual(items[1].body, "先和客户确认验收范围。")
        XCTAssertEqual(items[2].body, "明早确认环境和验收时间。")
        XCTAssertEqual(try Data(contentsOf: url), original, "Loading does not overwrite saved drafts")
        for exported in [document.markdown, document.plainText, document.html] {
            XCTAssertFalse(exported.contains("下一步安排待补充"))
            XCTAssertFalse(exported.contains("Next steps to be added."))
            XCTAssertTrue(exported.contains("验证安装结果。"))
        }
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
