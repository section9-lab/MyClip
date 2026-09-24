import Foundation

public enum EphemeralCodexCommand {
    public static func prepare(_ adapter: ACPCommand, codexExecutable: URL, directory: URL) throws -> ACPCommand {
        guard let resource = Bundle.module.url(forResource: "codex-ephemeral", withExtension: "cjs", subdirectory: "Resources") else {
            throw ACPError.protocolError(String(localized: "缺少 Codex 临时会话组件。"))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex-ephemeral.cjs")
        let contents = try Data(contentsOf: resource)
        if (try? Data(contentsOf: executable)) != contents { try contents.write(to: executable, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var command = adapter
        command.environment["CODEX_PATH"] = executable.path
        command.environment["MYCLIP_CODEX_PATH"] = codexExecutable.path
        return command
    }
}
