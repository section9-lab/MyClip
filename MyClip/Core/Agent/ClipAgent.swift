import Foundation

public enum ClipAgent: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude
    case opencode
    case cursor

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        case .cursor: "Cursor"
        }
    }
    /// The program that speaks ACP on stdio. Codex and Claude need a connector; OpenCode's own CLI is the server.
    public var executableName: String {
        switch self {
        case .codex: "codex-acp"
        case .claude: "claude-agent-acp"
        case .opencode: "opencode"
        case .cursor: "cursor-agent"
        }
    }
    public var acpArguments: [String] { self == .opencode || self == .cursor ? ["acp"] : [] }
    /// The user-facing command line, used for discovery and login instructions.
    public var cliName: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .opencode: "opencode"
        case .cursor: "cursor-agent"
        }
    }
    /// npm connector to install; nil when the CLI itself speaks ACP.
    public var package: String? {
        switch self {
        case .codex: "@agentclientprotocol/codex-acp@1.12.0"
        case .claude: "@agentclientprotocol/claude-agent-acp@0.78.0"
        case .opencode, .cursor: nil
        }
    }
    /// Session mode that lets the Agent read, write and run tools without asking.
    public var fullAccessModeID: String {
        switch self {
        case .codex: "agent-full-access"
        case .claude: "bypassPermissions"
        case .opencode: "build"
        case .cursor: "agent"
        }
    }
}
