import Foundation

struct AgentSessionRouter {
    private let defaultsKey = "Kara.AgentBridge.lastSuccessfulTarget"

    func judgeWithTemporaryAgent(
        text: String,
        enabledTools: Set<AIToolType>
    ) async -> AgentRouteJudgeDecision? {
        let availableTools = routableTools(enabledTools: enabledTools)
        guard let judgeTool = availableTools.first else { return nil }

        let session = newSession(for: judgeTool)
        guard let target = makeTarget(tool: judgeTool, session: session) else { return nil }

        let request = AgentDeliveryRequest(
            text: judgePrompt(text: text, enabledTools: enabledTools),
            screenshotURL: nil,
            target: target
        )
        let result = await AgentCLIAdapter.run(request: request)
        guard result.exitCode == 0 else { return nil }
        return AgentRouteJudgeDecision.parse(result.output)
    }

    func controlResult(
        for decision: AgentRouteJudgeDecision,
        text: String,
        enabledTools: Set<AIToolType>
    ) -> AgentBridgeControlResult? {
        let availableTools = routableTools(enabledTools: enabledTools)

        switch decision.intent {
        case .queryRoute:
            if let target = lastSuccessfulTarget() {
                return AgentBridgeControlResult(
                    message: "Current route: \(target.tool.compactDisplayName) CLI · \(sessionLabel(target.session))",
                    route: AgentBridgeRoute(target: target, reason: "Temporary Agent judge answered current route")
                )
            }
            return AgentBridgeControlResult(
                message: "No current Agent route yet. Say a task, or say \"use Codex\", \"use Claude\", or \"use Hermes\".",
                route: nil
            )

        case .querySessions:
            return AgentBridgeControlResult(
                message: recentSessionsSummary(tool: decision.tool, enabledTools: enabledTools),
                route: nil
            )

        case .switchRoute:
            guard !availableTools.isEmpty else {
                return AgentBridgeControlResult(message: "No enabled Agent CLI is available.", route: nil)
            }

            let tools = decision.tool.map { [$0] } ?? availableTools
            if let sessionID = decision.sessionID,
               let target = targetFromSessionID(sessionID, tools: tools) {
                let route = AgentBridgeRoute(target: target, reason: "Temporary Agent judge selected a session")
                recordSuccess(target)
                return AgentBridgeControlResult(
                    message: "Switched route to \(target.tool.compactDisplayName) CLI · \(sessionLabel(target.session))",
                    route: route
                )
            }

            if let target = targetFromSessionTitle(decision.sessionTitle, tools: tools) {
                let route = AgentBridgeRoute(target: target, reason: "Temporary Agent judge matched a session")
                recordSuccess(target)
                return AgentBridgeControlResult(
                    message: "Switched route to \(target.tool.compactDisplayName) CLI · \(sessionLabel(target.session))",
                    route: route
                )
            }

            if let target = targetFromSessionMatch(text: text, tools: tools) {
                let route = AgentBridgeRoute(target: target, reason: "Temporary Agent judge requested session matching")
                recordSuccess(target)
                return AgentBridgeControlResult(
                    message: "Switched route to \(target.tool.compactDisplayName) CLI · \(sessionLabel(target.session))",
                    route: route
                )
            }

            if let tool = decision.tool, availableTools.contains(tool),
               let target = lastSuccessfulTarget().flatMap({ $0.tool.baseTool == tool ? $0 : nil })
                    ?? makeTarget(tool: tool, session: newSession(for: tool)) {
                let route = AgentBridgeRoute(target: target, reason: "Temporary Agent judge selected \(target.tool.compactDisplayName) CLI")
                recordSuccess(target)
                return AgentBridgeControlResult(
                    message: "Switched route to \(target.tool.compactDisplayName) CLI · \(sessionLabel(target.session))",
                    route: route
                )
            }

            return AgentBridgeControlResult(
                message: "I could not find the session the judge selected. Try naming the Agent and a more specific session title.",
                route: nil
            )

        case .newSession:
            let tool = decision.tool.flatMap { availableTools.contains($0) ? $0 : nil }
                ?? lastSuccessfulTarget().flatMap { availableTools.contains($0.tool.baseTool) ? $0.tool.baseTool : nil }
                ?? availableTools.first
            guard let tool,
                  let target = makeTarget(tool: tool, session: newSession(for: tool))
            else {
                return AgentBridgeControlResult(message: "No enabled Agent CLI is available.", route: nil)
            }

            let route = AgentBridgeRoute(target: target, reason: "Temporary Agent judge requested a new session")
            recordSuccess(target)
            return AgentBridgeControlResult(
                message: "Started a new route: \(target.tool.compactDisplayName) CLI · new session",
                route: route
            )

        case .send, .unknown:
            return nil
        }
    }

