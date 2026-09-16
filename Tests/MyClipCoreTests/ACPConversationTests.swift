import XCTest
@testable import MyClipCore

@MainActor
final class ACPConversationTests: XCTestCase {
    var directory: URL!
    var stateFile: URL { directory.appendingPathComponent("Sessions/codex.json") }
    var agentFile: URL { directory.appendingPathComponent("agent.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func client(_ scenario: String = "conversation") async throws -> ACPClient {
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        _ = try await client.connect(command: ACPCommand(executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", Bundle.module.url(forResource: "acp_agent", withExtension: "py", subdirectory: "Fixtures")!.path],
            environment: ["MYCLIP_ACP_SCENARIO": scenario, "MYCLIP_ACP_CONVERSATIONS": agentFile.path]))
        return client
    }

    func requests(_ method: String) throws -> [[String: Any]] {
        try String(contentsOf: URL(fileURLWithPath: agentFile.path + ".requests"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            .filter { $0["method"] as? String == method }
    }

    func testConsecutiveBatchesKeepOneConversation() async throws {
        let client = try await client()
        let first = try await client.conversation(directory: directory, stateFile: stateFile)
        let initial = try await client.prompt(sessionID: first.id, text: "first", images: [fixtureImage().pngData])
        XCTAssertEqual(initial.text, "first")
        let next = try await client.conversation(directory: directory, stateFile: stateFile)
        let result = try await client.prompt(sessionID: next.id, text: "second", images: [fixtureImage(changed: true).pngData])
        XCTAssertEqual(next.id, first.id)
        XCTAssertEqual(result.text, "first|second")
        XCTAssertEqual(try requests("session/new").count, 1)
    }

    func testRestartResumesConversationWithMemoryServer() async throws {
        let firstClient = try await client()
        let first = try await firstClient.conversation(directory: directory, stateFile: stateFile)
        _ = try await firstClient.prompt(sessionID: first.id, text: "before restart", images: [])
        await firstClient.close()

        let reopened = try await client()
        let server = ACPCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["--mcp", "--library", directory.path])
        let restored = try await reopened.conversation(directory: directory, memoryServer: server, stateFile: stateFile)
        let result = try await reopened.prompt(sessionID: restored.id, text: "after restart", images: [])
        XCTAssertEqual(restored.id, first.id)
        XCTAssertEqual(restored.origin, .restored)
        XCTAssertEqual(result.text, "before restart|after restart")
        XCTAssertEqual(try requests("session/new").count, 1)
        let params = try XCTUnwrap(requests("session/resume").first?["params"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, directory.path)
        let servers = try XCTUnwrap(params["mcpServers"] as? [[String: Any]])
        XCTAssertEqual(servers.first?["command"] as? String, server.executable.path)
        XCTAssertEqual(servers.first?["args"] as? [String], server.arguments)
    }

    func testLoadOnlyAgentRestoresWithoutMixingReplayedOutput() async throws {
        let firstClient = try await client("conversation_load_only")
        let first = try await firstClient.conversation(directory: directory, stateFile: stateFile)
        _ = try await firstClient.prompt(sessionID: first.id, text: "first", images: [])
        await firstClient.close()
        let reopened = try await client("conversation_load_only")
        let restored = try await reopened.conversation(directory: directory, stateFile: stateFile)
        let result = try await reopened.prompt(sessionID: restored.id, text: "second", images: [])
        XCTAssertEqual(restored.id, first.id)
        XCTAssertEqual(result.text, "first|second")
        XCTAssertEqual(try requests("session/load").count, 1)
        XCTAssertTrue(try requests("session/resume").isEmpty)
    }

    func testDeletedSessionGetsReplacement() async throws {
        let firstClient = try await client()
        let first = try await firstClient.conversation(directory: directory, stateFile: stateFile)
        await firstClient.close()
        let reopened = try await client("conversation_missing")
        let replacement = try await reopened.conversation(directory: directory, stateFile: stateFile)
        XCTAssertNotEqual(replacement.id, first.id)
        XCTAssertEqual(replacement.origin, .replaced)
        let reused = try await reopened.conversation(directory: directory, stateFile: stateFile)
        XCTAssertEqual(reused.id, replacement.id)
        XCTAssertEqual(try requests("session/new").count, 2)
    }

    func testUnsupportedRecoveryCreatesOneReusableReplacement() async throws {
        let firstClient = try await client()
        _ = try await firstClient.conversation(directory: directory, stateFile: stateFile)
        await firstClient.close()
        let reopened = try await client("conversation_no_restore")
        let replacement = try await reopened.conversation(directory: directory, stateFile: stateFile)
        let reused = try await reopened.conversation(directory: directory, stateFile: stateFile)
        XCTAssertEqual(replacement.origin, .replaced)
        XCTAssertEqual(reused.id, replacement.id)
        XCTAssertTrue(try requests("session/resume").isEmpty)
        XCTAssertTrue(try requests("session/load").isEmpty)
    }

    func testAuthenticationFailureKeepsSavedConversation() async throws {
        let firstClient = try await client()
        _ = try await firstClient.conversation(directory: directory, stateFile: stateFile)
        let saved = try Data(contentsOf: stateFile)
        await firstClient.close()
        let reopened = try await client("conversation_auth")
        do {
            _ = try await reopened.conversation(directory: directory, stateFile: stateFile)
            XCTFail("Authentication errors must not replace an existing conversation")
        } catch ACPError.remote(let code, _) { XCTAssertEqual(code, -32000) }
        XCTAssertEqual(try Data(contentsOf: stateFile), saved)
        XCTAssertEqual(try requests("session/new").count, 1)
    }

    func testSeparateAgentRecordsKeepIndependentHistory() async throws {
        let codex = try await client()
        let first = try await codex.conversation(directory: directory, stateFile: stateFile)
        _ = try await codex.prompt(sessionID: first.id, text: "Codex", images: [])
        await codex.close()
        let claude = try await client()
        let second = try await claude.conversation(directory: directory, stateFile: directory.appendingPathComponent("Sessions/claude.json"))
        let result = try await claude.prompt(sessionID: second.id, text: "Claude", images: [])
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(result.text, "Claude")
        await claude.close()
        let reconnectedCodex = try await client()
        let restored = try await reconnectedCodex.conversation(directory: directory, stateFile: stateFile)
        XCTAssertEqual(restored.id, first.id)
    }
}
