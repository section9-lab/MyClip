import XCTest
import AppKit
@testable import MyClipCore

@MainActor
final class MemoryQualityLiveTests: XCTestCase {
    func testRealScreenshotsRespectTimeEvidenceAndResolvedInbox() async throws {
        guard let bin = ProcessInfo.processInfo.environment["MYCLIP_LIVE_ACP_BIN"],
              let manifest = ProcessInfo.processInfo.environment["MYCLIP_MEMORY_QUALITY_FIXTURES"] else {
            throw XCTSkip("Opt in with a signed-in ACP agent and a manifest of reviewed screenshots.")
        }
        struct Input: Decodable {
            let id: UUID
            let imagePath: String
            let app: String
            let capturedAt: Double
        }
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        XCTAssertEqual(inputs.count, 2)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-MemoryQuality-\(UUID().uuidString)")
        print("Memory quality acceptance library: \(root.path)")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let directory = root.appendingPathComponent("Memory")
        let focus = try await store.readMemory(path: "Now.md")
        let currentFocus = "# Now\n\n当前重点：验收 Memory 的时间与来源规则。"
        let focusText = try MemoryDocument.encode(id: focus.id, title: focus.title, body: currentFocus,
            revision: focus.revision, agent: .claude, sourceIDs: [], path: "Now.md", observedAt: Date())
        try focusText.write(to: focus.fileURL, atomically: true, encoding: .utf8)
        try "# MyClip\n\n任务看板升级尚无完成汇报记录。".write(to: directory.appendingPathComponent("Wiki/Projects/MyClip.md"), atomically: true, encoding: .utf8)
        let pendingQuestion = "待确认事项：MyClip 0.6.0 是否已有安装并启动的完成汇报。"
        try ("# MyClip 升级汇报\n\n" + pendingQuestion).write(to: directory.appendingPathComponent("Inbox/MyClip升级汇报.md"), atomically: true, encoding: .utf8)
        let index = try await store.readMemory(path: "Memory.md")
        try await store.updateEntry(id: index.id, title: index.title,
            body: "# Memory\n\n[[Now]]\n[[Wiki/Projects/MyClip]]\n[[Inbox/MyClip升级汇报]]", expectedRevision: index.revision)
        for (number, input) in inputs.enumerated() {
            let image = try XCTUnwrap(NSImage(contentsOfFile: input.imagePath))
            var rect = CGRect(origin: .zero, size: image.size)
            let captured = try CapturedImage(image: XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
            let context = CaptureContext(id: input.id, appName: input.app, bundleID: "myclip.quality.\(number)", windowTitle: input.app,
                windowID: UInt32(number + 1), reason: .enter, date: Date(timeIntervalSince1970: input.capturedAt))
            try await store.record(image: captured, context: context, agent: .claude, organize: true)
        }
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        let listener = Task {
            for await event in client.events {
                if case .tool(_, let title, _) = event { print("Memory quality tool: \(title)") }
                if case .permission(let request) = event {
                    let allowed = ["memory_search", "memory_get"].contains { request.title.contains($0) }
                    let option = request.options.first { $0.kind == (allowed ? "allow_once" : "reject_once") }
                    try? await client.respondToPermission(id: request.id, optionID: option?.id)
                }
            }
        }
        defer { listener.cancel() }
        let environment = ["INITIAL_AGENT_MODE": "agent", "DISABLE_MCP_CONFIG_FILTERING": "true", "PATH": bin + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")]
        _ = try await client.connect(command: ACPCommand(executable: URL(fileURLWithPath: bin).appendingPathComponent(ClipAgent.claude.executableName), environment: environment))
        let server = ACPCommand(executable: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/myclip-mcp"), arguments: ["--library", root.path])
        let conversation = try await client.conversation(directory: directory, memoryServer: server, stateFile: root.appendingPathComponent("Sessions/claude.json"))
        try await client.setMode(sessionID: conversation.id, modeID: "acceptEdits")
        var firstPaths: Set<String> = []
        for turn in 1...2 {
            if turn == 2 { _ = try await store.enqueue(sourceIDs: inputs.map(\.id), agent: .claude) }
            let claimed = try await store.claimNextJob(immediately: true)
            let job = try XCTUnwrap(claimed)
            let before = try await store.beginMemoryEditing(jobID: job.id)
            let captures = try await store.captures(ids: job.sourceIDs)
            let result = try await client.prompt(sessionID: conversation.id, text: MemoryPrompt.filePrompt(captures: captures),
                images: captures.map { try Data(contentsOf: $0.imageURL) })
            XCTAssertEqual(result.stopReason, "end_turn")
            _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
            let snapshot = try await store.snapshot()
            let current = try await store.readMemory(path: "Now.md")
            XCTAssertEqual(current.body, currentFocus, "Old screenshots must not replace newer current focus")
            let project = try await store.readMemory(path: "Wiki/Projects/MyClip.md")
            XCTAssertTrue(project.body.contains("0.6.0"))
            XCTAssertEqual(project.sourceIDs, [inputs[0].id], "The unrelated browser page is not project evidence")
            XCTAssertTrue(snapshot.entries.filter { $0.relativePath.hasPrefix("Wiki/Topics/") }.isEmpty, "A passing browser view does not require a permanent topic")
            XCTAssertFalse(snapshot.entries.contains { $0.relativePath.hasPrefix("Inbox/") && $0.body.contains(pendingQuestion) })
            for entry in snapshot.entries {
                let links = try await store.relations(entry.id)
                XCTAssertTrue(links.unresolved.isEmpty, "Keep links intact when resolving Inbox: \(entry.relativePath)")
            }
            let paths = Set(snapshot.entries.map(\.relativePath))
            let calendarDate = DateFormatter()
            calendarDate.locale = Locale(identifier: "en_US_POSIX")
            calendarDate.timeZone = .current
            calendarDate.dateFormat = "'Daily/'yyyy/MM/yyyy-MM-dd'.md'"
            XCTAssertTrue(paths.contains(calendarDate.string(from: Date(timeIntervalSince1970: inputs[0].capturedAt))), "Daily belongs to the local capture date")
            if turn == 1 { firstPaths = paths }
            else { XCTAssertEqual(paths, firstPaths, "Reprocessing the same screenshots must not create duplicate notes") }
            print("Memory quality turn \(turn) finished: \(paths.sorted())")
        }
    }
}