    func route(
        for decision: AgentRouteJudgeDecision,
        text: String,
        selectedSession: AgentSession,
        enabledTools: Set<AIToolType>
    ) -> AgentBridgeRoute? {
        guard decision.intent == .send else { return nil }
        let intent = VoiceRoutingIntent(text: text)
        let availableTools = routableTools(enabledTools: enabledTools)
        guard !availableTools.isEmpty else { return nil }

        if decision.newSession == true {
            let tool = decision.tool.flatMap { availableTools.contains($0) ? $0 : nil }
                ?? lastSuccessfulTarget().flatMap { availableTools.contains($0.tool.baseTool) ? $0.tool.baseTool : nil }
                ?? availableTools.first
            return tool
                .flatMap { makeTarget(tool: $0, session: newSession(for: $0)) }
                .map { AgentBridgeRoute(target: $0, reason: "Temporary Agent judge requested a new session for this request") }
        }

        let tools = decision.tool.map { [$0] } ?? availableTools
        if intent.allowsSessionTargeting {
            if let sessionID = decision.sessionID,
               let target = targetFromSessionID(sessionID, tools: tools) {
                return AgentBridgeRoute(target: target, reason: "Temporary Agent judge selected a session")
            }

            if let target = targetFromSessionTitle(decision.sessionTitle, tools: tools) {
                return AgentBridgeRoute(target: target, reason: "Temporary Agent judge matched a session")
            }
        }

        if let tool = decision.tool, availableTools.contains(tool) {
            if intent.allowsSessionTargeting,
               let lastTarget = lastSuccessfulTarget(),
               lastTarget.tool.baseTool == tool {
                return AgentBridgeRoute(target: lastTarget, reason: "Temporary Agent judge selected \(tool.compactDisplayName) CLI")
            }
            let session = intent.allowsSessionTargeting && selectedSession.sourceTool?.baseTool == tool ? selectedSession : newSession(for: tool)
            return makeTarget(tool: tool, session: session)
                .map { AgentBridgeRoute(target: $0, reason: "Temporary Agent judge selected \(tool.compactDisplayName) CLI") }
        }

        return nil
    }

