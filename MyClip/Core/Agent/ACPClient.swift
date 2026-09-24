import Foundation

public struct ACPCommand: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]

    public init(executable: URL, arguments: [String] = [], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// Environment variable prefixes that a hosting agent session leaks into MyClip when it launches the app.
    /// `CLAUDE_CODE_ENTRYPOINT=claude-desktop` makes Claude Code trust the host's short-lived `ANTHROPIC_AUTH_TOKEN`
    /// and ignore the user's own settings.json routing; the token is never refreshed for MyClip, so it expires into 401s.
    public static let inheritedAgentPrefixes = ["CLAUDE", "ANTHROPIC_"]

    /// MyClip's own environment with any hosting agent session's variables removed, so the agent MyClip launches
    /// authenticates exactly like the user's terminal would.
    public static func launchEnvironment(inheriting base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.filter { key, _ in !inheritedAgentPrefixes.contains { key.hasPrefix($0) } }
    }
}

public struct ACPAuthMethod: Sendable, Identifiable {
    public let id: String
    public let name: String
}

public struct ACPHandshake: Sendable {
    public let supportsImages: Bool
    public let authMethods: [ACPAuthMethod]
}

public struct ACPPermissionOption: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
}

public struct ACPPermissionRequest: Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let title: String
    public let options: [ACPPermissionOption]
}

public enum ACPEvent: Sendable {
    case message(sessionID: String, text: String)
    case thinking(sessionID: String)
    case tool(sessionID: String, title: String, status: String)
    case permission(ACPPermissionRequest)
    case permissionResolved(String)
    case disconnected(String)
}

public struct ACPCompletion: Sendable {
    public let text: String
    public let stopReason: String
    public let usage: TokenUsage?
    public let cost: ExecutionCost?
}

public struct ACPConversation: Sendable {
    public enum Origin: Sendable { case created, reused, restored, replaced }
    public let id: String
    public let origin: Origin
}

private struct ACPConversationRecord: Codable {
    let id: String
    let directory: String
}

private struct ACPExecutionState {
    let onUpdate: (@Sendable (ACPExecutionUpdate) async throws -> Void)?
    let costBaseline: ExecutionCost?
    let startsAtZero: Bool
    var reportedCost = false
    var cost: ExecutionCost?
    var tools: [String: ACPToolCall] = [:]
}

public enum ACPError: Error, LocalizedError, Sendable {
    case disconnected(String)
    case protocolError(String)
    case unsupportedImages
    case timeout
    case remote(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .disconnected(let message): String(localized: "Agent 连接已关闭。\(message)")
        case .protocolError(let message): String(localized: "Agent 通信错误：\(message)")
        case .unsupportedImages: String(localized: "此 Agent 未提供截图处理能力。")
        case .timeout: String(localized: "Agent 响应超时，可以重试。")
        case .remote(_, let message):
            if message.localizedCaseInsensitiveContains("connection refused") {
                String(localized: "无法连接 Agent 服务或代理，请检查 Claude Code / Codex 的网络配置。\n\(message)")
            } else if message.contains("model_not_found") || message.contains("No available channel for model") {
                String(localized: "当前配置的模型不可用，请检查 Claude Code / Codex 的模型和登录配置。\n\(message)")
            } else { message }
        }
    }
}

