import Foundation
import Observation
@preconcurrency import UserNotifications

enum AgentEndpoint: Equatable, Codable {
    case cli(command: String, arguments: [String])
}

struct AgentSession: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    let createdAt: Date
    var externalID: String?
    var sourceTool: AIToolType?
    var projectName: String?
    var projectPath: String?

    static let defaultTitle = "new session"

    static func makeDefault() -> AgentSession {
        AgentSession(
            id: UUID(),
            title: defaultTitle,
            createdAt: Date(),
            externalID: nil,
            sourceTool: nil,
            projectName: nil,
            projectPath: nil
        )
    }
}

struct AgentRecentSession: Identifiable, Equatable {
    let id: String
    let externalID: String
    let tool: AIToolType
    let title: String
    let updatedAt: Date
    let projectName: String?
    let projectPath: String?

    var displayTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "en_US")
        return formatter.localizedString(for: updatedAt, relativeTo: Date())
    }

    var agentSession: AgentSession {
        AgentSession(
            id: UUID(uuidString: externalID) ?? UUID(),
            title: title,
            createdAt: updatedAt,
            externalID: externalID,
            sourceTool: tool,
            projectName: projectName,
            projectPath: projectPath
        )
    }
}

struct AgentTarget: Equatable, Codable {
    var tool: AIToolType
    var endpoint: AgentEndpoint
    var session: AgentSession
}

struct AgentDeliveryRequest: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let screenshotURL: URL?
    let target: AgentTarget
    let createdAt = Date()
}

enum AgentDeliveryState: Equatable {
    case idle
    case transcribing
    case sending(AgentDeliveryRequest)
    case delivered(AgentDeliveryRequest)
    case running(AgentDeliveryRequest)
    case completed(AgentDeliveryRequest)
    case failed(String)

    var menuLabel: String? {
        switch self {
        case .idle:
            return nil
        case .transcribing:
            return "Transcribing"
        case .sending:
            return "Sending"
        case .delivered:
            return "Submitted"
        case .running:
            return "Running"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        }
    }

    var detailText: String {
        switch self {
        case .idle:
            return "Voice will be sent to the current Agent"
        case .transcribing:
            return "Preparing transcript"
        case .sending(let request):
            return "Sending to \(request.target.tool.compactDisplayName)"
        case .delivered(let request):
            return "Submitted to \(request.target.tool.compactDisplayName)"
        case .running(let request):
            return "\(request.target.tool.compactDisplayName) CLI is running"
        case .completed(let request):
            return "\(request.target.tool.compactDisplayName) CLI completed"
        case .failed(let message):
            return message
        }
    }
}

struct AgentDeliveryResult: Equatable {
    let request: AgentDeliveryRequest?
    let state: AgentDeliveryState
    let turnID: UUID?
    let output: String?
    let targetTool: AIToolType?

    init(
        request: AgentDeliveryRequest?,
        state: AgentDeliveryState,
        turnID: UUID? = nil,
        output: String? = nil,
        targetTool: AIToolType? = nil
    ) {
        self.request = request
        self.state = state
        self.turnID = turnID
        self.output = output
        self.targetTool = targetTool
    }
}

enum KaraLocalNotificationCenter {
    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("Kara notification authorization failed: \(error.localizedDescription)")
            } else {
                print("Kara notification authorization: \(granted ? "granted" : "denied")")
            }
        }
    }

    static func post(
        identifier: String,
        title: String,
        subtitle: String? = nil,
        body: String,
        userInfo: [String: String] = [:]
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle ?? ""
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                add(request, center: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        print("Kara notification authorization failed: \(error.localizedDescription)")
                        return
                    }

                    guard granted else {
                        print("Kara notification authorization denied")
                        return
                    }

                    add(request, center: center)
                }
            case .denied:
                print("Kara notification skipped: permission denied")
            @unknown default:
                print("Kara notification skipped: unknown authorization status")
            }
        }
    }

    private static func add(_ request: UNNotificationRequest, center: UNUserNotificationCenter) {
        center.add(request) { error in
            if let error {
                print("Kara notification add failed: \(error.localizedDescription)")
            } else {
                print("Kara notification posted: \(request.identifier)")
            }
        }
    }
}