    func controlCommand(
        text: String,
        enabledTools: Set<AIToolType>
    ) -> AgentBridgeControlResult? {
        let intent = VoiceRoutingIntent(text: text)

        if intent.isRouteStatusQuery {
            if let target = lastSuccessfulTarget() {
                let session = sessionLabel(target.session)
                return AgentBridgeControlResult(
                    message: "Current route: \(target.tool.compactDisplayName) CLI · \(session)",
                    route: AgentBridgeRoute(target: target, reason: "Voice asked for the current route")
                )
            }

            return AgentBridgeControlResult(
                message: "No current Agent route yet. Say a task, or say \"use Codex\", \"use Claude\", or \"use Hermes\".",
                route: nil
            )
        }

        if intent.isSessionHistoryQuery {
            return AgentBridgeControlResult(
                message: recentSessionsSummary(intent: intent, enabledTools: enabledTools),
                route: nil
            )
        }

        if intent.wantsNewSession && !intent.hasTaskVerb {
            let availableTools = routableTools(enabledTools: enabledTools)
            let tool = intent.explicitTool.flatMap { availableTools.contains($0) ? $0 : nil }
                ?? lastSuccessfulTarget().flatMap { availableTools.contains($0.tool.baseTool) ? $0.tool.baseTool : nil }
                ?? availableTools.first

            guard let tool,
                  let target = makeTarget(tool: tool, session: newSession(for: tool))
            else {
                return AgentBridgeControlResult(message: "No enabled Agent CLI is available.", route: nil)
            }

            let route = AgentBridgeRoute(target: target, reason: "Voice switched to a new \(target.tool.compactDisplayName) session")
            recordSuccess(target)
            return AgentBridgeControlResult(
                message: "Started a new route: \(target.tool.compactDisplayName) CLI · new session",
                route: route
            )
        }

        guard intent.isSwitchOnlyCommand else {
            return nil
        }

        let availableTools = routableTools(enabledTools: enabledTools)
        guard !availableTools.isEmpty else {
            return AgentBridgeControlResult(message: "No enabled Agent CLI is available.", route: nil)
        }

        if let target = targetFromSessionMatch(text: intent.text, tools: availableTools) {
            let route = AgentBridgeRoute(target: target, reason: "Voice switched to a matching session")
            recordSuccess(target)
            return AgentBridgeControlResult(
                message: "Switched route to \(target.tool.compactDisplayName) CLI · \(sessionLabel(target.session))",
                route: route
            )
        }

        if let tool = intent.explicitTool, availableTools.contains(tool) {
            let target = lastSuccessfulTarget().flatMap { lastTarget in
                lastTarget.tool.baseTool == tool ? lastTarget : nil
            } ?? makeTarget(tool: tool, session: newSession(for: tool))

            guard let target else {
                return AgentBridgeControlResult(message: "\(tool.displayName) installation was not detected.", route: nil)
            }
            let route = AgentBridgeRoute(target: target, reason: "Voice switched to \(target.tool.compactDisplayName) CLI")
            recordSuccess(target)
            return AgentBridgeControlResult(
                message: "Switched route to \(target.tool.compactDisplayName) CLI · \(sessionLabel(target.session))",
                route: route
            )
        }

        return AgentBridgeControlResult(
            message: "I could not find that Agent or session. Try saying \"use Codex\", \"use Claude\", or name part of the session title.",
            route: nil
        )
    }

    func route(
        text: String,
        selectedTool: AIToolType?,
        enabledTools: Set<AIToolType>,
        selectedSession: AgentSession,
        forcedTarget: AgentTarget?
    ) -> Result<AgentBridgeRoute, AgentBridgeRouteError> {
        if let forcedTarget {
            guard enabledTools.contains(forcedTarget.tool.baseTool) else {
                return .failure(AgentBridgeRouteError(message: "\(forcedTarget.tool.displayName) is disabled in Settings"))
            }
            return .success(
                AgentBridgeRoute(
                    target: forcedTarget,
                    reason: "Using the Agent/session bound to this retry"
                )
            )
        }

        let intent = VoiceRoutingIntent(text: text)
        let availableTools = routableTools(enabledTools: enabledTools)

        if let target = targetForVoiceIntent(
            intent,
            availableTools: availableTools,
            selectedSession: selectedSession
        ) {
            return .success(
                AgentBridgeRoute(
                    target: target,
                    reason: routeReason(for: intent, target: target)
                )
            )
        }

        if let lastTarget = lastSuccessfulTarget(),
           lastTarget.tool.canSendMessages,
           enabledTools.contains(lastTarget.tool.baseTool) {
            return .success(
                AgentBridgeRoute(
                    target: lastTarget,
                    reason: "Reusing the last successful Agent/session"
                )
            )
        }

        let selectedBaseTool = selectedTool?.baseTool
        let tool = selectedBaseTool.flatMap {
            enabledTools.contains($0) && $0.canSendMessages ? $0 : nil
        } ?? availableTools.first

        guard let tool else {
            return .failure(AgentBridgeRouteError(message: "No available Agent CLI detected"))
        }

        let session = selectedSession.sourceTool?.baseTool == tool ? selectedSession : newSession(for: tool)
        guard let endpoint = AgentCLIAdapter.endpoint(for: tool, session: session) else {
            return .failure(AgentBridgeRouteError(message: "\(tool.displayName) installation was not detected"))
        }

        let target = AgentTarget(
            tool: tool,
            endpoint: endpoint,
            session: session
        )

        return .success(
            AgentBridgeRoute(
                target: target,
                reason: selectedTool == nil ? "Automatically selected an available Agent" : "Using the current Agent/session"
            )
        )
    }

