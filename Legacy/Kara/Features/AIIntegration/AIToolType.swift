import Foundation
import AppKit

/// Supported AI tools that can receive transcribed text.
enum AIToolType: String, Identifiable, Codable {
    case claudeDesktop = "claude-desktop"
    case codexDesktop  = "codex-desktop"
    case hermesDesktop = "hermes-desktop"
    case claudeCLI     = "claude-cli"
    case codexCLI      = "codex-cli"
    case hermesCLI     = "hermes-cli"

    static var allCases: [AIToolType] {
        [.claudeCLI, .codexCLI, .hermesCLI]
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeDesktop: return "Claude CLI"
        case .codexDesktop: return "Codex CLI"
        case .hermesDesktop: return "Hermes CLI"
        case .claudeCLI: return "Claude CLI"
        case .codexCLI: return "Codex CLI"
        case .hermesCLI: return "Hermes CLI"
        }
    }

    var iconSystemName: String {
        switch baseTool {
        case .claudeCLI: return "brain"
        case .codexCLI: return "terminal"
        case .hermesCLI: return "bolt.circle"
        case .claudeDesktop, .codexDesktop, .hermesDesktop: return "terminal"
        }
    }

    /// The macOS bundle identifier used to locate desktop apps.
    var bundleIdentifier: String {
        switch baseTool {
        case .claudeDesktop: return "com.anthropic.claudefordesktop"
        case .codexDesktop: return "com.openai.codex"
        case .hermesDesktop: return "com.nousresearch.hermes"
        case .claudeCLI, .codexCLI, .hermesCLI: return ""
        }
    }

    /// The process name visible to System Events for UI automation.
    var processName: String {
        switch baseTool {
        case .claudeDesktop: return "Claude"
        case .codexDesktop: return "Codex"
        case .hermesDesktop: return "Hermes"
        case .claudeCLI, .codexCLI, .hermesCLI: return ""
        }
    }

    /// Check whether this tool appears to be installed on the system.
    var isInstalled: Bool {
        isCLIInstalled
    }

    var canSendMessages: Bool {
        isCommandLine && isCLIInstalled
    }

    var unavailableSendReason: String {
        if isCommandLine {
            return "Not Installed"
        }

        return "Not Installed"
    }

    var isDesktopInstalled: Bool {
        guard !isCommandLine else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    var cliExecutableURL: URL? {
        guard isCommandLine else { return nil }

        switch baseTool {
        case .claudeCLI:
            return executableURL(named: "claude")
        case .codexCLI:
            let bundledURL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
            if FileManager.default.isExecutableFile(atPath: bundledURL.path) {
                return bundledURL
            }
            return executableURL(named: "codex")
        case .hermesCLI:
            return executableURL(named: "hermes")
        case .claudeDesktop, .codexDesktop, .hermesDesktop:
            return nil
        }
    }

    var isCLIInstalled: Bool {
        cliExecutableURL != nil
    }

    private func executableURL(named name: String) -> URL? {
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
        ]

        for path in searchPaths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    var isCommandLine: Bool {
        switch self {
        case .claudeCLI, .codexCLI, .hermesCLI:
            return true
        case .claudeDesktop, .codexDesktop, .hermesDesktop:
            return false
        }
    }

    var baseTool: AIToolType {
        switch self {
        case .claudeDesktop, .claudeCLI:
            return .claudeCLI
        case .codexDesktop, .codexCLI:
            return .codexCLI
        case .hermesDesktop, .hermesCLI:
            return .hermesCLI
        }
    }

    var endpointDetail: String {
        if isCommandLine {
            return cliExecutableURL?.path ?? "CLI Not Found"
        }
        return bundleIdentifier
    }
}

extension AIToolType {
    var compactDisplayName: String {
        switch baseTool {
        case .claudeCLI: return "Claude"
        case .codexCLI: return "Codex"
        case .hermesCLI: return "Hermes"
        case .claudeDesktop, .codexDesktop, .hermesDesktop: return ""
        }
    }

    var brandIcon: NSImage? {
        AgentIconAssets.icon(for: self)
    }
}

private enum AgentIconAssets {
    static func icon(for tool: AIToolType) -> NSImage? {
        switch tool {
        case .claudeDesktop, .claudeCLI:
            return NSImage(named: "ClaudeIcon")
        case .codexDesktop, .codexCLI:
            return NSImage(named: "CodexIcon")
        case .hermesDesktop, .hermesCLI:
            return image(fromFileAt: "/Users/jackwang/Downloads/hermesagent.svg")
        }
    }

    private static func image(fromFileAt path: String, removingWhiteBackground: Bool = false) -> NSImage? {
        let url = URL(fileURLWithPath: path)

        guard url.pathExtension.lowercased() == "svg" else {
            let image = NSImage(contentsOf: url)
            image?.isTemplate = false
            return image
        }

        guard var svg = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            return nil
        }

        if removingWhiteBackground {
            svg = svg.replacingOccurrences(
                of: ##"<path\b[^>]*fill="#fff"[^>]*></path>"##,
                with: "",
                options: .regularExpression
            )
        }

        guard let data = svg.data(using: .utf8),
              let image = NSImage(data: data)
        else {
            return nil
        }
        image.isTemplate = false
        return image
    }
}