/// Manages sending transcribed text to the selected AI tool.
@MainActor
@Observable
final class AIIntegrationService {
    var selectedTool: AIToolType? {
        didSet {
            persist()
            if oldValue?.baseTool != selectedTool?.baseTool {
                loadRecentSessionsForSelectedTool()
            }
        }
    }
    var selectedSession: AgentSession {
        didSet { persistSession() }
    }
    var deliveryState: AgentDeliveryState = .idle
    var recentSessions: [AgentRecentSession] = []
    var recentSessionsByTool: [AIToolType: [AgentRecentSession]] = [:]
    var loadingRecentSessionTools: Set<AIToolType> = []
    var lastResponse: String?
    var lastError: String?
    var lastRequest: AgentDeliveryRequest?
    var lastFailedRequest: AgentDeliveryRequest?
    let bridgeService = AgentBridgeService()

    private let defaultsKey = "Kara.selectedAITool"
    private let enabledToolsDefaultsKey = "Kara.enabledAITools"
    private let sessionDefaultsKey = "Kara.selectedAgentSession"
    private var enabledToolIDs: Set<String>
    private var clearStateTask: Task<Void, Never>?
    private var recentSessionTasks: [AIToolType: Task<Void, Never>] = [:]
    nonisolated private static let cliTimeoutSeconds: TimeInterval = 180

    init() {
        if let savedIDs = UserDefaults.standard.array(forKey: enabledToolsDefaultsKey) as? [String] {
            enabledToolIDs = Set(savedIDs)
        } else {
            enabledToolIDs = Set(AIToolType.allCases.map(\.rawValue))
        }

        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let tool = AIToolType(rawValue: raw) {
            selectedTool = tool.baseTool
        }

        if let data = UserDefaults.standard.data(forKey: sessionDefaultsKey),
           let session = try? JSONDecoder().decode(AgentSession.self, from: data) {
            selectedSession = session
        } else {
            selectedSession = AgentSession.makeDefault()
        }

        if selectedTool == nil {
            selectedTool = preferredTool
        }

        loadRecentSessionsForSelectedTool()
    }

    /// Tools that can currently receive messages.
    var installedTools: [AIToolType] {
        AIToolType.allCases.filter { $0.canSendMessages }
    }

    var enabledTools: Set<AIToolType> {
        Set(AIToolType.allCases.filter { enabledToolIDs.contains($0.baseTool.rawValue) })
    }

    var preferredTool: AIToolType? {
        selectedTool.flatMap {
            let normalizedTool = $0.baseTool
            return normalizedTool.canSendMessages && isToolEnabled(normalizedTool) ? normalizedTool : nil
        }
            ?? installedTools.first(where: { $0 == .codexCLI && isToolEnabled($0) })
            ?? installedTools.first(where: { $0 == .claudeCLI && isToolEnabled($0) })
            ?? installedTools.first(where: { $0 == .hermesCLI && isToolEnabled($0) })
    }

    var statusDetailText: String {
        deliveryState.detailText
    }

    var canSendToSelectedTool: Bool {
        preferredTool?.canSendMessages == true
    }

    func refreshRecentSessions() {
        for tool in AIToolType.allCases {
            loadRecentSessions(for: tool)
        }
    }

    func isToolEnabled(_ tool: AIToolType) -> Bool {
        enabledToolIDs.contains(tool.baseTool.rawValue)
    }

    func setTool(_ tool: AIToolType, enabled: Bool) {
        let normalizedTool = tool.baseTool
        if enabled {
            enabledToolIDs.insert(normalizedTool.rawValue)
        } else {
            enabledToolIDs.remove(normalizedTool.rawValue)
            if selectedTool?.baseTool == normalizedTool {
                selectedTool = nil
            }
        }
        persistEnabledTools()
        loadRecentSessionsForSelectedTool()
    }

    func loadRecentSessionsForSelectedTool() {
        guard let tool = selectedTool?.baseTool ?? preferredTool else {
            recentSessions = []
            return
        }

        loadRecentSessions(for: tool)
    }

