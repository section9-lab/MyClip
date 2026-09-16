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
    case tool(sessionID: String, title: String, status: String)
    case permission(ACPPermissionRequest)
    case permissionResolved(String)
    case disconnected(String)
}

public struct ACPCompletion: Sendable {
    public let text: String
    public let stopReason: String
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

public enum ACPError: Error, LocalizedError, Sendable {
    case disconnected(String)
    case protocolError(String)
    case unsupportedImages
    case timeout
    case remote(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .disconnected(let message): "Agent 连接已关闭。\(message)"
        case .protocolError(let message): "Agent 通信错误：\(message)"
        case .unsupportedImages: "此 Agent 未提供截图处理能力。"
        case .timeout: "Agent 响应超时，可以重试。"
        case .remote(_, let message): message
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
    private var responses: [String: String] = [:]
    private var supportsImages = false
    private var supportsSessionLoading = false
    private var supportsSessionResume = false
    private var conversations: [URL: ACPConversationRecord] = [:]
    private var closed = false

    public init() {
        let stream = AsyncStream<ACPEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
    }

    public func connect(command: ACPCommand) async throws -> ACPHandshake {
        guard process == nil, !closed else { throw ACPError.protocolError("连接已启动。") }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = command.executable
        child.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        environment.merge(command.environment) { _, new in new }
        child.environment = environment
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
            await self?.disconnect("进程已退出。")
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
            throw ACPError.protocolError("此 ACP 版本不受支持。")
        }
        supportsImages = result["agentCapabilities"]["promptCapabilities"]["image"].boolean
        supportsSessionLoading = result["agentCapabilities"]["loadSession"].boolean
        if case .object = result["agentCapabilities"]["sessionCapabilities"]["resume"] { supportsSessionResume = true }
        return ACPHandshake(supportsImages: supportsImages, authMethods: result["authMethods"].array.compactMap {
            guard let id = $0["id"].string, let name = $0["name"].string else { return nil }
            return ACPAuthMethod(id: id, name: name)
        })
    }

    public func newSession(directory: URL, memoryServer: ACPCommand? = nil) async throws -> String {
        let result = try await request("session/new", params: .object(sessionParameters(directory: directory, memoryServer: memoryServer)))
        guard let id = result["sessionId"].string, !id.isEmpty else {
            throw ACPError.protocolError("缺少会话标识。")
        }
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
                _ = try await request(supportsSessionResume ? "session/resume" : "session/load", params: .object(params), timeout: 60)
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
        _ = try await request("authenticate", params: .object(["methodId": .string(methodID)]), timeout: 180)
    }

    public func setMode(sessionID: String, modeID: String) async throws {
        _ = try await request("session/set_mode", params: .object(["sessionId": .string(sessionID), "modeId": .string(modeID)]))
    }

    public func prompt(sessionID: String, text: String, images: [Data]) async throws -> ACPCompletion {
        guard images.isEmpty || supportsImages else { throw ACPError.unsupportedImages }
        guard responses[sessionID] == nil else { throw ACPError.protocolError("此会话正在整理。") }
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        blocks += images.map { .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string($0.base64EncodedString())]) }
        responses[sessionID] = ""
        defer { responses.removeValue(forKey: sessionID) }
        let result = try await request("session/prompt", params: .object([
            "sessionId": .string(sessionID), "prompt": .array(blocks)
        ]), timeout: 300)
        guard let stopReason = result["stopReason"].string else { throw ACPError.protocolError("缺少结束状态。") }
        return ACPCompletion(text: responses[sessionID] ?? "", stopReason: stopReason)
    }

    public func respondToPermission(id: String, optionID: String?) throws {
        guard let permission = permissions[id] else { return }
        if let optionID, !permission.request.options.contains(where: { $0.id == optionID }) {
            throw ACPError.protocolError("无效的权限选项。")
        }
        let outcome: JSONValue = optionID.map {
            .object(["outcome": .string("selected"), "optionId": .string($0)])
        } ?? .object(["outcome": .string("cancelled")])
        try send(.object(["jsonrpc": .string("2.0"), "id": permission.wireID,
                          "result": .object(["outcome": outcome])]))
        permissions.removeValue(forKey: id)
        eventContinuation.yield(.permissionResolved(id))
    }

    public func cancel(sessionID: String) throws {
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
        eventContinuation.finish()
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

    private func request(_ method: String, params: JSONValue, timeout: Double = 30) async throws -> JSONValue {
        guard !closed, process?.isRunning == true else { throw ACPError.disconnected("") }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send(.object(["jsonrpc": .string("2.0"), "id": .number(id),
                                      "method": .string(method), "params": params]))
                    timeouts[id] = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(timeout)) }
                        catch { return }
                        await self?.expireRequest(id)
                    }
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: { Task { await self.expireRequest(id) } }
    }

    private func send(_ message: JSONValue) throws {
        guard !closed, let input else { throw ACPError.disconnected("") }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            if line.count > 16 * 1024 * 1024 { disconnect("消息超过大小限制。"); return }
            do { try handle(JSONDecoder().decode(JSONValue.self, from: line)) }
            catch { disconnect(error.localizedDescription); return }
        }
        if buffer.count > 16 * 1024 * 1024 { disconnect("消息超过大小限制。") }
    }

    private func handle(_ message: JSONValue) throws {
        guard message["jsonrpc"].string == "2.0" else { throw ACPError.protocolError("无效的 JSON-RPC 消息。") }
        if let method = message["method"].string {
            let params = message["params"]
            if method == "session/update", let session = params["sessionId"].string {
                let update = params["update"]
                switch update["sessionUpdate"].string {
                case "agent_message_chunk":
                    if update["content"]["type"].string == "text", let text = update["content"]["text"].string,
                       responses[session] != nil {
                        guard (responses[session]?.utf8.count ?? 0) + text.utf8.count < 2 * 1024 * 1024 else {
                            throw ACPError.protocolError("整理结果过长。")
                        }
                        responses[session, default: ""] += text
                        eventContinuation.yield(.message(sessionID: session, text: text))
                    }
                case "tool_call", "tool_call_update":
                    eventContinuation.yield(.tool(sessionID: session, title: update["title"].string ?? "正在整理",
                                                  status: update["status"].string ?? "in_progress"))
                default: break
                }
            } else if method == "session/request_permission", let key = message["id"].key {
                let request = ACPPermissionRequest(id: key, sessionID: params["sessionId"].string ?? "",
                    title: params["toolCall"]["title"].string ?? "Agent 请求权限", options: params["options"].array.compactMap {
                        guard let id = $0["optionId"].string else { return nil }
                        return ACPPermissionOption(id: id, name: $0["name"].string ?? id, kind: $0["kind"].string ?? "")
                    })
                permissions[key] = (message["id"], request)
                eventContinuation.yield(.permission(request))
            } else if message["id"].key != nil {
                try send(.object(["jsonrpc": .string("2.0"), "id": message["id"],
                    "error": .object(["code": .number(-32601), "message": .string("Method not supported")])]))
            }
        } else if let id = message["id"].integer, let continuation = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let code = message["error"]["code"].integer {
                continuation.resume(throwing: ACPError.remote(code: code, message: message["error"]["message"].string ?? "Agent 返回错误。"))
            } else { continuation.resume(returning: message["result"]) }
        }
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
        disconnect("响应超时。")
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
