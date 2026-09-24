import Foundation
import IOKit.pwr_mgt
import Observation

enum ScheduledTaskCadence: String, CaseIterable, Codable, Identifiable {
    case daily
    case weekdays
    case weeklyMonday

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily:
            return "Daily"
        case .weekdays:
            return "Weekdays"
        case .weeklyMonday:
            return "Mondays"
        }
    }

    func shouldRun(on date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        switch self {
        case .daily:
            return true
        case .weekdays:
            return (2...6).contains(weekday)
        case .weeklyMonday:
            return weekday == 2
        }
    }
}

struct ScheduledTaskRun: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case succeeded
        case failed

        var displayName: String {
            switch self {
            case .succeeded:
                return "Succeeded"
            case .failed:
                return "Failed"
            }
        }
    }

    let id: UUID
    let taskID: UUID
    var taskName: String
    var ranAt: Date
    var status: Status
    var detail: String
    var prompt: String
    var response: String?
    var responsePreview: String?
    var turnID: UUID?
    var targetTool: AIToolType?

    init(
        id: UUID = UUID(),
        taskID: UUID,
        taskName: String,
        ranAt: Date = Date(),
        status: Status,
        detail: String,
        prompt: String = "",
        response: String? = nil,
        responsePreview: String? = nil,
        turnID: UUID? = nil,
        targetTool: AIToolType? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.taskName = taskName
        self.ranAt = ranAt
        self.status = status
        self.detail = detail
        self.prompt = prompt
        self.response = response
        self.responsePreview = responsePreview ?? Self.preview(response)
        self.turnID = turnID
        self.targetTool = targetTool
    }

    var summaryText: String {
        if let responsePreview,
           !responsePreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return responsePreview
        }
        return displayDetail
    }

    var displayDetail: String {
        Self.displayDetail(for: detail)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID
        case taskName
        case ranAt
        case status
        case detail
        case prompt
        case response
        case responsePreview
        case turnID
        case targetTool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        taskID = try container.decode(UUID.self, forKey: .taskID)
        taskName = try container.decode(String.self, forKey: .taskName)
        ranAt = try container.decodeIfPresent(Date.self, forKey: .ranAt) ?? Date()
        status = try container.decode(Status.self, forKey: .status)
        detail = try container.decode(String.self, forKey: .detail)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        response = try container.decodeIfPresent(String.self, forKey: .response)
        responsePreview = try container.decodeIfPresent(String.self, forKey: .responsePreview) ?? Self.preview(response)
        turnID = try container.decodeIfPresent(UUID.self, forKey: .turnID)
        targetTool = try container.decodeIfPresent(AIToolType.self, forKey: .targetTool)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(taskName, forKey: .taskName)
        try container.encode(ranAt, forKey: .ranAt)
        try container.encode(status, forKey: .status)
        try container.encode(detail, forKey: .detail)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(response, forKey: .response)
        try container.encodeIfPresent(responsePreview, forKey: .responsePreview)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encodeIfPresent(targetTool, forKey: .targetTool)
    }

    static func preview(_ text: String?, limit: Int = 160) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "..."
    }

    private static func displayDetail(for detail: String) -> String {
        switch detail {
        case "手动执行已提交":
            return "Manual run submitted"
        case "定时执行已提交":
            return "Scheduled run submitted"
        case "手动执行完成":
            return "Manual run completed"
        case "定时执行完成":
            return "Scheduled run completed"
        case "手动执行失败":
            return "Manual run failed"
        case "定时执行失败":
            return "Scheduled run failed"
        case "任务没有配置执行目标":
            return "No execution target configured for this task"
        case "AI 服务不可用":
            return "AI service unavailable"
        case "保持系统唤醒失败":
            return "Failed to keep the system awake"
        default:
            return detail
        }
    }
}