    func loadRecentSessions(for tool: AIToolType) {
        let normalizedTool = tool.baseTool
        guard normalizedTool.canSendMessages else {
            recentSessionTasks[normalizedTool]?.cancel()
            loadingRecentSessionTools.remove(normalizedTool)
            recentSessionsByTool[normalizedTool] = []
            if preferredTool == normalizedTool {
                recentSessions = []
            }
            return
        }

        recentSessionTasks[normalizedTool]?.cancel()
        loadingRecentSessionTools.insert(normalizedTool)
        recentSessionsByTool[normalizedTool] = []
        if preferredTool == normalizedTool {
            recentSessions = []
        }

        recentSessionTasks[normalizedTool] = Task { [weak self] in
            let sessions = await Task.detached(priority: .userInitiated) {
                AgentRecentSessionReader.recentSessions(for: normalizedTool, limit: 5)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.loadingRecentSessionTools.remove(normalizedTool)
                self.recentSessionsByTool[normalizedTool] = sessions
                if self.preferredTool == normalizedTool {
                    self.recentSessions = sessions
                }
            }
        }
    }

    func selectRecentSession(_ session: AgentRecentSession) {
        selectedTool = session.tool
        selectedSession = session.agentSession
    }

    func clearSelectedSession(for tool: AIToolType) {
        selectedTool = tool
        selectedSession = AgentSession(
            id: UUID(),
            title: AgentSession.defaultTitle,
            createdAt: Date(),
            externalID: nil,
            sourceTool: tool,
            projectName: nil,
            projectPath: nil
        )
    }

    func markTranscribing() {
        clearStateTask?.cancel()
        deliveryState = .transcribing
    }

    func markFailed(_ message: String) {
        _ = fail(message)
    }

    @discardableResult
    func retryLastRequest() async -> AgentDeliveryResult {
        guard let request = lastFailedRequest ?? lastRequest else {
            return fail("No request available to retry")
        }

        return await deliverText(
            request.text,
            screenshotURL: request.screenshotURL,
            forcedTarget: request.target,
            notifyOnCompletion: true
        )
    }

    /// Send the given text to the currently selected AI tool.
    func sendText(_ text: String) {
        Task {
            _ = await deliverText(text, notifyOnCompletion: true)
        }
    }

    func deliverTextForReply(_ text: String, screenshotURL: URL? = nil) async throws -> String {
        Self.log("deliverTextForReply start: \(Self.previewText(text))")
        let result = await deliverText(text, screenshotURL: screenshotURL)

        switch result.state {
        case .completed:
            let reply = lastResponse?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Self.log("deliverTextForReply completed: \(Self.previewText(reply))")
            return reply.isEmpty ? "Completed" : reply
        case .failed(let message):
            Self.log("deliverTextForReply failed: \(message)")
            throw AIReplyError(message: message)
        default:
            Self.log("deliverTextForReply ended in non-final state")
            throw AIReplyError(message: "AI execution has not completed")
        }
    }

    @discardableResult
    func deliverText(
        _ text: String,
        screenshotURL: URL? = nil,
        forcedTarget: AgentTarget? = nil,
        notifyOnCompletion: Bool = false
    ) async -> AgentDeliveryResult {
        clearStateTask?.cancel()

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            let result = fail("No text to send")
            if notifyOnCompletion {
                notifyDeliveryCompletion(result, prompt: trimmedText)
            }
            return result
        }

        guard preferredTool != nil || forcedTarget != nil else {
            Self.log("deliverText failed: no selected tool")
            let result = fail("No AI tool selected")
            if notifyOnCompletion {
                notifyDeliveryCompletion(result, prompt: trimmedText)
            }
            return result
        }

        if let tool = forcedTarget?.tool.baseTool ?? preferredTool,
           selectedTool != tool {
            selectedTool = tool
        }

        lastError = nil
        lastResponse = nil

