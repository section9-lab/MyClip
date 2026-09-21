import XCTest
@testable import MyClipCore

@MainActor
final class InstalledAdapterTests: XCTestCase {
    func testCodexEphemeralSessionDoesNotPersist() async throws { try await checkEphemeralSession(.codex) }
    func testClaudeEphemeralSessionDoesNotPersist() async throws { try await checkEphemeralSession(.claude) }

    private func checkEphemeralSession(_ agent: ClipAgent) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MYCLIP_TEST_EPHEMERAL"] == "1", let bin = environment["MYCLIP_TEST_ACP_BIN"] else {
            throw XCTSkip("Set MYCLIP_TEST_EPHEMERAL=1 and MYCLIP_TEST_ACP_BIN to make a small real model request.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("myclip-ephemeral-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var command = ACPCommand(executable: URL(fileURLWithPath: bin).appendingPathComponent(agent.executableName),
            environment: ["INITIAL_AGENT_MODE": "read-only", "DISABLE_MCP_CONFIG_FILTERING": "true",
                "PATH": bin + ":" + (environment["PATH"] ?? "/usr/bin:/bin")])
        if agent == .codex {
            command = try EphemeralCodexCommand.prepare(command, codexExecutable: URL(fileURLWithPath: bin).appendingPathComponent("codex"), directory: directory)
        }
        let client = ACPClient(promptIdleTimeout: .seconds(45), promptMaximumDuration: .seconds(60))
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: command)
        let session = try await client.newSession(directory: directory, ephemeralFor: agent)
        let result = try await client.prompt(sessionID: session, text: "Reply with exactly MYCLIP_EPHEMERAL_OK. Do not use tools or read any files.", images: [])
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertTrue(result.text.contains("MYCLIP_EPHEMERAL_OK"))
        await client.close()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = agent == .codex
            ? [URL(fileURLWithPath: environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)]
            : [URL(fileURLWithPath: environment["CLAUDE_CONFIG_DIR"] ?? home.appendingPathComponent(".claude").path)]
        let folders = agent == .codex ? ["sessions", "archived_sessions"] : ["projects"]
        for root in roots {
            for folder in folders {
                let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
                while let file = files?.nextObject() as? URL {
                    XCTAssertFalse(file.lastPathComponent.contains(session), "Temporary session unexpectedly persisted at \(file.path)")
                }
            }
        }
        print("\(agent.name): real request completed in ephemeral session; no session file found")
    }

    func testInstalledAdapterHandshakes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MYCLIP_TEST_ACP_BIN"] else {
            throw XCTSkip("Set MYCLIP_TEST_ACP_BIN to opt in to real adapter handshake checks.")
        }
        for agent in ClipAgent.allCases {
            let client = ACPClient()
            let command = ACPCommand(executable: URL(fileURLWithPath: directory).appendingPathComponent(agent.executableName),
                                     environment: ["INITIAL_AGENT_MODE": "read-only"])
            do {
                let result = try await client.connect(command: command)
                XCTAssertTrue(result.supportsImages, "\(agent.name) must accept screenshots")
                print("\(agent.name): ACP v1 image capability verified; \(result.authMethods.count) authentication methods")
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        }
    }

    func testInstalledAdaptersAcceptFullAccessModes() async throws {
        guard let bin = ProcessInfo.processInfo.environment["MYCLIP_TEST_ACP_BIN"] else {
            throw XCTSkip("Set MYCLIP_TEST_ACP_BIN to verify full access with installed adapters.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("myclip-full-access-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for agent in ClipAgent.allCases {
            var command = ACPCommand(executable: URL(fileURLWithPath: bin).appendingPathComponent(agent.executableName),
                environment: ["INITIAL_AGENT_MODE": "agent-full-access", "DISABLE_MCP_CONFIG_FILTERING": "true",
                    "PATH": bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")])
            if agent == .codex {
                command = try EphemeralCodexCommand.prepare(command, codexExecutable: URL(fileURLWithPath: bin).appendingPathComponent("codex"), directory: directory)
            }
            let client = ACPClient()
            addTeardownBlock { await client.close() }
            _ = try await client.connect(command: command)
            let session = try await client.newSession(directory: directory, ephemeralFor: agent)
            try await client.setMode(sessionID: session, modeID: agent == .codex ? "agent-full-access" : "bypassPermissions")
            await client.close()
            print("\(agent.name): full access mode accepted without a model request")
        }
    }
}