/// A scheduled task that sends a prompt to an AI tool at a planned time.
struct ScheduledTask: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var prompt: String
    var cadence: ScheduledTaskCadence
    var hour: Int
    var minute: Int
    var targetTool: AIToolType?
    var targetChannelID: UUID?
    var isEnabled: Bool
    var lastRunAt: Date?
    var lastScheduledRunKey: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        cadence: ScheduledTaskCadence = .daily,
        hour: Int = 9,
        minute: Int = 30,
        targetTool: AIToolType? = nil,
        targetChannelID: UUID? = nil,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        lastScheduledRunKey: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.cadence = cadence
        self.hour = hour
        self.minute = minute
        self.targetTool = targetTool
        self.targetChannelID = targetChannelID
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.lastScheduledRunKey = lastScheduledRunKey
        self.createdAt = createdAt
    }

    var scheduleText: String {
        "\(cadence.displayName) \(Self.timeText(hour: hour, minute: minute))"
    }

    static func timeText(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case prompt
        case intervalMinutes
        case cadence
        case hour
        case minute
        case targetTool
        case targetChannelID
        case isEnabled
        case lastRunAt
        case lastScheduledRunKey
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        cadence = try container.decodeIfPresent(ScheduledTaskCadence.self, forKey: .cadence) ?? .daily
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 30
        targetTool = try container.decodeIfPresent(AIToolType.self, forKey: .targetTool)
        targetChannelID = try container.decodeIfPresent(UUID.self, forKey: .targetChannelID)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastScheduledRunKey = try container.decodeIfPresent(String.self, forKey: .lastScheduledRunKey)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(hour, forKey: .hour)
        try container.encode(minute, forKey: .minute)
        try container.encodeIfPresent(targetTool, forKey: .targetTool)
        try container.encodeIfPresent(targetChannelID, forKey: .targetChannelID)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try container.encodeIfPresent(lastScheduledRunKey, forKey: .lastScheduledRunKey)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// Manages scheduled AI tasks.
@MainActor
@Observable
final class ScheduledTaskService {
    var tasks: [ScheduledTask] = []
    var runs: [ScheduledTaskRun] = []
    var lastError: String?
    var keepSystemAwake = false
    var unreadRunCount = 0
    var focusedRunID: UUID?

    private let storageKey = "Kara.scheduledTasks"
    private let runsStorageKey = "Kara.scheduledTaskRuns"
    private let keepAwakeStorageKey = "Kara.scheduledTasks.keepAwake"
    private let exampleSeedStorageKey = "Kara.scheduledTasks.seededExamples.v1"
    private let responseStorageLimit = 50_000
    private var schedulerTimer: Timer?
    private var powerAssertionID = IOPMAssertionID(0)
    private var runningTaskIDs: Set<UUID> = []
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// Reference to the AI service for executing tasks.
    weak var aiService: AIIntegrationService?
    weak var imService: IMChannelService?

    init() {
        loadTasks()
        loadRuns()
        keepSystemAwake = UserDefaults.standard.bool(forKey: keepAwakeStorageKey)
        updatePowerAssertion()
    }

    // MARK: - CRUD

    func addTask(_ task: ScheduledTask) {
        tasks.append(task)
        saveTasks()
    }

    func updateTask(_ task: ScheduledTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx] = task
        saveTasks()
    }

    func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        runs.removeAll { $0.taskID == id }
        runningTaskIDs.remove(id)
        saveTasks()
        saveRuns()
    }

    func toggleTask(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].isEnabled.toggle()
        saveTasks()
    }

    func setKeepSystemAwake(_ isEnabled: Bool) {
        keepSystemAwake = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: keepAwakeStorageKey)
        updatePowerAssertion()
    }

    func markRunsSeen() {
        unreadRunCount = 0
    }

    func focusRun(id: UUID?) {
        focusedRunID = id
        if id != nil {
            markRunsSeen()
        }
    }

    func clearFocusedRun() {
        focusedRunID = nil
    }

    func sendTestNotification() {
        KaraLocalNotificationCenter.post(
            identifier: "kara.test.\(UUID().uuidString)",
            title: "Kara Notification Test",
            subtitle: "System Notification",
            body: "If you see this notification, Kara's notification permission and delivery path are working.",
            userInfo: [
                "kind": "test"
            ]
        )
    }

    private func updatePowerAssertion() {
        if keepSystemAwake {
            guard powerAssertionID == 0 else { return }
            let reason = "Kara scheduled tasks require the Mac to stay awake" as CFString
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoIdleSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &powerAssertionID
            )
            if result != kIOReturnSuccess {
                powerAssertionID = 0
                lastError = "Failed to keep the system awake"
            }
        } else if powerAssertionID != 0 {
            IOPMAssertionRelease(powerAssertionID)
            powerAssertionID = 0
        }
    }

    // MARK: - Timer management

    func startAllTimers() {
        guard schedulerTimer == nil else { return }
        evaluateDueTasks(at: Date())
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateDueTasks(at: Date())
            }
        }
        schedulerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAllTimers() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
    }

    private func evaluateDueTasks(at date: Date) {
        for task in tasks where isDue(task, at: date) {
            executeTask(id: task.id, trigger: .scheduled, scheduledRunKey: runKey(for: task, at: date))
        }
    }

    private func isDue(_ task: ScheduledTask, at date: Date) -> Bool {
        guard task.isEnabled,
              !runningTaskIDs.contains(task.id),
              task.cadence.shouldRun(on: date, calendar: calendar)
        else {
            return false
        }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard components.hour == task.hour,
              components.minute == task.minute
        else {
            return false
        }

        return task.lastScheduledRunKey != runKey(for: task, at: date)
    }

    private func runKey(for task: ScheduledTask, at date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(task.id.uuidString)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)-\(task.hour)-\(task.minute)"
    }

    // MARK: - Task execution

    enum ExecutionTrigger {
        case manual
        case scheduled
    }

    private struct ExecutionResult {
        var status: ScheduledTaskRun.Status
        var prompt: String
        var response: String?
        var turnID: UUID?
        var targetTool: AIToolType?
        var errorMessage: String?
    }

    func runNow(id: UUID) {
        executeTask(id: id, trigger: .manual, scheduledRunKey: nil)
    }

    private func executeTask(id: UUID, trigger: ExecutionTrigger, scheduledRunKey: String?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }),
              !runningTaskIDs.contains(id)
        else {
            return
        }

        runningTaskIDs.insert(id)
        let task = tasks[idx]
        if let scheduledRunKey {
            tasks[idx].lastScheduledRunKey = scheduledRunKey
            saveTasks()
        }

        Task { [weak self] in
            guard let self else { return }
            let result = await self.perform(task)
            await MainActor.run {
                self.finishExecution(taskID: id, taskName: task.name, trigger: trigger, result: result)
            }
        }
    }

    private func perform(_ task: ScheduledTask) async -> ExecutionResult {
        var succeeded = false
        var response: String?
        var turnID: UUID?
        var targetTool: AIToolType?
        var errorMessage: String?

        if let tool = task.targetTool ?? aiService?.preferredTool {
            aiService?.selectedTool = tool
            let result = await aiService?.deliverText(promptForScheduledExecution(task.prompt))
            if let result {
                response = result.output
                turnID = result.turnID
                targetTool = result.targetTool ?? tool.baseTool
                switch result.state {
                case .completed, .delivered:
                    succeeded = true
                case .failed(let message):
                    succeeded = false
                    errorMessage = message
                default:
                    succeeded = true
                }
            } else {
                errorMessage = "AI service unavailable"
            }
        }

        if let channelID = task.targetChannelID {
            imService?.sendMessage(task.prompt, to: channelID)
            succeeded = true
        }

        if task.targetTool == nil, aiService?.preferredTool == nil, task.targetChannelID == nil {
            lastError = "No execution target configured for this task"
            return ExecutionResult(
                status: .failed,
                prompt: task.prompt,
                response: nil,
                turnID: nil,
                targetTool: nil,
                errorMessage: lastError
            )
        }

        return ExecutionResult(
            status: succeeded ? .succeeded : .failed,
            prompt: task.prompt,
            response: response,
            turnID: turnID,
            targetTool: targetTool,
            errorMessage: errorMessage
        )
    }

    private func promptForScheduledExecution(_ prompt: String, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let today = localDateString(now, calendar: calendar)
        let yesterday = localDateString(
            calendar.date(byAdding: .day, value: -1, to: now) ?? now,
            calendar: calendar
        )

        return """
        Kara scheduled task execution rules:
        - Complete quickly. If required inputs are missing or ambiguous, stop and ask for the exact missing path/fields instead of doing broad analysis.
        - Current local date: \(today). Yesterday: \(yesterday).
        - For file-based tasks, only inspect Desktop, Documents, and Downloads. Do not scan Library, hidden directories, system directories, or the whole home folder.
        - First look for Excel/CSV/TSV files modified on \(yesterday) or \(today). If none are found, report that no current data file was found and ask for the data directory and key metric columns.
        - Do not load spreadsheet-specific skills, create workbooks, render charts, or run Python until a current source data file is confirmed.

        User task:
        \(prompt)
        """
    }

    private func localDateString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func finishExecution(
        taskID: UUID,
        taskName: String,
        trigger: ExecutionTrigger,
        result: ExecutionResult
    ) {
        runningTaskIDs.remove(taskID)

        if let idx = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[idx].lastRunAt = Date()
            saveTasks()
        }

        let triggerText = trigger == .manual ? "Manual run" : "Scheduled run"
        let detail: String
        if result.status == .succeeded {
            detail = "\(triggerText) completed"
        } else if let errorPreview = ScheduledTaskRun.preview(result.errorMessage, limit: 220) {
            detail = errorPreview
        } else if let errorPreview = ScheduledTaskRun.preview(lastError, limit: 220) {
            detail = errorPreview
        } else {
            detail = "\(triggerText) failed"
        }
        let response = storedResponse(from: result.response)
        let run = ScheduledTaskRun(
            taskID: taskID,
            taskName: taskName,
            status: result.status,
            detail: detail,
            prompt: result.prompt,
            response: response,
            responsePreview: ScheduledTaskRun.preview(response),
            turnID: result.turnID,
            targetTool: result.targetTool
        )
        runs.insert(
            run,
            at: 0
        )
        unreadRunCount += 1
        if runs.count > 80 {
            runs = Array(runs.prefix(80))
        }
        saveRuns()
        sendCompletionNotification(for: run)
    }

    private func storedResponse(from response: String?) -> String? {
        guard let response,
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard response.count > responseStorageLimit else { return response }
        return String(response.prefix(responseStorageLimit)) + "\n\n[Output truncated by Kara]"
    }

    private func sendCompletionNotification(for run: ScheduledTaskRun) {
        KaraLocalNotificationCenter.post(
            identifier: "kara.task.\(run.id.uuidString)",
            title: run.status == .succeeded ? "Task Completed" : "Task Failed",
            subtitle: run.taskName,
            body: run.responsePreview ?? run.detail,
            userInfo: [
                "kind": "scheduledTask",
                "taskID": run.taskID.uuidString,
                "runID": run.id.uuidString
            ]
        )
    }

    // MARK: - Persistence

    private func saveTasks() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadTasks() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            seedExamplesIfNeeded()
            return
        }

        guard let decoded = try? JSONDecoder().decode([ScheduledTask].self, from: data) else { return }
        tasks = decoded
        if tasks.isEmpty {
            seedExamplesIfNeeded()
        }
    }

    private func seedExamplesIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: exampleSeedStorageKey) else { return }
        tasks = Self.defaultExampleTasks
        UserDefaults.standard.set(true, forKey: exampleSeedStorageKey)
        saveTasks()
    }

    private func saveRuns() {
        if let data = try? JSONEncoder().encode(runs) {
            UserDefaults.standard.set(data, forKey: runsStorageKey)
        }
    }

    private func loadRuns() {
        guard let data = UserDefaults.standard.data(forKey: runsStorageKey),
              let decoded = try? JSONDecoder().decode([ScheduledTaskRun].self, from: data) else { return }
        runs = decoded
    }

    private static var defaultExampleTasks: [ScheduledTask] {
        let baseDate = Date()
        return [
            ScheduledTask(
                name: "每日数据报表更新",
                prompt: """
                请帮我处理每日数据更新：

                1. 读取工作目录中最新的 Excel/CSV 数据文件
                2. 与前一天的数据对比，计算关键指标的日环比变化
                3. 生成数据摘要：
                   - 核心指标的当日值和变化趋势（↑/↓/→）
                   - 异常波动（变化超过 20%）用醒目标记，并分析可能原因
                   - 生成趋势折线图
                4. 输出一份可以直接发给团队的日报
                """,
                cadence: .daily,
                hour: 9,
                minute: 30,
                targetTool: nil,
                isEnabled: false,
                createdAt: baseDate.addingTimeInterval(3)
            ),
            ScheduledTask(
                name: "午间充电站",
                prompt: """
                午休时间到了！帮我放松一下：

                请从以下内容中随机挑 2-3 个给我看：
                1. 一个近期有趣的开源项目（简短介绍它做什么、为什么有意思）
                2. 一条值得收藏的效率技巧
                3. 一段 5 分钟内能读完的技术/产品小知识
                4. 一个轻松但有启发的问题，适合下午重新进入状态
                """,
                cadence: .weekdays,
                hour: 12,
                minute: 30,
                targetTool: nil,
                isEnabled: false,
                createdAt: baseDate.addingTimeInterval(2)
            ),
            ScheduledTask(
                name: "每周竞品动态追踪",
                prompt: """
                请帮我追踪以下竞品的最新动态：

                - Cursor
                - Windsurf
                - GitHub Copilot

                追踪内容：
                1. 上周是否有新版本发布或功能更新
                2. 官方博客、更新日志、社交媒体中的重点信息
                3. 可能值得我们关注或借鉴的变化
                4. 用「影响程度：高/中/低」整理成摘要
                """,
                cadence: .weeklyMonday,
                hour: 10,
                minute: 0,
                targetTool: nil,
                isEnabled: false,
                createdAt: baseDate.addingTimeInterval(1)
            ),
            ScheduledTask(
                name: "每日下载文件夹清理",
                prompt: """
                请帮我整理「下载」文件夹：

                1. 扫描 ~/Downloads 目录中今天新增的文件
                2. 按以下规则归档：
                   - 图片文件（jpg/png/gif/svg）→ 图片
                   - 文档文件（pdf/docx/xlsx/pptx/txt）→ 文档
                   - 压缩包（zip/rar/7z）→ 压缩包
                3. 不确定的文件先列出来，不要删除
                4. 输出本次整理摘要
                """,
                cadence: .daily,
                hour: 18,
                minute: 30,
                targetTool: nil,
                isEnabled: false,
                createdAt: baseDate
            )
        ]
    }
}