        Self.log("bridge turn start: session=\(selectedSession.externalID ?? "new")")
        let bridgeResult = await bridgeService.startTurn(
            text: trimmedText,
            screenshotURL: screenshotURL,
            selectedTool: forcedTarget?.tool.baseTool ?? preferredTool,
            enabledTools: enabledTools,
            selectedSession: selectedSession,
            forcedTarget: forcedTarget,
            onRequestReady: { [weak self] request in
                guard let self else { return }
                self.lastRequest = request
                self.deliveryState = .sending(request)
                self.deliveryState = .running(request)
            }
        )
        Self.log("bridge turn exited: code=\(bridgeResult.exitCode), output=\(Self.previewText(bridgeResult.output))")

        guard let request = bridgeResult.request else {
            if bridgeResult.exitCode == 0 {
                lastResponse = bridgeResult.output
                lastFailedRequest = nil
                deliveryState = .idle
                scheduleStateReset()
                let result = AgentDeliveryResult(
                    request: nil,
                    state: deliveryState,
                    turnID: bridgeResult.turnID,
                    output: bridgeResult.output,
                    targetTool: bridgeResult.route?.target.tool.baseTool
                )
                if notifyOnCompletion {
                    notifyDeliveryCompletion(result, prompt: trimmedText)
                }
                return result
            }

            let result = fail(
                bridgeResult.output,
                turnID: bridgeResult.turnID,
                output: bridgeResult.output
            )
            if notifyOnCompletion {
                notifyDeliveryCompletion(result, prompt: trimmedText)
            }
            return result
        }

        if bridgeResult.exitCode == 0 {
            lastResponse = bridgeResult.output
            lastFailedRequest = nil
            deliveryState = .completed(request)
            scheduleStateReset()
            let result = AgentDeliveryResult(
                request: request,
                state: deliveryState,
                turnID: bridgeResult.turnID,
                output: bridgeResult.output,
                targetTool: bridgeResult.route?.target.tool.baseTool ?? request.target.tool.baseTool
            )
            if notifyOnCompletion {
                notifyDeliveryCompletion(result, prompt: trimmedText)
            }
            return result
        }