    func recordSuccess(_ target: AgentTarget) {
        guard let data = try? JSONEncoder().encode(target) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func lastSuccessfulTarget() -> AgentTarget? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let target = try? JSONDecoder().decode(AgentTarget.self, from: data),
              target.tool.canSendMessages
        else {
            return nil
        }
        return target
    }

    private func preferredInstalledTool(enabledTools: Set<AIToolType>) -> AIToolType? {
        [.codexCLI, .claudeCLI, .hermesCLI].first {
            $0.canSendMessages && enabledTools.contains($0)
        }
    }

    private func routableTools(enabledTools: Set<AIToolType>) -> [AIToolType] {
        [.codexCLI, .claudeCLI, .hermesCLI].filter {
            $0.canSendMessages && enabledTools.contains($0)
        }
    }

    private func targetForVoiceIntent(
        _ intent: VoiceRoutingIntent,
        availableTools: [AIToolType],
        selectedSession: AgentSession
    ) -> AgentTarget? {
        guard !availableTools.isEmpty else { return nil }

        if intent.wantsNewSession {
            let tool = intent.explicitTool.flatMap { availableTools.contains($0) ? $0 : nil }
                ?? lastSuccessfulTarget().flatMap { availableTools.contains($0.tool.baseTool) ? $0.tool.baseTool : nil }
                ?? availableTools.first
            return tool.flatMap { makeTarget(tool: $0, session: newSession(for: $0)) }
        }

        if intent.allowsSessionTargeting,
           let target = targetFromSessionMatch(text: intent.text, tools: availableTools) {
            return target
        }

        if let tool = intent.explicitTool, availableTools.contains(tool) {
            if let lastTarget = lastSuccessfulTarget(),
               lastTarget.tool.baseTool == tool,
               lastTarget.tool.canSendMessages {
                return lastTarget
            }

            let session = selectedSession.sourceTool?.baseTool == tool ? selectedSession : newSession(for: tool)
            return makeTarget(tool: tool, session: session)
        }

        return nil
    }

    private func targetFromSessionMatch(text: String, tools: [AIToolType]) -> AgentTarget? {
        guard let session = bestSessionMatch(for: text, tools: tools) else {
            return nil
        }

        return makeTarget(tool: session.tool.baseTool, session: session.agentSession)
    }

    private func targetFromSessionID(_ sessionID: String, tools: [AIToolType]) -> AgentTarget? {
        let normalizedID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }

