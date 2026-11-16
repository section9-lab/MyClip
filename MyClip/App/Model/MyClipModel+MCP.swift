import AppKit
import MyClipCore

extension MyClipModel {
    /// Installed into other clients (Claude Code, Codex, OpenCode) and read-only on purpose.
    var memoryCommand: ACPCommand {
        ACPCommand(executable: Bundle.main.executableURL!, arguments: ["--mcp", "--library", store.root.path])
    }

    /// The session MyClip runs itself: the hourly digest writes the board and the calendar through these tools.
    var agentMemoryCommand: ACPCommand {
        ACPCommand(executable: Bundle.main.executableURL!, arguments: ["--mcp", "--library", store.root.path, "--write-tools"])
    }

    func setMCPEnabled(_ enabled: Bool) {
        do {
            try MemoryMCP.setEnabled(enabled, in: store.root)
            mcpEnabled = enabled
        } catch { notice = String(localized: "无法更改 MCP 状态：\(error.localizedDescription)") }
    }

    func configureMCP() {
        guard mcpEnabled, !configuringMCP, !preview, !preferences.mcpClients.isEmpty else { return }
        let selected = MCPClient.allCases.filter { preferences.mcpClients.contains($0) }
        let bundledCodex = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            .flatMap { BundledCodexExecutable.find(in: $0) }
        let installer = MCPClientInstaller(codexExecutable: bundledCodex)
        configuringMCP = true
        mcpSetupResults = [:]
        Task {
            defer { configuringMCP = false }
            for client in selected {
                do {
                    try await installer.install(client, command: memoryCommand)
                    mcpSetupResults[client] = .configured
                } catch { mcpSetupResults[client] = .failed(error.localizedDescription) }
            }
        }
    }
}
