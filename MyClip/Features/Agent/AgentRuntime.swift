import AppKit
import MyClipCore

enum LocalAgentAvailability {
    case connector, commandLine, desktopConnector, desktopEngine, accountSetup, desktopOnly, missing

    var hasConnector: Bool { self == .connector || self == .desktopConnector }
    var canSelect: Bool { hasConnector || self == .commandLine || self == .desktopEngine || self == .accountSetup }
    var detail: String {
        switch self {
        case .connector: String(localized: "连接组件已安装")
        case .commandLine: String(localized: "已检测到 · 需安装连接组件")
        case .desktopConnector: String(localized: "桌面应用内置引擎可用")
        case .desktopEngine: String(localized: "已检测到桌面引擎 · 将自动准备连接组件")
        case .accountSetup: String(localized: "连接账号后即可使用")
        case .desktopOnly: String(localized: "已检测到桌面端 · 自动整理接口待接入")
        case .missing: String(localized: "未检测到")
        }
    }
}

struct AgentRuntime {
    let root: URL
    var searchPaths: [String]? = nil
    var desktopApplications: [ClipAgent: URL]? = nil
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    var componentManifest: ManagedRuntimeManifest? = nil

    var binDirectory: URL { root.appendingPathComponent("node_modules/.bin") }

    var environment: [String: String] {
        var seen = Set<String>()
        let paths = ([binDirectory.path] + (searchPaths ?? defaultSearchPaths))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        // The session's library must take precedence over a globally registered myclip server.
        return ["PATH": paths.joined(separator: ":"), "INITIAL_AGENT_MODE": "agent-full-access", "DISABLE_MCP_CONFIG_FILTERING": "true"]
    }

    private var defaultSearchPaths: [String] {
        let home = homeDirectory.path
        let inheritedPaths = (inheritedEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
        let userPaths = ["\(home)/.local/bin", "\(home)/.opencode/bin", "\(home)/.codebuddy/bin", "\(home)/.qwenwork/bin"]
        let systemPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let nvmDirectory = inheritedEnvironment["NVM_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(".nvm")
        // Finder launches do not inherit nvm's shell PATH. Scan its installed versions without running shell startup scripts.
        let versions = (try? FileManager.default.contentsOfDirectory(at: nvmDirectory.appendingPathComponent("versions/node"),
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let nvmPaths = versions.filter { $0.lastPathComponent.hasPrefix("v") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin").path }
        return inheritedPaths + userPaths + nvmPaths + systemPaths
    }

    private func desktopApplication(for agent: ClipAgent) -> URL? {
        if let desktopApplications { return desktopApplications[agent] }
        let bundleID: String
        switch agent {
        case .codex: bundleID = "com.openai.codex"
        case .claude: bundleID = "com.anthropic.claudefordesktop"
        case .cursor: bundleID = "com.todesktop.230313mzl4w4u92"
        case .workbuddy: bundleID = "com.tencent.workbuddy.mac"
        case .qwenwork: bundleID = "cn.qwenwork.desktop.mac"
        case .opencode: return nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func cliExecutable(for agent: ClipAgent, customPath: String) -> URL? {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        if !customPath.isEmpty { directories.insert(URL(fileURLWithPath: customPath).deletingLastPathComponent(), at: 0) }
        var candidates = directories.map { $0.appendingPathComponent(agent.cliName) }
        if agent == .codex, let app = desktopApplication(for: agent), let executable = BundledCodexExecutable.find(in: app) {
            // The ACP package also installs a Codex dependency. It must not shadow
            // the desktop engine discovered before preparing that connector.
            if customPath.isEmpty {
                candidates.removeAll { $0.deletingLastPathComponent().standardizedFileURL == binDirectory.standardizedFileURL }
            }
            candidates.append(executable)
            candidates.append(binDirectory.appendingPathComponent(agent.cliName))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func availability(of agent: ClipAgent, customPath: String) -> LocalAgentAvailability {
        if let command = command(for: agent, customPath: customPath) {
            if !customPath.isEmpty { return .connector }
            let executable = agent == .codex ? cliExecutable(for: agent, customPath: customPath) ?? command.executable : command.executable
            return usesDesktopBundle(executable, agent: agent) ? .desktopConnector : .connector
        }
        if !customPath.isEmpty { return .missing }
        if agent == .workbuddy || agent == .qwenwork {
            return .accountSetup
        }
        if let executable = cliExecutable(for: agent, customPath: customPath) {
            return usesDesktopBundle(executable, agent: agent) ? .desktopEngine : .commandLine
        }
        return desktopApplication(for: agent) == nil ? .missing : .desktopOnly
    }

    func command(for agent: ClipAgent, customPath: String) -> ACPCommand? {
        if customPath.isEmpty, agent == .workbuddy || agent == .qwenwork {
            return accountCommand(for: agent)
        }
        let locations = customPath.isEmpty
            ? (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(agent.executableName) }
            : [URL(fileURLWithPath: customPath)]
        guard let executable = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        return ACPCommand(executable: executable, arguments: agent.acpArguments, environment: environment)
    }

    /// Account connections always use MyClip-managed components, regardless of
    /// the user's shell, installed desktop applications, or personal Agent config.
    private func accountCommand(for agent: ClipAgent) -> ACPCommand? {
        guard agent == .workbuddy || agent == .qwenwork,
              let manifest = componentManifest ?? (try? ManagedRuntimeManifest.load()),
              let directory = ManagedAgentRuntime.readyDirectory(root: root, manifest: manifest) else { return nil }
        var env = environment
        env["PATH"] = directory.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        if let app = desktopApplication(for: agent), let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String {
            env["MYCLIP_PRODUCT_VERSION"] = version
        }
        let engine = ACPCommand(executable: directory.appendingPathComponent("opencode"), arguments: ["acp"], environment: env)
        return SubscriptionAgentCommand.make(provider: agent, node: directory.appendingPathComponent("node"), engine: engine, runtimeRoot: root)
    }

    func usesAccountBridge(_ agent: ClipAgent, customPath: String) -> Bool {
        customPath.isEmpty && (agent == .workbuddy || agent == .qwenwork)
    }

    private func usesDesktopBundle(_ executable: URL, agent: ClipAgent) -> Bool {
        guard let app = desktopApplication(for: agent) else { return false }
        return executable.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/")
    }

    func sessionCommand(for agent: ClipAgent, customPath: String) -> ACPCommand? {
        if agent == .claude { return command(for: agent, customPath: customPath) }
        guard let executable = cliExecutable(for: agent, customPath: customPath) else { return nil }
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
        if agent == .workbuddy || agent == .qwenwork {
            let manifest = try componentManifest ?? ManagedRuntimeManifest.load()
            _ = try await ManagedAgentRuntime(root: root, manifest: manifest).prepare()
            return
        }
        guard let package = agent.package else {
            throw LibraryError.invalidResult(String(localized: "\(agent.name) 自带 ACP 支持，无需连接组件；请先安装 \(agent.cliName) 命令行。"))
        }
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
            process.arguments = ["npm", "install", "--prefix", root.path, "--save-exact", "--no-audit", "--no-fund", package]
            process.environment = ACPCommand.launchEnvironment().merging(env) { _, new in new }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw LibraryError.invalidResult(String(localized: "连接组件安装失败。请安装 Node.js 22 或更新版本，并查看 Runtime/install.log。"))
            }
        }.value
    }
}
