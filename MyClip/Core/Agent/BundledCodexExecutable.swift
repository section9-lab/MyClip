import Foundation

/// Share desktop-package discovery between organization and MCP setup.
public enum BundledCodexExecutable {
    public static func find(in application: URL) -> URL? {
        ["Contents/Resources/codex-cli/bin/codex",
         "Contents/Resources/codex",
         "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
            .map { application.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
