import Foundation

public struct ClipAgentSession: Sendable {
    public let agent: ClipAgent
    public let id: String
    public let directory: URL

    public init?(agent: ClipAgent, id: String, directory: URL) {
        guard UUID(uuidString: id) != nil else { return nil }
        self.agent = agent
        self.id = id
        self.directory = directory
    }

    public var appURL: URL? {
        agent == .codex ? URL(string: "codex://threads/\(id)") : nil
    }

    public func terminalScript(command: ACPCommand) -> String {
        let arguments: [String]
        switch agent {
        case .codex: arguments = ["resume", id]
        case .claude: arguments = ["--cli", "--resume", id]
        case .opencode: arguments = ["--session", id]
        case .cursor: arguments = ["--resume", id]
        }
        let environment = command.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let invocation = (["/usr/bin/env"] + environment + [command.executable.path] + command.arguments + arguments)
            .map(Self.shellQuote).joined(separator: " ")
        return "#!/bin/sh\ncd \(Self.shellQuote(directory.path)) || exit 1\nexec \(invocation)\n"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
