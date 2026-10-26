import Foundation

public enum WorkTaskReportPeriod: String, Codable, CaseIterable, Sendable {
    case day, week, month
    public var title: String {
        switch self {
        case .day: String(localized: "日报")
        case .week: String(localized: "周报")
        case .month: String(localized: "月报")
        }
    }
    public var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

public struct WorkTaskReport: Sendable {
    public let period: WorkTaskReportPeriod
    public let interval: DateInterval
    public let dateTitle: String
    public let isCurrent: Bool
    public let added: Int
    public let completed: [WorkTask]
    public let doing: [WorkTask]
    public let todo: [WorkTask]
    public let waiting: [WorkTask]
    private let progressed: [WorkTask]
    private let progressBodies: [UUID: String]
    public var isEmpty: Bool { progressed.isEmpty && waiting.isEmpty }
    /// Unchanged unfinished tasks stay available as references without filling the report body.
    public var referenceTaskIDs: Set<UUID> { Set((progressed + completed + doing + todo).map(\.id)) }
    public var summary: String { String(localized: "新增 \(added) 项，完成 \(completed.count) 项；\(isCurrent ? String(localized: "目前") : String(localized: "期末"))进行中 \(doing.count) 项，待办 \(todo.count) 项。") }

    public init(period: WorkTaskReportPeriod, containing date: Date, tasks: [WorkTask], events: [WorkTaskEvent], now: Date = Date(), calendar: Calendar = .current) {
        var calendar = calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        self.period = period
        interval = calendar.dateInterval(of: period.component, for: date)!
        isCurrent = now >= interval.start && now < interval.end
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = period == .month ? String(localized: "yyyy年M月") : String(localized: "yyyy年M月d日")
        dateTitle = period == .week
            ? formatter.string(from: interval.start) + " — " + formatter.string(from: calendar.date(byAdding: .day, value: -1, to: interval.end)!)
            : formatter.string(from: interval.start)

        let start = interval.start, end = interval.end
        var latest: [UUID: WorkTaskStatus] = [:]
        var completions: Set<UUID> = []
        var activity: Set<UUID> = []
        // Equal timestamps keep their persisted event order. The period end is exclusive.
        for event in events.sorted(by: { $0.date < $1.date }) where event.date < end && event.date <= now {
            latest[event.taskID] = event.to
            if event.date >= start && event.to == .done { completions.insert(event.taskID) }
            if event.date >= start && event.from != event.to && (event.to == .doing || event.to == .done) {
                activity.insert(event.taskID)
            }
        }
        var tasksByID: [UUID: WorkTask] = [:]
        for task in tasks {
            if let existing = tasksByID[task.id], existing.updatedAt >= task.updatedAt { continue }
            tasksByID[task.id] = task
        }
        let tasks = Array(tasksByID.values)
        added = tasks.filter { task in
            guard let date = task.confirmedAt else { return false }
            return date >= start && date < end && date <= now
        }.count
        let sorted = tasks.sorted { left, right in
            if left.projectTitle != right.projectTitle { return left.projectTitle < right.projectTitle }
            if left.title != right.title { return left.title < right.title }
            return left.id.uuidString < right.id.uuidString
        }
        completed = sorted.filter { latest[$0.id] == .done && completions.contains($0.id) }
        doing = sorted.filter { latest[$0.id] == .doing }
        todo = sorted.filter { latest[$0.id] == .todo }
        // Waiting text is editable, so only show it when it is known at the report cutoff.
        waiting = (doing + todo).filter {
            !$0.waitingReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.updatedAt <= now && $0.updatedAt < end
        }
        let waitingIDs = Set(waiting.map(\.id))
        var bodies: [UUID: String] = [:]
        for task in sorted {
            var seen: Set<String> = []
            let reason = waitingIDs.contains(task.id) ? task.waitingReason.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let evidence = task.evidence.filter { $0.date >= start && $0.date < end && $0.date <= now }
                .sorted { $0.date < $1.date }
                .map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != task.title && $0 != reason && seen.insert($0).inserted }
            bodies[task.id] = evidence.joined(separator: "\n")
        }
        progressBodies = bodies
        progressed = sorted.filter {
            latest[$0.id]?.isOnBoard == true && (activity.contains($0.id) || bodies[$0.id]?.isEmpty == false)
        }
    }