        return sessions(for: tools)
            .first { $0.externalID == normalizedID || $0.id == normalizedID }
            .flatMap { makeTarget(tool: $0.tool.baseTool, session: $0.agentSession) }
    }

    private func targetFromSessionTitle(_ title: String?, tools: [AIToolType]) -> AgentTarget? {
        guard let title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        guard let session = bestSessionMatch(for: title, tools: tools) else {
            return nil
        }

        return makeTarget(tool: session.tool.baseTool, session: session.agentSession)
    }

    private func sessions(for tools: [AIToolType], limit: Int = 20) -> [AgentRecentSession] {
        tools.flatMap { AgentRecentSessionReader.recentSessions(for: $0, limit: limit) }
    }

    private func targetFromSessionMatch(intent: VoiceRoutingIntent, tools: [AIToolType]) -> AgentTarget? {
        let searchTools: [AIToolType]
        if let explicitTool = intent.explicitTool, tools.contains(explicitTool) {
            searchTools = [explicitTool]
        } else {
            searchTools = tools
        }

        return targetFromSessionMatch(text: intent.text, tools: searchTools)
    }

    private func makeTarget(tool: AIToolType, session: AgentSession) -> AgentTarget? {
        guard let endpoint = AgentCLIAdapter.endpoint(for: tool, session: session) else {
            return nil
        }

        return AgentTarget(tool: tool, endpoint: endpoint, session: session)
    }

    private func newSession(for tool: AIToolType) -> AgentSession {
        AgentSession(
            id: UUID(),
            title: AgentSession.defaultTitle,
            createdAt: Date(),
            externalID: nil,
            sourceTool: tool,
            projectName: nil,
            projectPath: nil
        )
    }

    private func bestSessionMatch(for text: String, tools: [AIToolType]) -> AgentRecentSession? {
        let sessions = sessions(for: tools)
        let query = VoiceSessionQuery(text: text)
        return sessions
            .map { session in (session, score(session: session, query: query)) }
            .filter { $0.1 >= 12 }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.updatedAt > $1.0.updatedAt
                }
                return $0.1 > $1.1
            }
            .first?
            .0
    }

    private func score(session: AgentRecentSession, query: VoiceSessionQuery) -> Int {
        let normalizedText = query.normalized
        let title = normalize(session.title)
        let projectName = normalize(session.projectName ?? "")
        let projectPath = normalize(session.projectPath ?? "")
        var score = 0

        if !title.isEmpty, normalizedText.contains(title) || title.contains(normalizedText) {
            score += 80
        }
        if !projectName.isEmpty, normalizedText.contains(projectName) || projectName.contains(normalizedText) {
            score += 35
        }
        if !projectPath.isEmpty, normalizedText.contains(projectPath) {
            score += 20
        }

        for term in query.terms {
            let normalizedTerm = normalize(term)
            guard normalizedTerm.count >= 2 else { continue }
            if title.contains(normalizedTerm) {
                score += min(20, normalizedTerm.count * 2)
            }
            if projectName.contains(normalizedTerm) {
                score += min(14, normalizedTerm.count)
            }
        }

        return score
    }

    private func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func routeReason(for intent: VoiceRoutingIntent, target: AgentTarget) -> String {
        if intent.wantsNewSession {
            return "Voice requested a new \(target.tool.compactDisplayName) session"
        }
        if intent.explicitTool != nil {
            return "Voice selected \(target.tool.compactDisplayName) CLI"
        }
        if target.session.externalID != nil {
            return "Voice matched a recent session"
        }
        return "Voice routed to an available Agent"
    }

    private func recentSessionsSummary(intent: VoiceRoutingIntent, enabledTools: Set<AIToolType>) -> String {
        recentSessionsSummary(tool: intent.explicitTool, enabledTools: enabledTools)
    }

    private func recentSessionsSummary(tool explicitTool: AIToolType?, enabledTools: Set<AIToolType>) -> String {
        let tools: [AIToolType]
        if let explicitTool {
            tools = [explicitTool].filter { enabledTools.contains($0) && $0.canSendMessages }
        } else {
            tools = routableTools(enabledTools: enabledTools)
        }

        let sessions = tools
            .flatMap { AgentRecentSessionReader.recentSessions(for: $0, limit: 5) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(8)

        guard !sessions.isEmpty else {
            return "No recent sessions were found for the enabled Agent tools."
        }

        let lines = sessions.enumerated().map { index, session in
            "\(index + 1). \(session.tool.compactDisplayName) · \(session.title)"
        }
        return "Recent sessions:\n" + lines.joined(separator: "\n")
    }

    private func sessionLabel(_ session: AgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != AgentSession.defaultTitle {
            return title
        }
        return session.externalID ?? AgentSession.defaultTitle
    }

    private func judgePrompt(text: String, enabledTools: Set<AIToolType>) -> String {
        let availableTools = routableTools(enabledTools: enabledTools)
        let sessionLines = availableTools
            .flatMap { tool in AgentRecentSessionReader.recentSessions(for: tool, limit: 12) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .enumerated()
            .map { index, session in
                let project = session.projectName.map { " project=\($0)" } ?? ""
                return "\(index + 1). tool=\(session.tool.rawValue) id=\(session.externalID) title=\(session.title)\(project)"
            }
            .joined(separator: "\n")

        let lastRouteLine: String
        if let lastTarget = lastSuccessfulTarget() {
            lastRouteLine = "tool=\(lastTarget.tool.rawValue) sessionID=\(lastTarget.session.externalID ?? "new") title=\(lastTarget.session.title)"
        } else {
            lastRouteLine = "none"
        }

        return """
        You are Kara's temporary routing judge. You are not the final task agent.
        Decide how Kara should handle the user's voice transcript.

        Return only compact JSON. No markdown. No explanation.

        JSON schema:
        {
          "intent": "send" | "switch_route" | "new_session" | "query_sessions" | "query_route" | "unknown",
          "tool": "codex-cli" | "claude-cli" | "hermes-cli" | null,
          "sessionID": string | null,
          "sessionTitle": string | null,
          "newSession": boolean,
          "confidence": 0.0-1.0
        }

        Rules:
        - If the transcript asks to switch, go back, resume, continue, or use a specific Agent/session, intent is switch_route unless it explicitly asks to start a new session.
        - If it asks to create/open/start a new session, intent is new_session.
        - If it asks what sessions exist or asks for session history, intent is query_sessions.
        - If it asks who/what current route is, intent is query_route.
        - Otherwise intent is send.
        - For normal task requests, choose only a tool and leave sessionID/sessionTitle null.
        - Prefer an exact sessionID from the session list only when the transcript explicitly asks to switch, resume, continue, or names a specific session/project.
        - Do not perform the user task.

        Current route:
        \(lastRouteLine)

        Available recent sessions:
        \(sessionLines.isEmpty ? "none" : sessionLines)

        Voice transcript:
        \(text)
        """
    }
}

struct AgentRouteJudgeDecision: Equatable {
    enum Intent: String, Equatable {
        case send
        case switchRoute = "switch_route"
        case newSession = "new_session"
        case querySessions = "query_sessions"
        case queryRoute = "query_route"
        case unknown
    }

    let intent: Intent
    let tool: AIToolType?
    let sessionID: String?
    let sessionTitle: String?
    let newSession: Bool?
    let confidence: Double

    static func parse(_ output: String) -> AgentRouteJudgeDecision? {
        guard let data = jsonData(from: output),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let rawIntent = (object["intent"] as? String) ?? "unknown"
        let intent = Intent(rawValue: rawIntent) ?? .unknown
        let tool = (object["tool"] as? String)
            .flatMap(AIToolType.init(rawValue:))?
            .baseTool
        let confidence = object["confidence"] as? Double
            ?? (object["confidence"] as? NSNumber)?.doubleValue
            ?? 0

        return AgentRouteJudgeDecision(
            intent: intent,
            tool: tool,
            sessionID: object["sessionID"] as? String,
            sessionTitle: object["sessionTitle"] as? String,
            newSession: object["newSession"] as? Bool,
            confidence: confidence
        )
    }

    private static func jsonData(from output: String) -> Data? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else {
            return nil
        }

        let json = String(trimmed[start...end])
        return json.data(using: .utf8)
    }
}

