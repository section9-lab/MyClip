import Foundation

public enum MCPClient: String, CaseIterable, Identifiable, Sendable {
    case codex, claudeCode, cursor, openCode
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .openCode: "OpenCode"
        }
    }
}

public struct MCPClientInstaller: Sendable {
    let homeDirectory: URL
    let environment: [String: String]
    let codexExecutable: URL?

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment, codexExecutable: URL? = nil) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.codexExecutable = codexExecutable
    }

    public func configurationURL(for client: MCPClient) -> URL {
        switch client {
        case .codex:
            return directory("CODEX_HOME", fallback: ".codex").appendingPathComponent("config.toml")
        case .claudeCode:
            return environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") }
                ?? homeDirectory.appendingPathComponent(".claude.json")
        case .cursor:
            return homeDirectory.appendingPathComponent(".cursor/mcp.json")
        case .openCode:
            let directory = directory("XDG_CONFIG_HOME", fallback: ".config").appendingPathComponent("opencode")
            let jsonc = directory.appendingPathComponent("opencode.jsonc")
            return FileManager.default.fileExists(atPath: jsonc.path) ? jsonc : directory.appendingPathComponent("opencode.json")
        }
    }

    private func directory(_ key: String, fallback: String) -> URL {
        environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? homeDirectory.appendingPathComponent(fallback)
    }

    public func install(_ client: MCPClient, command: ACPCommand) async throws {
        try await Task.detached(priority: .utility) {
            if client == .codex { try installCodex(command) }
            else { try installJSON(client, command: command) }
        }.value
    }

    private func installJSON(_ client: MCPClient, command: ACPCommand) throws {
        let url = configurationURL(for: client).resolvingSymlinksInPath()
        let exists = FileManager.default.fileExists(atPath: url.path)
        let original = exists ? try Data(contentsOf: url) : nil
        guard var config = try original.map({ try JSONSerialization.jsonObject(with: $0, options: [.json5Allowed]) as? [String: Any] }) ?? [:] else {
            throw LibraryError.invalidResult("\(client.name) 配置必须是 JSON 对象，原文件未改动。")
        }
        let key = client == .openCode ? "mcp" : "mcpServers"
        guard var servers = config[key].map({ $0 as? [String: Any] }) ?? [:],
              var entry = servers["myclip"].map({ $0 as? [String: Any] }) ?? [:] else {
            throw LibraryError.invalidResult("\(client.name) 的 MCP 配置格式不正确，原文件未改动。")
        }
        let oldCommand = entry["command"] as? String ?? (entry["command"] as? [String])?.first
        if entry["url"] != nil || oldCommand.map({ !["MyClip", "myclip-mcp"].contains(URL(fileURLWithPath: $0).lastPathComponent) }) == true {
            throw LibraryError.invalidResult("\(client.name) 已有其他服务使用 myclip 名称，请先在客户端中重命名该服务。")
        }
        if client == .openCode {
            entry["type"] = "local"
            entry["command"] = [command.executable.path] + command.arguments
            entry["enabled"] = true
        } else {
            entry["command"] = command.executable.path
            entry["args"] = command.arguments
            if client == .claudeCode { entry["type"] = "stdio" }
            if entry["disabled"] != nil { entry["disabled"] = false }
        }
        if let existing = servers["myclip"] as? [String: Any], NSDictionary(dictionary: existing).isEqual(to: entry) { return }
        servers["myclip"] = entry
        config[key] = servers
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let original {
            guard try Data(contentsOf: url) == original else { throw LibraryError.invalidResult("配置已被其他应用更新，请重试。") }
            try backup(url)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func installCodex(_ command: ACPCommand) throws {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
            + [homeDirectory.appendingPathComponent(".local/bin/codex").path, "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
               "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"]
        guard let executable = codexExecutable ?? paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map({ URL(fileURLWithPath: $0) }) else {
            throw LibraryError.invalidResult("未找到 Codex。请先安装 Codex 应用或 CLI，再重试。")
        }
        let config = configurationURL(for: .codex)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: config.path) { try backup(config) }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["mcp", "add", "myclip", "--", command.executable.path] + command.arguments
        process.currentDirectoryURL = homeDirectory
        process.environment = environment.merging(["CODEX_HOME": config.deletingLastPathComponent().path]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LibraryError.invalidResult("Codex 配置未完成。\(detail.isEmpty ? "请检查 Codex 安装后重试。" : String(detail.prefix(600)))")
        }
    }

    private func backup(_ url: URL) throws {
        let backup = url.appendingPathExtension("myclip-backup")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: url, to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }
}
