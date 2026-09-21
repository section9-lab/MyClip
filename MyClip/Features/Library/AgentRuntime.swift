import Foundation
import MyClipCore

struct AgentRuntime {
    let root: URL

    var binDirectory: URL { root.appendingPathComponent("node_modules/.bin") }

    var environment: [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [binDirectory.path, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        // The session's library must take precedence over a globally registered myclip server.
        return ["PATH": paths.joined(separator: ":"), "INITIAL_AGENT_MODE": "agent-full-access", "DISABLE_MCP_CONFIG_FILTERING": "true"]
    }

    func command(for agent: ClipAgent, customPath: String) -> ACPCommand? {
        let locations = customPath.isEmpty
            ? (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(agent.executableName) }
            : [URL(fileURLWithPath: customPath)]
        guard let executable = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        return ACPCommand(executable: executable, environment: environment)
    }

    func sessionCommand(for agent: ClipAgent, customPath: String) -> ACPCommand? {
        if agent == .claude { return command(for: agent, customPath: customPath) }
        var directories = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        if !customPath.isEmpty { directories.insert(URL(fileURLWithPath: customPath).deletingLastPathComponent(), at: 0) }
        guard let executable = directories.map({ $0.appendingPathComponent("codex") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        return ACPCommand(executable: executable, environment: environment)
    }

    func organizationCommand(for agent: ClipAgent, customPath: String) throws -> ACPCommand? {
        guard let command = command(for: agent, customPath: customPath) else { return nil }
        guard agent == .codex else { return command }
        let codex = sessionCommand(for: .codex, customPath: customPath)?.executable
            ?? binDirectory.appendingPathComponent("codex")
        return try EphemeralCodexCommand.prepare(command, codexExecutable: codex, directory: root)
    }

    func install(_ agent: ClipAgent) async throws {
        let env = environment
        let root = root
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let log = root.appendingPathComponent("install.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["npm", "install", "--prefix", root.path, "--save-exact", "--no-audit", "--no-fund", agent.package]
            process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw LibraryError.invalidResult("连接组件安装失败。请安装 Node.js 22 或更新版本，并查看 Runtime/install.log。")
            }
        }.value
    }
}