private struct VoiceRoutingIntent {
    let text: String
    let normalized: String
    let explicitTool: AIToolType?

    init(text: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalized = VoiceRoutingIntent.normalize(text)
        self.explicitTool = VoiceRoutingIntent.detectTool(in: normalized)
    }

    var wantsNewSession: Bool {
        let compactPhrase = containsAny(["新建session", "新开session", "新建会话", "新开会话", "新的session", "新的会话", "newsession", "newchat", "newconversation"])
        let hasNewVerb = containsAny(["新建", "新开", "新的", "单独开", "另开", "new"])
        let hasSessionWord = containsAny(["session", "cesion", "esion", "会话", "chat", "conversation"])
        return compactPhrase || (hasNewVerb && hasSessionWord)
    }

    var isSessionHistoryQuery: Bool {
        let asksForSessions = containsAny(["有哪些session", "有哪些cesion", "有哪些esion", "有哪些会话", "列出session", "列出会话", "查session", "查cesion", "查esion", "查会话", "session列表", "会话列表", "listsession", "show sessions"])
        let asksForHistory = containsAny(["历史记录", "最近会话", "最近session", "最近cesion", "最近esion", "历史session", "history"])
        let explicitAgentListQuery = explicitTool != nil && containsAny(["有哪些", "列出", "最近", "历史"])
        return asksForSessions || asksForHistory
            || explicitAgentListQuery
    }