private enum JSONValue: Codable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Int), decimal(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int.self) { self = .number(value) }
        else if let value = try? c.decode(Double.self) { self = .decimal(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .decimal(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue {
        if case .object(let object) = self { return object[key] ?? .null }
        return .null
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var integer: Int? { if case .number(let value) = self { return value }; return nil }
    var boolean: Bool { if case .bool(let value) = self { return value }; return false }
    var array: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    var key: String? { string ?? integer.map(String.init) }
    var formatted: String? {
        if case .null = self { return nil }
        if let string { return string }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    var cost: ExecutionCost? {
        let amount: Decimal?
        switch self["amount"] {
        case .number(let value): amount = Decimal(value)
        case .decimal(let value): amount = value.isFinite ? Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) : nil
        default: amount = nil
        }
        guard let amount, amount >= 0, let currency = self["currency"].string,
              currency.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return ExecutionCost(amount: amount, currency: currency)
    }
}

public actor ACPClient {
    public nonisolated let events: AsyncStream<ACPEvent>
    private let eventContinuation: AsyncStream<ACPEvent>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var reader: Task<Void, Never>?
    private var errorReader: Task<Void, Never>?
    private var buffer = Data()
    private var diagnostics = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var permissions: [String: (wireID: JSONValue, request: ACPPermissionRequest)] = [:]
    private var fullAccessSessions: Set<String> = []
    private var cancelledPrompts: Set<String> = []
    private var responses: [String: String] = [:]
    private var executions: [String: ACPExecutionState] = [:]
    private var sessionCosts: [String: ExecutionCost] = [:]
    private var freshCostSessions: Set<String> = []
    private var lastPromptActivity: [String: ContinuousClock.Instant] = [:]
    private var supportsImages = false
    private var supportsSessionLoading = false
    private var supportsSessionResume = false
    private var conversations: [URL: ACPConversationRecord] = [:]
    private var closed = false
    private let promptIdleTimeout: Duration
    private let promptMaximumDuration: Duration
    /// Per-prompt ceilings that replace `promptMaximumDuration`, for turns known to run long.
    private var promptLimits: [String: Duration] = [:]

    /// A prompt fails after this long without any update from the agent, or once it runs past the maximum.
    /// Tool-heavy turns over a large vault regularly take more than a quarter of an hour.
    public static let promptIdleSeconds = 600
    public static let promptMaximumSeconds = 1800

    public init(promptIdleTimeout: Duration = .seconds(promptIdleSeconds), promptMaximumDuration: Duration = .seconds(promptMaximumSeconds)) {
        self.promptIdleTimeout = promptIdleTimeout
        self.promptMaximumDuration = promptMaximumDuration
        let stream = AsyncStream<ACPEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
    }

    public func connect(command: ACPCommand) async throws -> ACPHandshake {
        guard process == nil, !closed else { throw ACPError.protocolError(String(localized: "连接已启动。")) }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = command.executable
        child.arguments = command.arguments
        child.environment = ACPCommand.launchEnvironment().merging(command.environment) { _, new in new }
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errorOutput = stderr.fileHandleForReading
        let chunks = Self.chunks(from: stdout.fileHandleForReading)
        let errors = Self.chunks(from: stderr.fileHandleForReading)
        reader = Task { [weak self] in
            for await chunk in chunks { await self?.receive(chunk) }
            await self?.disconnect(String(localized: "进程已退出。"))
        }
        errorReader = Task { [weak self] in
            for await chunk in errors { await self?.receiveDiagnostics(chunk) }
        }
        do { try child.run() }
        catch {
            close()
            throw ACPError.disconnected(error.localizedDescription)
        }
        process = child
        let result = try await request("initialize", params: .object([
            "protocolVersion": .number(1),
            "clientCapabilities": .object([:]),
            "clientInfo": .object(["name": .string("myclip"), "title": .string("MyClip"), "version": .string("1.0.0")])
        ]))
        guard result["protocolVersion"].integer == 1 else {
            close()
            throw ACPError.protocolError(String(localized: "此 ACP 版本不受支持。"))
        }
        supportsImages = result["agentCapabilities"]["promptCapabilities"]["image"].boolean
        supportsSessionLoading = result["agentCapabilities"]["loadSession"].boolean
        if case .object = result["agentCapabilities"]["sessionCapabilities"]["resume"] { supportsSessionResume = true }
        return ACPHandshake(supportsImages: supportsImages, authMethods: result["authMethods"].array.compactMap {
            guard let id = $0["id"].string, let name = $0["name"].string else { return nil }
            return ACPAuthMethod(id: id, name: name)
        })
    }

    public func newSession(directory: URL, memoryServer: ACPCommand? = nil, ephemeralFor agent: ClipAgent? = nil) async throws -> String {
        var parameters = sessionParameters(directory: directory, memoryServer: memoryServer)
        if agent == .claude {
            parameters["_meta"] = .object(["claudeCode": .object(["options": .object(["persistSession": .bool(false)])])])
        }
        // Codex persistence is enforced by EphemeralCodexCommand at the app-server boundary.
        let result = try await request("session/new", params: .object(parameters))
        guard let id = result["sessionId"].string, !id.isEmpty else {
            throw ACPError.protocolError(String(localized: "缺少会话标识。"))
        }
        freshCostSessions.insert(id)
        return id
    }

    private func sessionParameters(directory: URL, memoryServer: ACPCommand?) -> [String: JSONValue] {
        let servers: [JSONValue] = memoryServer.map { command in
            [.object(["name": .string("myclip"), "command": .string(command.executable.path),
                      "args": .array(command.arguments.map(JSONValue.string)),
                      "env": .array(command.environment.map { .object(["name": .string($0.key), "value": .string($0.value)]) })])]
        } ?? []
        return ["cwd": .string(directory.path), "mcpServers": .array(servers)]
    }

    public func conversation(directory: URL, memoryServer: ACPCommand? = nil, stateFile: URL) async throws -> ACPConversation {
        guard !closed, process?.isRunning == true else { throw ACPError.disconnected("") }
        let path = directory.standardizedFileURL.path
        if let active = conversations[stateFile], active.directory == path {
            return ACPConversation(id: active.id, origin: .reused)
        }
        let hadSavedSession = FileManager.default.fileExists(atPath: stateFile.path)
        let saved = try? JSONDecoder().decode(ACPConversationRecord.self, from: Data(contentsOf: stateFile))
        if let saved, !saved.id.isEmpty, saved.directory == path, supportsSessionResume || supportsSessionLoading {
            var params = sessionParameters(directory: directory, memoryServer: memoryServer)
            params["sessionId"] = .string(saved.id)
            do {
                _ = try await request(supportsSessionResume ? "session/resume" : "session/load", params: .object(params), timeout: .seconds(60))
                conversations[stateFile] = saved
                return ACPConversation(id: saved.id, origin: .restored)
            } catch ACPError.remote(let code, _) where [-32601, -32602, -32002].contains(code) {
                // Missing sessions or unsupported restore methods may start fresh. Authentication and transport errors must preserve the saved conversation.
            }
        }
        let id = try await newSession(directory: directory, memoryServer: memoryServer)
        let record = ACPConversationRecord(id: id, directory: path)
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: stateFile, options: .atomic)
        conversations[stateFile] = record
        return ACPConversation(id: id, origin: hadSavedSession ? .replaced : .created)
    }

    public func authenticate(methodID: String) async throws {
        _ = try await request("authenticate", params: .object(["methodId": .string(methodID)]), timeout: .seconds(180))
    }

    public func setMode(sessionID: String, modeID: String) async throws {
        _ = try await request("session/set_mode", params: .object(["sessionId": .string(sessionID), "modeId": .string(modeID)]))
        if ClipAgent.allCases.contains(where: { $0.fullAccessModeID == modeID }) { fullAccessSessions.insert(sessionID) }
        else { fullAccessSessions.remove(sessionID) }
    }

    public func prompt(sessionID: String, text: String, images: [Data], maximumDuration: Duration? = nil,
                       onUpdate: (@Sendable (ACPExecutionUpdate) async throws -> Void)? = nil) async throws -> ACPCompletion {
        guard images.isEmpty || supportsImages else { throw ACPError.unsupportedImages }
        guard responses[sessionID] == nil else { throw ACPError.protocolError(String(localized: "此会话正在整理。")) }
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        blocks += images.map { .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string($0.base64EncodedString())]) }
        responses[sessionID] = ""
        cancelledPrompts.remove(sessionID)
        let fresh = freshCostSessions.remove(sessionID) != nil
        executions[sessionID] = ACPExecutionState(onUpdate: onUpdate, costBaseline: sessionCosts[sessionID],
            startsAtZero: fresh && sessionCosts[sessionID] == nil)
        lastPromptActivity[sessionID] = .now
        promptLimits[sessionID] = maximumDuration
        defer {
            promptLimits.removeValue(forKey: sessionID)
            responses.removeValue(forKey: sessionID)
            cancelledPrompts.remove(sessionID)
            if executions.removeValue(forKey: sessionID)?.reportedCost != true { sessionCosts.removeValue(forKey: sessionID) }
            lastPromptActivity.removeValue(forKey: sessionID)
        }
        let result = try await request("session/prompt", params: .object([
            "sessionId": .string(sessionID), "prompt": .array(blocks)
        ]), timeout: promptIdleTimeout)
        guard let stopReason = result["stopReason"].string else { throw ACPError.protocolError(String(localized: "缺少结束状态。")) }
        return ACPCompletion(text: responses[sessionID] ?? "", stopReason: stopReason, usage: Self.tokenUsage(result), cost: executions[sessionID]?.cost)
    }

    private static func tokenUsage(_ result: JSONValue) -> TokenUsage? {
        func decode(_ value: JSONValue, quota: Bool = false) -> TokenUsage? {
            guard let total = value["totalTokens"].integer, total >= 0,
                  let input = value["inputTokens"].integer, input >= 0,
                  let output = value["outputTokens"].integer, output >= 0 else { return nil }
            func optional(_ key: String) -> Int? { value[key].integer.flatMap { $0 >= 0 ? $0 : nil } }
            return TokenUsage(totalTokens: total, inputTokens: input, outputTokens: output,
                cachedReadTokens: optional(quota ? "cachedInputTokens" : "cachedReadTokens"),
                cachedWriteTokens: optional("cachedWriteTokens"),
                thoughtTokens: optional(quota ? "reasoningOutputTokens" : "thoughtTokens"))
        }
        // Claude's model totals include subagents. They replace, rather than add to, the main-loop usage.
        let models = result["_meta"]["quota"]["model_usage"].array
        let usages = models.compactMap { decode($0["token_count"], quota: true) }
        if !models.isEmpty, usages.count == models.count {
            func sum(_ key: KeyPath<TokenUsage, Int?>) -> Int? {
                let values = usages.compactMap { $0[keyPath: key] }
                return values.isEmpty ? nil : values.reduce(0, +)
            }
            return TokenUsage(totalTokens: usages.reduce(0) { $0 + $1.totalTokens },
                inputTokens: usages.reduce(0) { $0 + $1.inputTokens },
                outputTokens: usages.reduce(0) { $0 + $1.outputTokens },
                cachedReadTokens: sum(\.cachedReadTokens), cachedWriteTokens: sum(\.cachedWriteTokens),
                thoughtTokens: sum(\.thoughtTokens))
        }
        return decode(result["usage"]) ?? decode(result["_meta"]["quota"]["token_count"], quota: true)
    }

    public func respondToPermission(id: String, optionID: String?) throws {
        guard let permission = permissions[id] else { return }
        if let optionID, !permission.request.options.contains(where: { $0.id == optionID }) {
            throw ACPError.protocolError(String(localized: "无效的权限选项。"))
        }
        let outcome: JSONValue = optionID.map {
            .object(["outcome": .string("selected"), "optionId": .string($0)])
        } ?? .object(["outcome": .string("cancelled")])
        try send(.object(["jsonrpc": .string("2.0"), "id": permission.wireID,
                          "result": .object(["outcome": outcome])]))
        permissions.removeValue(forKey: id)
        recordPromptActivity(permission.request.sessionID)
        eventContinuation.yield(.permissionResolved(id))
    }

    public func cancel(sessionID: String) throws {
        cancelledPrompts.insert(sessionID)
        for permission in permissions.values.filter({ $0.request.sessionID == sessionID }) {
            try respondToPermission(id: permission.request.id, optionID: nil)
        }
        try send(.object(["jsonrpc": .string("2.0"), "method": .string("session/cancel"),
                          "params": .object(["sessionId": .string(sessionID)])]))
    }

    public func close() {
        guard !closed else { return }
        closed = true
        if let process, process.isRunning { process.terminate() }
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        try? errorOutput?.close()
        reader?.cancel()
        errorReader?.cancel()
        failPending(ACPError.disconnected(""))
        permissions.removeAll()
        fullAccessSessions.removeAll()
        cancelledPrompts.removeAll()
        eventContinuation.finish()
    }

    public func cancelAndClose(sessionID: String?) async {
        if let sessionID {
            try? cancel(sessionID: sessionID)
            // Give the agent a bounded chance to report tokens already spent before terminating it.
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while responses[sessionID] != nil, ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { break }
            }
        }
        close()
    }

    private static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else { continuation.yield(data) }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// Handshake and session calls: an agent adapter that is still starting (node, first login check) can take a while.
    private func request(_ method: String, params: JSONValue, timeout: Duration = .seconds(60)) async throws -> JSONValue {
        guard !closed, process?.isRunning == true else { throw ACPError.disconnected("") }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send(.object(["jsonrpc": .string("2.0"), "id": .number(id),
                                      "method": .string(method), "params": params]))
                    let session = method == "session/prompt" ? params["sessionId"].string : nil
                    timeouts[id] = Task { [weak self] in
                        await self?.watchTimeout(id, sessionID: session, timeout: timeout)
                    }
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: { Task { await self.expireRequest(id) } }
    }

    private func watchTimeout(_ id: Int, sessionID: String?, timeout: Duration) async {
        let clock = ContinuousClock(), started = ContinuousClock.now
        let limit = started.advanced(by: sessionID.map { promptLimits[$0] ?? promptMaximumDuration } ?? timeout)
        while pending[id] != nil {
            let activity = sessionID.flatMap { lastPromptActivity[$0] } ?? started
            let deadline = min(limit, activity.advanced(by: timeout))
            guard clock.now < deadline else { expireRequest(id); return }
            do { try await clock.sleep(until: deadline) }
            catch { return }
        }
    }

    private func recordPromptActivity(_ sessionID: String) {
        if lastPromptActivity[sessionID] != nil { lastPromptActivity[sessionID] = .now }
    }

    private func send(_ message: JSONValue) throws {
        guard !closed, let input else { throw ACPError.disconnected("") }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) async {
        guard !closed else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            if line.count > 16 * 1024 * 1024 { disconnect(String(localized: "消息超过大小限制。")); return }
            do { try await handle(JSONDecoder().decode(JSONValue.self, from: line)) }
            catch { disconnect(error.localizedDescription); return }
        }
        if buffer.count > 16 * 1024 * 1024 { disconnect(String(localized: "消息超过大小限制。")) }
    }

    private func handle(_ message: JSONValue) async throws {
        guard message["jsonrpc"].string == "2.0" else { throw ACPError.protocolError(String(localized: "无效的 JSON-RPC 消息。")) }
        if let method = message["method"].string {
            let params = message["params"]
            if method == "session/update", let session = params["sessionId"].string {
                let update = params["update"]
                switch update["sessionUpdate"].string {
                case "agent_thought_chunk":
                    if responses[session] != nil, let text = update["content"]["text"].string, !text.isEmpty {
                        recordPromptActivity(session)
                        eventContinuation.yield(.thinking(sessionID: session))
                    }
                case "agent_message_chunk":
                    if update["content"]["type"].string == "text", let text = update["content"]["text"].string,
                       !text.isEmpty, responses[session] != nil {
                        guard (responses[session]?.utf8.count ?? 0) + text.utf8.count < 2 * 1024 * 1024 else {
                            throw ACPError.protocolError(String(localized: "整理结果过长。"))
                        }
                        responses[session, default: ""] += text
                        recordPromptActivity(session)
                        eventContinuation.yield(.message(sessionID: session, text: text))
                    }
                case "tool_call", "tool_call_update":
                    guard responses[session] != nil else { break }
                    recordPromptActivity(session)
                    if let tool = try await recordTool(update, session: session) {
                        eventContinuation.yield(.tool(sessionID: session, title: tool.title, status: tool.status))
                    } else {
                        eventContinuation.yield(.tool(sessionID: session, title: update["title"].string ?? String(localized: "正在整理"),
                                                      status: update["status"].string ?? "in_progress"))
                    }
                case "usage_update":
                    if let cost = update["cost"].cost {
                        sessionCosts[session] = cost
                        if let execution = executions[session] {
                            var delta: ExecutionCost?
                            if execution.startsAtZero { delta = cost }
                            else if let baseline = execution.costBaseline, baseline.currency == cost.currency,
                                    cost.amount >= baseline.amount {
                                delta = ExecutionCost(amount: cost.amount - baseline.amount, currency: cost.currency)
                            }
                            executions[session]?.reportedCost = true
                            executions[session]?.cost = delta
                            try await execution.onUpdate?(.cost(delta))
                        }
                    }
                default: break
                }
            } else if method == "session/request_permission", let key = message["id"].key {
                let request = ACPPermissionRequest(id: key, sessionID: params["sessionId"].string ?? "",
                    title: params["toolCall"]["title"].string ?? String(localized: "Agent 请求权限"), options: params["options"].array.compactMap {
                        guard let id = $0["optionId"].string else { return nil }
                        return ACPPermissionOption(id: id, name: $0["name"].string ?? id, kind: $0["kind"].string ?? "")
                    })
                permissions[key] = (message["id"], request)
                if responses[request.sessionID] != nil { _ = try await recordTool(params["toolCall"], session: request.sessionID) }
                recordPromptActivity(request.sessionID)
                if fullAccessSessions.contains(request.sessionID) {
                    // Full access applies to this session; prefer allowing once over saving extra rules.
                    let option = request.options.first { $0.kind == "allow_once" }
                        ?? request.options.first { $0.kind == "allow_always" }
                    let active = responses[request.sessionID] != nil && !cancelledPrompts.contains(request.sessionID)
                    try respondToPermission(id: key, optionID: active ? option?.id : nil)
                } else { eventContinuation.yield(.permission(request)) }
            } else if message["id"].key != nil {
                try send(.object(["jsonrpc": .string("2.0"), "id": message["id"],
                    "error": .object(["code": .number(-32601), "message": .string("Method not supported")])]))
            }
        } else if let id = message["id"].integer, let continuation = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let code = message["error"]["code"].integer {
                continuation.resume(throwing: ACPError.remote(code: code, message: message["error"]["message"].string ?? String(localized: "Agent 返回错误。")))
            } else { continuation.resume(returning: message["result"]) }
        }
    }

    private func recordTool(_ update: JSONValue, session: String) async throws -> ACPToolCall? {
        guard let id = update["toolCallId"].string, !id.isEmpty else { return nil }
        var tool = executions[session]?.tools[id] ?? ACPToolCall(id: id, title: String(localized: "工具调用"), startedAt: .now, updatedAt: .now)
        if let title = update["title"].string { tool.title = title }
        if let name = update["name"].string { tool.name = name }
        if let kind = update["kind"].string { tool.kind = kind }
        if let status = update["status"].string { tool.status = status }
        if let input = update["rawInput"].formatted { tool.rawInput = input }
        if let output = update["rawOutput"].formatted { tool.rawOutput = output }
        if case .array(let locations) = update["locations"] {
            tool.locations = locations.compactMap { location in
                guard let path = location["path"].string else { return nil }
                return ACPToolLocation(path: path, line: location["line"].integer)
            }
        }
        if case .array(let content) = update["content"] {
            tool.content = content.map { item in
                switch item["type"].string {
                case "diff":
                    ACPToolContent(type: "diff", path: item["path"].string,
                        oldText: item["oldText"].string, newText: item["newText"].string)
                case "content":
                    ACPToolContent(type: "text", text: item["content"]["text"].string
                        ?? item["content"]["resource"]["text"].string ?? String(localized: "非文本结果（\(item["content"]["type"].string ?? String(localized: "未知类型"))）"))
                case "terminal": ACPToolContent(type: "terminal", text: String(localized: "终端：\(item["terminalId"].string ?? String(localized: "未回传标识"))"))
                default: ACPToolContent(type: "text", text: item.formatted)
                }
            }
        }
        tool.updatedAt = .now
        executions[session]?.tools[id] = tool
        try await executions[session]?.onUpdate?(.tool(tool))
        return tool
    }

    private func receiveDiagnostics(_ data: Data) {
        diagnostics.append(data)
        if diagnostics.count > 4096 { diagnostics = diagnostics.suffix(4096) }
    }

    private func expireRequest(_ id: Int) {
        guard pending[id] != nil else { return }
        // A timed-out prompt may still be running remotely; close it before another job can start.
        pending.removeValue(forKey: id)?.resume(throwing: ACPError.timeout)
        timeouts.removeValue(forKey: id)?.cancel()
        disconnect(String(localized: "响应超时。"))
    }

    private func disconnect(_ message: String) {
        guard !closed else { return }
        failPending(ACPError.disconnected(message))
        eventContinuation.yield(.disconnected(message))
        close()
    }

    private func failPending(_ error: any Error) {
        let continuations = Array(pending.values)
        pending.removeAll()
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }
}