    public var document: WorkTaskReportDocument {
        let current = period == .day ? String(localized: "今日") : period == .week ? String(localized: "本周") : String(localized: "本月")
        let next = period == .day ? String(localized: "明日") : period == .week ? String(localized: "下周") : String(localized: "下月")
        let doingIDs = Set(doing.map(\.id))
        let todoIDs = Set(todo.map(\.id))
        func projects(_ tasks: [WorkTask], issues: Bool = false) -> [WorkTaskReportDocument.Project] {
            Dictionary(grouping: tasks, by: \.projectTitle).sorted { $0.key < $1.key }.map { name, tasks in
                let items = tasks.map { task in
                    let status: WorkTaskStatus = doingIDs.contains(task.id) ? .doing : todoIDs.contains(task.id) ? .todo : .done
                    let body = issues ? task.waitingReason.trimmingCharacters(in: .whitespacesAndNewlines) : progressBodies[task.id] ?? ""
                    return WorkTaskReportDocument.Item(id: task.id, status: status, title: task.title, body: body)
                }
                return WorkTaskReportDocument.Project(name: name, items: items)
            }
        }
        return WorkTaskReportDocument(period: period, interval: interval, dateTitle: dateTitle, sections: [
            .init(id: "outcomes", title: String(localized: "一、\(current)工作与成果"), projects: projects(progressed)),
            .init(id: "progress", title: String(localized: "二、问题与风险"), projects: projects(waiting, issues: true)),
            .init(id: "plans", title: String(localized: "三、\(next)工作计划"), projects: [])
        ])
    }

    public var markdown: String { document.markdown }
}