        let result = fail(
            bridgeResult.output.isEmpty ? "CLI failed with exit code \(bridgeResult.exitCode)" : bridgeResult.output,
            request: request,
            turnID: bridgeResult.turnID,
            output: bridgeResult.output,
            targetTool: bridgeResult.route?.target.tool.baseTool ?? request.target.tool.baseTool
        )
        if notifyOnCompletion {
            notifyDeliveryCompletion(result, prompt: trimmedText)
        }
        return result
    }

    private func notifyDeliveryCompletion(_ result: AgentDeliveryResult, prompt: String) {
        let isFailed: Bool
        if case .failed = result.state {
            isFailed = true
        } else {
            isFailed = false
        }

        let body = Self.previewNotificationText(result.output)
            ?? Self.previewNotificationText(prompt)
            ?? (isFailed ? "Agent execution failed" : "Agent execution completed")
        let toolName = result.targetTool?.compactDisplayName
            ?? result.request?.target.tool.compactDisplayName
            ?? "Kara"
        var userInfo = [
            "kind": "agentDelivery"
        ]
        if let turnID = result.turnID {
            userInfo["turnID"] = turnID.uuidString
        }

        KaraLocalNotificationCenter.post(
            identifier: "kara.agent.\(result.turnID?.uuidString ?? UUID().uuidString)",
            title: isFailed ? "Agent 执行失败" : "Agent 执行完成",
            subtitle: toolName,
            body: body,
            userInfo: userInfo
        )
    }

    private func endpoint(for tool: AIToolType) -> AgentEndpoint? {
        guard tool.isCommandLine,
              let cliURL = tool.cliExecutableURL
        else {
            return nil
        }
        return .cli(command: cliURL.path, arguments: cliArguments(for: tool))
    }

    // MARK: - CLI

    private func cliArguments(for tool: AIToolType) -> [String] {
        switch tool {
        case .codexDesktop, .codexCLI:
            if selectedSession.sourceTool?.baseTool == .codexCLI,
               let externalID = selectedSession.externalID,
               !externalID.isEmpty {
                return ["exec", "resume", "--skip-git-repo-check", externalID]
            }
            return ["exec", "--skip-git-repo-check", "--sandbox", "read-only"]
        case .claudeDesktop, .claudeCLI:
            return ["-p"]
        case .hermesDesktop, .hermesCLI:
            var arguments = [
                "chat",
                "-Q",
                "--ignore-rules",
                "--max-turns", "3"
            ]
            if selectedSession.sourceTool?.baseTool == .hermesCLI,
               let externalID = selectedSession.externalID,
               !externalID.isEmpty {
                arguments += ["--resume", externalID]
            }
            arguments += ["-q"]
            return arguments
        }
    }

    private func runCLI(request: AgentDeliveryRequest) async -> CLIExecutionResult {
        guard case .cli(let command, let arguments) = request.target.endpoint else {
            return CLIExecutionResult(exitCode: 1, output: "Current target is not a CLI")
        }

        let prompt = Self.promptText(for: request)
        let outputFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kara-codex-\(request.id.uuidString).txt")
        let shouldCaptureCodexLastMessage = request.target.tool.baseTool == .codexCLI
        let shouldSendPromptViaStdin = request.target.tool.baseTool == .codexCLI
            || request.target.tool.baseTool == .claudeCLI

        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)

            var processArguments = arguments
            if shouldCaptureCodexLastMessage {
                if processArguments.count >= 2,
                   processArguments[0] == "exec",
                   processArguments[1] == "resume" {
                    processArguments.insert(contentsOf: ["--output-last-message", outputFileURL.path], at: 2)
                } else {
                    processArguments += ["--output-last-message", outputFileURL.path]
                }
            }
            if request.target.tool.baseTool == .codexCLI,
               let screenshotURL = request.screenshotURL,
               FileManager.default.fileExists(atPath: screenshotURL.path) {
                Self.insertCodexImageArgument(screenshotURL.path, into: &processArguments)
                Self.log("runCLI attaching image: \(screenshotURL.path)")
            } else if request.target.tool.baseTool == .claudeCLI,
                      let screenshotURL = request.screenshotURL,
                      FileManager.default.fileExists(atPath: screenshotURL.path) {
                Self.insertClaudeScreenshotDirectory(screenshotURL.deletingLastPathComponent().path, into: &processArguments)
                Self.log("runCLI exposing screenshot directory to Claude: \(screenshotURL.deletingLastPathComponent().path)")
            } else if request.screenshotURL != nil {
                Self.log("runCLI screenshot available but no image argument for tool=\(request.target.tool.rawValue)")
            }
            process.arguments = shouldSendPromptViaStdin ? processArguments : processArguments + [prompt]
            process.currentDirectoryURL = Self.workingDirectoryURL(for: request.target.session)

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let inputPipe = Pipe()
            let outputCapture = PipeCapture()
            let errorCapture = PipeCapture()
            if shouldSendPromptViaStdin {
                process.standardInput = inputPipe
            }
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    outputCapture.append(data)
                }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    errorCapture.append(data)
                }
            }

            do {
                let promptSource = shouldSendPromptViaStdin ? "stdin" : "argv"
                Self.log("runCLI start: \(command) \(processArguments.joined(separator: " ")); prompt=\(promptSource); cwd=\(process.currentDirectoryURL?.path ?? "")")
                try process.run()
                if shouldSendPromptViaStdin {
                    try inputPipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                    try inputPipe.fileHandleForWriting.close()
                }
                let deadline = Date().addingTimeInterval(Self.cliTimeoutSeconds)
                while process.isRunning && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if process.isRunning {
                    process.terminate()
                    try? await Task.sleep(for: .milliseconds(500))
                    if process.isRunning {
                        process.interrupt()
                    }
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    Self.log("runCLI timeout after \(Int(Self.cliTimeoutSeconds))s")
                    return CLIExecutionResult(
                        exitCode: 124,
                        output: Self.timeoutMessage(
                            output: outputCapture.snapshot(),
                            error: errorCapture.snapshot()
                        )
                    )
                }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let output = String(
                    data: outputCapture.snapshot(),
                    encoding: .utf8
                ) ?? ""
                let error = String(
                    data: errorCapture.snapshot(),
                    encoding: .utf8
                ) ?? ""
                let cleanOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanError = error.trimmingCharacters(in: .whitespacesAndNewlines)

                let codexLastMessage = shouldCaptureCodexLastMessage
                    ? (try? String(contentsOf: outputFileURL, encoding: .utf8))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    : nil
                let successfulOutput = [codexLastMessage, cleanOutput]
                    .compactMap { $0 }
                    .first { !$0.isEmpty } ?? cleanError
                let failedOutput = [cleanOutput, cleanError]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                try? FileManager.default.removeItem(at: outputFileURL)
                Self.log("runCLI finished: status=\(process.terminationStatus)")
                return CLIExecutionResult(
                    exitCode: process.terminationStatus,
                    output: process.terminationStatus == 0 ? successfulOutput : failedOutput
                )
            } catch {
                Self.log("runCLI error: \(error.localizedDescription)")
                return CLIExecutionResult(exitCode: 1, output: error.localizedDescription)
            }
        }.value
    }

    nonisolated private static func workingDirectoryURL(for session: AgentSession) -> URL {
        guard let projectPath = session.projectPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectPath.isEmpty
        else {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        return URL(fileURLWithPath: projectPath)
    }

    // MARK: - Helpers

    nonisolated private static func promptText(for request: AgentDeliveryRequest) -> String {
        guard let screenshotURL = request.screenshotURL else {
            return request.text
        }

        if request.target.tool.baseTool == .codexCLI {
            return """
            Voice transcript:
            \(request.text)

            A screenshot from the same moment was sent as an image attachment with this request.

            Use both the transcript and screenshot to understand my intent and act on it.
            """
        }

        if request.target.tool.baseTool == .claudeCLI {
            return """
            Voice transcript:
            \(request.text)

            A screenshot from the same moment was saved as a PNG file:
            \(screenshotURL.path)

            The screenshot directory has been made readable through --add-dir. Read the screenshot, then use it with the transcript to understand my intent and act on it.
            """
        }

        return """
        Voice transcript:
        \(request.text)

        A screenshot from the same moment was saved as a PNG file:
        \(screenshotURL.path)

        Use both the transcript and screenshot to understand my intent and act on it.
        """
    }

    nonisolated private static func insertCodexImageArgument(_ path: String, into arguments: inout [String]) {
        if arguments.count >= 2,
           arguments[0] == "exec",
           arguments[1] == "resume" {
            arguments.insert(contentsOf: ["--image", path], at: 2)
        } else {
            arguments += ["--image", path]
        }
    }

    nonisolated private static func insertClaudeScreenshotDirectory(_ path: String, into arguments: inout [String]) {
        guard !arguments.contains(path) else { return }
        arguments += ["--add-dir", path]
    }

    nonisolated private static func timeoutMessage(output: Data, error: Data) -> String {
        let outputText = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorText = String(data: error, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let partial = [outputText, errorText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !partial.isEmpty else {
            return "Agent execution timed out after \(Int(Self.cliTimeoutSeconds))s. Try again later or ask a more specific question."
        }

        return """
        Agent execution timed out after \(Int(Self.cliTimeoutSeconds))s.

        Last output:
        \(Self.tail(partial, limit: 1600))
        """
    }

    nonisolated private static func tail(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "..." + String(text.suffix(limit))
    }

    private func fail(
        _ message: String,
        request: AgentDeliveryRequest? = nil,
        turnID: UUID? = nil,
        output: String? = nil,
        targetTool: AIToolType? = nil
    ) -> AgentDeliveryResult {
        lastError = message
        if let request {
            lastFailedRequest = request
            lastRequest = request
        }
        deliveryState = .failed(message)
        scheduleStateReset()
        return AgentDeliveryResult(
            request: request,
            state: deliveryState,
            turnID: turnID,
            output: output ?? message,
            targetTool: targetTool ?? request?.target.tool.baseTool
        )
    }

    private func scheduleStateReset() {
        clearStateTask?.cancel()
        clearStateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.deliveryState = .idle
            }
        }
    }

    nonisolated private static func previewText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 60 else { return trimmed }
        return String(trimmed.prefix(60)) + "..."
    }

    nonisolated private static func previewNotificationText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        guard trimmed.count > 180 else { return trimmed }
        return String(trimmed.prefix(180)) + "..."
    }

    nonisolated private static func log(_ message: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Kara", isDirectory: true)
        let url = directory.appendingPathComponent("agent-cli.log")
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url)
            }
        } catch {
            print("[Kara] \(message)")
        }
    }

    private func persist() {
        if let tool = selectedTool {
            UserDefaults.standard.set(tool.rawValue, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    private func persistEnabledTools() {
        UserDefaults.standard.set(Array(enabledToolIDs).sorted(), forKey: enabledToolsDefaultsKey)
    }

    private func persistSession() {
        guard let data = try? JSONEncoder().encode(selectedSession) else {
            return
        }
        UserDefaults.standard.set(data, forKey: sessionDefaultsKey)
    }
}

private struct CLIExecutionResult: Equatable {
    let exitCode: Int32
    let output: String
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}

private struct AIReplyError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum AgentRecentSessionReader {
    static func recentSessions(for tool: AIToolType, limit: Int) -> [AgentRecentSession] {
        switch tool.baseTool {
        case .codexCLI:
            return codexSessions(for: tool, limit: limit)
        case .claudeCLI:
            return claudeSessions(for: tool, limit: limit)
        case .hermesCLI:
            return hermesSessions(for: tool, limit: limit)
        case .claudeDesktop, .codexDesktop, .hermesDesktop:
            return []
        }
    }

    private static func codexSessions(for tool: AIToolType, limit: Int) -> [AgentRecentSession] {
        let url = homeURL.appendingPathComponent(".codex/session_index.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        return content
            .split(separator: "\n")
            .compactMap { line -> AgentRecentSession? in
                guard let data = String(line).data(using: .utf8),
                      let record = try? JSONDecoder.iso8601Flexible.decode(CodexSessionRecord.self, from: data)
                else {
                    return nil
                }

                return AgentRecentSession(
                    id: record.id,
                    externalID: record.id,
                    tool: tool,
                    title: cleanTitle(record.threadName, fallback: "Codex session"),
                    updatedAt: record.updatedAt,
                    projectName: nil,
                    projectPath: nil
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    private static func claudeSessions(for tool: AIToolType, limit: Int) -> [AgentRecentSession] {
        let projectsURL = homeURL.appendingPathComponent(".claude/projects")
        guard let files = recursiveJSONLFiles(in: projectsURL) else {
            return []
        }

        return files
            .compactMap { claudeSession(from: $0, tool: tool) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    private static func claudeSession(from url: URL, tool: AIToolType) -> AgentRecentSession? {
        let sessionID = url.deletingPathExtension().lastPathComponent
        let updatedAt = fileModifiedDate(url) ?? Date.distantPast

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return AgentRecentSession(
                id: sessionID,
                externalID: sessionID,
                tool: tool,
                title: cleanTitle(sessionID, fallback: "Claude session"),
                updatedAt: updatedAt,
                projectName: projectName(fromClaudeProjectURL: url),
                projectPath: nil
            )
        }

        var fallbackTitle: String?
        var sessionProjectName = projectName(fromClaudeProjectURL: url)
        var sessionProjectPath: String?
        for line in content.split(separator: "\n").prefix(80) {
            guard let object = jsonObject(from: String(line)) else {
                continue
            }

            if let cwd = object["cwd"] as? String {
                if sessionProjectPath == nil {
                    sessionProjectPath = cwd
                }
                if sessionProjectName == nil {
                    sessionProjectName = projectName(fromPath: cwd)
                }
            }

            if object["type"] as? String == "ai-title",
               let title = object["aiTitle"] as? String {
                let externalID = object["sessionId"] as? String ?? sessionID
                return AgentRecentSession(
                    id: externalID,
                    externalID: externalID,
                    tool: tool,
                    title: cleanTitle(title, fallback: "Claude session"),
                    updatedAt: updatedAt,
                    projectName: sessionProjectName,
                    projectPath: sessionProjectPath
                )
            }

            if fallbackTitle == nil,
               object["type"] as? String == "user",
               let message = object["message"] as? [String: Any] {
                fallbackTitle = textFromClaudeContent(message["content"])
            }

            if fallbackTitle == nil,
               object["type"] as? String == "queue-operation",
               let content = object["content"] as? String {
                fallbackTitle = content
            }
        }

        return AgentRecentSession(
            id: sessionID,
            externalID: sessionID,
            tool: tool,
            title: cleanTitle(fallbackTitle ?? sessionID, fallback: "Claude session"),
            updatedAt: updatedAt,
            projectName: sessionProjectName,
            projectPath: sessionProjectPath
        )
    }

    private static func hermesSessions(for tool: AIToolType, limit: Int) -> [AgentRecentSession] {
        let sessionsURL = homeURL.appendingPathComponent(".hermes/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { hermesSession(from: $0, tool: tool) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    private static func hermesSession(from url: URL, tool: AIToolType) -> AgentRecentSession? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let sessionID = object["session_id"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        let updatedAt = (object["timestamp"] as? String).flatMap(parseDate)
            ?? fileModifiedDate(url)
            ?? Date.distantPast

        var title: String?
        if let request = object["request"] as? [String: Any],
           let body = request["body"] as? [String: Any],
           let messages = body["messages"] as? [[String: Any]] {
            title = messages.reversed().compactMap { message -> String? in
                guard message["role"] as? String == "user" else {
                    return nil
                }
                return message["content"] as? String
            }.first
        }

        return AgentRecentSession(
            id: "\(sessionID)-\(Int(updatedAt.timeIntervalSince1970))-\(url.deletingPathExtension().lastPathComponent)",
            externalID: sessionID,
            tool: tool,
            title: cleanTitle(title ?? sessionID, fallback: "Hermes session"),
            updatedAt: updatedAt,
            projectName: projectName(fromHermesObject: object),
            projectPath: projectPath(fromHermesObject: object)
        )
    }

    private static func recursiveJSONLFiles(in url: URL) -> [URL]? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
    }

    private static func fileModifiedDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func textFromClaudeContent(_ content: Any?) -> String? {
        if let text = content as? String {
            return text
        }

        if let parts = content as? [[String: Any]] {
            return parts.compactMap { part in
                part["text"] as? String
            }.joined(separator: " ")
        }

        return nil
    }

    private static func cleanTitle(_ title: String?, fallback: String) -> String {
        let cleaned = (title ?? fallback)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return fallback
        }

        return String(cleaned.prefix(42))
    }

    private static func projectName(fromPath path: String?) -> String? {
        guard let path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func projectName(fromClaudeProjectURL url: URL) -> String? {
        let folder = url.deletingLastPathComponent().lastPathComponent
        guard folder.hasPrefix("-") else {
            return nil
        }

        let components = folder
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }
        return components.last
    }

    private static func projectName(fromHermesObject object: [String: Any]) -> String? {
        for key in ["project", "workspace", "cwd", "directory", "root", "repo", "repository"] {
            if let value = object[key] as? String,
               let projectName = projectName(fromPath: value) {
                return projectName
            }
        }
        return nil
    }

    private static func projectPath(fromHermesObject object: [String: Any]) -> String? {
        for key in ["project", "workspace", "cwd", "directory", "root", "repo", "repository"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func parseDate(_ string: String) -> Date? {
        JSONDecoder.dateDecodingStrategyDate(from: string)
    }

    private static var homeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
}

private struct CodexSessionRecord: Decodable {
    let id: String
    let threadName: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
        case updatedAt = "updated_at"
    }
}

private extension JSONDecoder {
    static var iso8601Flexible: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = dateDecodingStrategyDate(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported date format: \(value)"
            )
        }
        return decoder
    }

    static func dateDecodingStrategyDate(from value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        if let date = standardFormatter.date(from: value) {
            return date
        }

        let hermesFormatter = DateFormatter()
        hermesFormatter.locale = Locale(identifier: "en_US_POSIX")
        hermesFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return hermesFormatter.date(from: value)
    }
}
