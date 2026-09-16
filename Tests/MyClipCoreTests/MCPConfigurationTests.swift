import XCTest
@testable import MyClipCore

@MainActor
final class MCPConfigurationTests: XCTestCase {
    var root: URL!
    let executable = URL(fileURLWithPath: "/Applications/My Clip.app/Contents/MacOS/MyClip")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    var installer: MCPClientInstaller {
        MCPClientInstaller(homeDirectory: root, environment: [:])
    }

    var command: ACPCommand {
        ACPCommand(executable: executable, arguments: ["--mcp", "--library", root.appendingPathComponent("My Library").path])
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.json5Allowed]) as? [String: Any])
    }

    func testJSONClientsPreserveOtherSettingsAndUseExactCommandArguments() async throws {
        for client in [MCPClient.claudeCode, .cursor, .openCode] {
            let url = installer.configurationURL(for: client)
            let key = client == .openCode ? "mcp" : "mcpServers"
            let original = "{\"theme\":\"dark\",\"\(key)\":{\"existing\":{\"url\":\"https://example.com/mcp\"}}}"
            try write(original, to: url)
            try await installer.install(client, command: command)
            let config = try json(url)
            XCTAssertEqual(config["theme"] as? String, "dark")
            let servers = try XCTUnwrap(config[key] as? [String: [String: Any]])
            XCTAssertEqual(servers["existing"]?["url"] as? String, "https://example.com/mcp")
            let memory = try XCTUnwrap(servers["myclip"])
            if client == .openCode {
                XCTAssertEqual(memory["type"] as? String, "local")
                XCTAssertEqual(memory["command"] as? [String], [executable.path] + command.arguments)
                XCTAssertEqual(memory["enabled"] as? Bool, true)
            } else {
                XCTAssertEqual(memory["command"] as? String, executable.path)
                XCTAssertEqual(memory["args"] as? [String], command.arguments)
            }
            XCTAssertEqual(try String(contentsOf: url.appendingPathExtension("myclip-backup"), encoding: .utf8), original)
            let installed = try Data(contentsOf: url)
            try await installer.install(client, command: command)
            XCTAssertEqual(try Data(contentsOf: url), installed)
            XCTAssertEqual(try String(contentsOf: url.appendingPathExtension("myclip-backup"), encoding: .utf8), original)
        }
    }

    func testOnlySelectedClientIsConfigured() async throws {
        try await installer.install(.cursor, command: command)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.configurationURL(for: .cursor).path))
        for client in [MCPClient.codex, .claudeCode, .openCode] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: installer.configurationURL(for: client).path))
        }
    }

    func testOpenCodeUsesExistingJSONCAndKeepsSettings() async throws {
        let url = root.appendingPathComponent(".config/opencode/opencode.jsonc")
        try write("{ // personal settings\n \"model\": \"provider/model\", \"mcp\": {}, }", to: url)
        XCTAssertEqual(installer.configurationURL(for: .openCode), url)
        try await installer.install(.openCode, command: command)
        XCTAssertEqual(try json(url)["model"] as? String, "provider/model")
        XCTAssertNotNil((try json(url)["mcp"] as? [String: Any])?["myclip"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("json").path))
    }

    func testMalformedOrConflictingConfigurationIsNeverOverwritten() async throws {
        for original in ["{invalid", "[]", "{\"mcpServers\": []}", "{\"mcpServers\":{\"myclip\":{\"url\":\"https://example.com/mcp\"}}}"] {
            let url = installer.configurationURL(for: .cursor)
            try write(original, to: url)
            do {
                try await installer.install(.cursor, command: command)
                XCTFail("Invalid or unrelated configuration must be preserved")
            } catch { }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        }
    }

    func testReenableExistingMyClipKeepsCustomSettings() async throws {
        let url = installer.configurationURL(for: .cursor)
        try write("{\"mcpServers\":{\"myclip\":{\"command\":\"/old/MyClip\",\"args\":[\"--mcp\"],\"disabled\":true,\"env\":{\"CUSTOM\":\"value\"}}}}", to: url)
        try await installer.install(.cursor, command: command)
        let servers = try XCTUnwrap(try json(url)["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["myclip"]?["disabled"] as? Bool, false)
        XCTAssertEqual(servers["myclip"]?["env"] as? [String: String], ["CUSTOM": "value"])
        XCTAssertEqual(servers["myclip"]?["command"] as? String, executable.path)
    }

    func testCodexOfficialCLIUpdatesOnlyMyClipAndIsRepeatable() async throws {
        let cli = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let cli else { throw XCTSkip("Codex CLI is not installed") }
        let installer = MCPClientInstaller(homeDirectory: root, environment: [:], codexExecutable: URL(fileURLWithPath: cli))
        let url = installer.configurationURL(for: .codex)
        try write("# Keep user preferences\nmodel = \"example-model\"\n[mcp_servers.existing]\ncommand = \"existing-server\"\n", to: url)
        try await installer.install(.codex, command: command)
        try await installer.install(.codex, command: command)
        let config = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(config.contains("# Keep user preferences"))
        XCTAssertTrue(config.contains("model = \"example-model\""))
        XCTAssertTrue(config.contains("[mcp_servers.existing]"))
        XCTAssertTrue(config.contains(executable.path))
        XCTAssertEqual(config.components(separatedBy: "[mcp_servers.myclip]").count, 2)
    }
}