public struct WorkTaskReportDocument: Codable, Equatable, Identifiable, Sendable {
    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let status: WorkTaskStatus
        public var title: String
        public var body: String
    }

    public struct Project: Codable, Equatable, Identifiable, Sendable {
        public let name: String
        public var items: [Item]
        public var id: String { name }
        public var progress: String {
            [(WorkTaskStatus.done, String(localized: "完成")), (.doing, String(localized: "推进中")), (.todo, String(localized: "待办"))].compactMap { status, title in
                let count = items.filter { $0.status == status }.count
                return count == 0 ? nil : String(localized: "\(title) \(count) 项")
            }.joined(separator: " · ")
        }
    }

    public struct Section: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public var title: String
        public var projects: [Project]
        public var emptyText: String { id == "plans" ? String(localized: "尚未安排。") : String(localized: "暂无记录。") }
    }

    public let period: WorkTaskReportPeriod
    public let interval: DateInterval
    public let dateTitle: String
    public var sections: [Section]
    public var id: String { "\(period.rawValue)-\(Int(interval.start.timeIntervalSince1970))" }
    public var title: String { String(localized: "工作\(period.title)") }
    public var taskIDs: [UUID] {
        var seen: Set<UUID> = []
        return sections.flatMap(\.projects).flatMap(\.items).map(\.id).filter { seen.insert($0).inserted }
    }
    /// Older drafts copied every unfinished task into plans. Keep concrete edits, but discard generated rows.
    func removingAutomaticPlans() -> Self {
        let placeholders: Set<String> = [
            "下一步安排待补充。", "Next steps to be added.", "Nächste Schritte noch zu ergänzen.",
            "Próximos pasos por completar.", "Prochaines étapes à compléter.", "次のステップは未記入です。",
            "다음 단계 계획은 추후 보충 예정입니다."
        ]
        let waitingPrefixes = [
            "等待与问题：", "Waiting on / Issues:", "Wartet auf / offene Fragen:", "Esperas y problemas:",
            "Attentes et problèmes :", "待ちと課題：", "대기 사항 및 문제:"
        ]
        let sourceItems = Dictionary(grouping: sections.filter { $0.id != "plans" }.flatMap(\.projects).flatMap(\.items), by: \.id)
        var document = self
        for index in document.sections.indices where document.sections[index].id == "plans" {
            document.sections[index].projects = document.sections[index].projects.compactMap { project in
                var project = project
                project.items = project.items.compactMap { item in
                    let lines = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: "\n", maxSplits: 1).map(String.init)
                    guard let first = lines.first, placeholders.contains(first.trimmingCharacters(in: .whitespaces)) else { return item }
                    var remainder = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if let prefix = waitingPrefixes.first(where: { remainder.hasPrefix($0) }) {
                        // Match the copied issue exactly so an appended concrete plan survives, including multiline issues.
                        let copiedIssues = sourceItems[item.id, default: []].compactMap { source -> String? in
                            guard let range = source.body.range(of: prefix, options: .backwards) else { return nil }
                            return String(source.body[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }.sorted { $0.count > $1.count }
                        if let copied = copiedIssues.first(where: { remainder == $0 || remainder.hasPrefix($0 + "\n") }) {
                            remainder = String(remainder.dropFirst(copied.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if !remainder.contains("\n") {
                            return nil
                        }
                    }
                    guard !remainder.isEmpty else { return nil }
                    var item = item
                    item.body = remainder
                    return item
                }
                return project.items.isEmpty ? nil : project
            }
        }
        return document
    }
    public var markdown: String {
        var lines = ["# \(title)", "", dateTitle]
        for section in sections {
            lines += ["", "## \(section.title)"]
            if section.projects.isEmpty { lines += ["", section.emptyText] }
            for project in section.projects {
                lines += ["", "### \(project.name)", "", project.progress, ""]
                for item in project.items {
                    let body = item.body.isEmpty ? "" : "：" + item.body.replacingOccurrences(of: "\n", with: "\n  ")
                    lines.append("- [\(item.status.title)] **\(item.title)**\(body)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
    /// The subject line used when the report leaves MyClip, e.g. as an email.
    public var shareSubject: String { "\(title) · \(dateTitle)" }
    /// The report without Markdown syntax, for chat apps that paste plain text.
    public var plainText: String {
        var lines = [title, dateTitle]
        for section in sections {
            lines += ["", section.title]
            if section.projects.isEmpty { lines.append(section.emptyText) }
            for project in section.projects {
                lines += ["", "\(project.name) · \(project.progress)"]
                for item in project.items {
                    let body = item.body.isEmpty ? "" : "：" + item.body.replacingOccurrences(of: "\n", with: "\n  ")
                    lines.append("- [\(item.status.title)] \(item.title)\(body)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
    /// The report as an HTML fragment, which mail, docs and chat apps paste with headings, lists and bold titles.
    public var html: String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        // Chromium-based apps decode pasted HTML as Latin-1 unless the fragment declares its encoding.
        var html = "<meta charset=\"utf-8\"><h1>\(escape(title))</h1><p>\(escape(dateTitle))</p>"
        for section in sections {
            html += "<h2>\(escape(section.title))</h2>"
            if section.projects.isEmpty { html += "<p>\(escape(section.emptyText))</p>" }
            for project in section.projects {
                html += "<h3>\(escape(project.name))</h3><p>\(escape(project.progress))</p><ul>"
                for item in project.items {
                    let body = item.body.isEmpty ? "" : "：" + escape(item.body).replacingOccurrences(of: "\n", with: "<br>")
                    html += "<li>[\(escape(item.status.title))] <b>\(escape(item.title))</b>\(body)</li>"
                }
                html += "</ul>"
            }
        }
        return html
    }
}

extension LibraryStore {
    public func savedWorkTaskReport(for report: WorkTaskReport) throws -> WorkTaskReportDocument? {
        let url = root.appendingPathComponent("Reports/\(report.document.id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let document = try JSONDecoder().decode(WorkTaskReportDocument.self, from: Data(contentsOf: url))
        guard document.id == report.document.id else { throw LibraryError.invalidResult(String(localized: "报告日期与草稿不一致")) }
        return document.removingAutomaticPlans()
    }

    public func saveWorkTaskReport(_ document: WorkTaskReportDocument) throws {
        let folder = root.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: folder.appendingPathComponent("\(document.id).json"), options: .atomic)
    }
}