    var isRouteStatusQuery: Bool {
        containsAny(["当前发给谁", "发给哪个agent", "现在用哪个agent", "当前agent", "当前会话", "当前session", "currentroute", "currentagent"])
    }

    var isSwitchOnlyCommand: Bool {
        guard hasSwitchVerb else { return false }

        if hasStrictSwitchVerb {
            return true
        }

        return !hasTaskVerb
    }

    var hasTaskVerb: Bool {
        containsAny(["帮我", "看一下", "检查", "查", "查询", "调查", "修", "生成", "写", "解释", "总结", "分析", "发送", "处理", "测试", "截图", "访问", "打开", "支持", "结论", "提交", "发布", "打包", "安装", "fix", "create", "write", "explain", "summarize", "check", "test", "open", "visit", "release"])
    }

    var allowsSessionTargeting: Bool {
        wantsNewSession
            || isSessionHistoryQuery
            || isRouteStatusQuery
            || hasStrictSwitchVerb
            || containsAny(["session", "cesion", "esion", "会话", "项目", "project", "继续", "恢复", "上次", "之前", "刚才", "最近", "历史", "resume"])
    }

    private var hasSwitchVerb: Bool {
        hasStrictSwitchVerb || containsAny(["使用", "用", "use"])
    }

    private var hasStrictSwitchVerb: Bool {
        containsAny(["切到", "切换到", "换到", "回到", "恢复到", "继续用", "switchto"])
    }

    private func containsAny(_ values: [String]) -> Bool {
        values.contains { normalized.contains(VoiceRoutingIntent.normalize($0)) }
    }

    private static func detectTool(in normalized: String) -> AIToolType? {
        if normalized.contains("codex") {
            return .codexCLI
        }
        if normalized.contains("claude") || normalized.contains("cloude") || normalized.contains("cloud") {
            return .claudeCLI
        }
        if normalized.contains("hermes") {
            return .hermesCLI
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private struct VoiceSessionQuery {
    let normalized: String
    let terms: [String]

    init(text: String) {
        self.normalized = VoiceSessionQuery.normalize(text)
        self.terms = VoiceSessionQuery.buildTerms(from: text)
    }

    private static func buildTerms(from text: String) -> [String] {
        var normalized = normalize(text)

        let removablePhrases = [
            "切换到", "切到", "换到", "回到", "恢复到", "继续用", "使用", "用",
            "codex", "claude", "cloude", "cloud", "hermes", "agent", "cli",
            "session", "cesion", "esion", "会话", "上", "里", "里面", "里边",
            "的", "那个", "一下", "帮我"
        ]
        for phrase in removablePhrases {
            normalized = normalized.replacingOccurrences(of: normalize(phrase), with: "")
        }

        var terms: [String] = []
        if normalized.count >= 2 {
            terms.append(normalized)
        }

        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        let rawTerms = text
            .components(separatedBy: separators)
            .map { normalize($0) }
            .filter { term in
                guard term.count >= 2 else { return false }
                return !removablePhrases.contains { normalize($0) == term }
            }

        terms.append(contentsOf: rawTerms)
        terms.append(contentsOf: phraseWindows(from: normalized, minLength: 4, maxLength: 14))

        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    private static func phraseWindows(from text: String, minLength: Int, maxLength: Int) -> [String] {
        let chars = Array(text)
        guard chars.count >= minLength else { return [] }

        var windows: [String] = []
        let upperLength = min(maxLength, chars.count)
        for length in stride(from: upperLength, through: minLength, by: -1) {
            guard chars.count >= length else { continue }
            for start in 0...(chars.count - length) {
                windows.append(String(chars[start..<(start + length)]))
            }
        }
        return windows
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
