import XCTest
@testable import MyClipCore

final class AgentSessionTests: XCTestCase {
    private let sessionID = "01a0ab51-7407-7e03-8df0-2e7bd3dd0a95"

    func testCodexLinkOpensTheExactSession() throws {
        let session = try XCTUnwrap(ClipAgentSession(agent: .codex, id: sessionID, directory: URL(fileURLWithPath: "/tmp/Memory")))
        XCTAssertEqual(session.appURL?.absoluteString, "codex://threads/\(sessionID)")
        let claude = try XCTUnwrap(ClipAgentSession(agent: .claude, id: sessionID, directory: session.directory))
        XCTAssertNil(claude.appURL)
    }

    func testInvalidSessionIDsCannotOpenAnotherRouteOrSessionPicker() {
        for agent in ClipAgent.allCases {
            for id in ["", " ", "new", "../new", sessionID + "?prompt=test", sessionID + "\n"] {
                XCTAssertNil(ClipAgentSession(agent: agent, id: id, directory: URL(fileURLWithPath: "/tmp/Memory")))
            }
        }
    }

    func testTerminalResumesExactSessionInItsWorkspaceWithoutSendingAPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Memory's 中文 $HOME `pwd`")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("agent's $HOME `pwd`")
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$MYCLIP_SESSION_TEST\" \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let environmentValue = "value's $HOME `pwd`\nsecond line"
        let command = ACPCommand(executable: executable, environment: ["MYCLIP_SESSION_TEST": environmentValue])

        for agent in ClipAgent.allCases {
            let session = try XCTUnwrap(ClipAgentSession(agent: agent, id: sessionID, directory: workspace))
            let script = root.appendingPathComponent("\(agent.rawValue).command")
            try session.terminalScript(command: command).write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let arguments = agent == .codex ? ["resume", sessionID] : ["--cli", "--resume", sessionID]
            XCTAssertEqual(String(data: output, encoding: .utf8), ([workspace.path, environmentValue] + arguments).joined(separator: "\n") + "\n")
        }
    }

    func testOnlyConnectedSessionsCanBeOpened() {
        var state = ClipAgentState()
        for phase in [ClipAgentState.Phase.ready, .working, .permission] {
            state.phase = phase
            XCTAssertFalse(state.canOpenSession)
        }
        state.sessionID = sessionID
        for phase in [ClipAgentState.Phase.ready, .working, .permission] {
            state.phase = phase
            XCTAssertTrue(state.canOpenSession)
        }
        for phase in [ClipAgentState.Phase.disconnected, .connecting, .installing, .failed] {
            state.phase = phase
            XCTAssertFalse(state.canOpenSession)
        }
        state.phase = .working
        state.sessionID = ""
        XCTAssertFalse(state.canOpenSession)
    }
}
