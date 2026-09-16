import XCTest
import AppKit
@testable import MyClipCore

@MainActor
final class LiveAgentTests: XCTestCase {
    func testRealCodexOrganizesEightCapturesInOneBatch() async throws {
        guard let bin = ProcessInfo.processInfo.environment["MYCLIP_LIVE_ACP_BIN"] else {
            throw XCTSkip("Opt in with MYCLIP_LIVE_ACP_BIN; this test uses the signed-in agent.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-Batch-Acceptance-\(UUID().uuidString)")
        let store = try LibraryStore(root: root)
        let marker = String(UUID().uuidString.prefix(8))
        var sourceIDs: [UUID] = []
        for index in 1...8 {
            let image = NSImage(size: NSSize(width: 1000, height: 420), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                let text = "MyClip 合批验收\n\n记录编号：\(marker)-\(index)\n这是第 \(index) 个应用窗口中的独立事实。" as NSString
                text.draw(at: NSPoint(x: 45, y: 110), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
                return true
            }
            var rect = CGRect(origin: .zero, size: image.size)
            let captured = try CapturedImage(image: XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
            let context = CaptureContext(appName: "验收应用 \(index)", bundleID: "myclip.acceptance.\(index)", windowTitle: "窗口 \(index)", windowID: UInt32(index), reason: .enter)
            sourceIDs.append(context.id)
            try await store.record(image: captured, context: context, agent: .codex, organize: true)
        }
        let claimed = try await store.claimNextJob(immediately: true)
        let job = try XCTUnwrap(claimed)
        XCTAssertEqual(job.sourceIDs, sourceIDs)
        let before = try await store.beginMemoryEditing(jobID: job.id)
        let inputs = try await store.captures(ids: job.sourceIDs)
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        let listener = Task {
            for await event in client.events {
                if case .tool(_, let title, _) = event { print("Batch tool: \(title)") }
                if case .permission(let request) = event {
                    let allowed = ["search_memories", "read_memory", "get_sources", "get_related_memories"].contains { request.title.contains($0) }
                    let option = request.options.first { $0.kind == (allowed ? "allow_once" : "reject_once") }
                    try? await client.respondToPermission(id: request.id, optionID: option?.id)
                }
            }
        }
        defer { listener.cancel() }
        _ = try await client.connect(command: ACPCommand(executable: URL(fileURLWithPath: bin).appendingPathComponent(ClipAgent.codex.executableName), environment: ["INITIAL_AGENT_MODE": "agent", "DISABLE_MCP_CONFIG_FILTERING": "true", "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")]))
        let server = ACPCommand(executable: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/myclip-mcp"), arguments: ["--library", root.path])
        let conversation = try await client.conversation(directory: root.appendingPathComponent("Memory"), memoryServer: server, stateFile: root.appendingPathComponent("Sessions/codex.json"))
        try await client.setMode(sessionID: conversation.id, modeID: "agent")
        let prompt = KnowledgeComposer.filePrompt(captures: inputs) + "\n本次是隔离目录中的软件验收。请实际创建 Wiki/Topics/合批验收.md，记录全部附图中的记录编号和对应的应用、窗口。保留根文件。"
        let started = Date()
        let response = try await client.prompt(sessionID: conversation.id, text: prompt, images: inputs.map { try Data(contentsOf: $0.imageURL) })
        XCTAssertEqual(response.stopReason, "end_turn")
        _ = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
        let note = try await store.readMemory(path: "Wiki/Topics/合批验收.md")
        for index in 1...8 { XCTAssertTrue(note.body.contains("\(marker)-\(index)"), "Every screenshot must be read") }
        XCTAssertEqual(Set(note.sourceIDs), Set(sourceIDs))
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.jobs.count, 1)
        XCTAssertEqual(snapshot.jobs.first?.state, .completed)
        XCTAssertEqual(snapshot.queue.pendingCount, 0)
        print("Eight images → one ACP prompt → Markdown with eight sources PASS (\(Int(Date().timeIntervalSince(started)))s): \(root.path)")
    }

    func testRealCodexRestoresConversation() async throws { try await checkRestoration(.codex) }
    func testRealClaudeRestoresConversation() async throws { try await checkRestoration(.claude) }

    private func checkRestoration(_ agent: ClipAgent) async throws {
        guard let bin = ProcessInfo.processInfo.environment["MYCLIP_LIVE_ACP_BIN"] else {
            throw XCTSkip("Opt in with MYCLIP_LIVE_ACP_BIN; this test uses the signed-in agents.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-Conversation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Conversation acceptance library: \(root.path)")
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let directory = root.appendingPathComponent("Memory")
        let server = ACPCommand(executable: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/myclip-mcp"), arguments: ["--library", root.path])
        let command = ACPCommand(executable: URL(fileURLWithPath: bin).appendingPathComponent(agent.executableName),
            environment: ["INITIAL_AGENT_MODE": "agent", "DISABLE_MCP_CONFIG_FILTERING": "true", "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")])
        let stateFile = root.appendingPathComponent("Sessions/\(agent.rawValue).json")
        let original = ACPClient()
        let reopened = ACPClient()
        addTeardownBlock { await original.close(); await reopened.close() }
        var listeners: [Task<Void, Never>] = []
        for client in [original, reopened] {
            listeners.append(Task {
                for await event in client.events {
                    if case .tool(_, let title, _) = event { print("\(agent.name) tool: \(title)") }
                    if case .permission(let request) = event {
                        let allowed = ["search_memories", "read_memory", "get_sources", "get_related_memories"].contains { request.title.contains($0) }
                        print("\(agent.name) permission: \(request.title); read-only MCP allowed: \(allowed)")
                        let option = request.options.first { $0.kind == (allowed ? "allow_once" : "reject_once") }
                        try? await client.respondToPermission(id: request.id, optionID: option?.id)
                    }
                }
            })
        }
        defer { listeners.forEach { $0.cancel() } }
        let marker = "青杉-" + UUID().uuidString.prefix(8)
        var sessionID = ""
        var noteID: UUID?
        var sourceIDs: [UUID] = []
        for turn in 1...2 {
            let image = NSImage(size: NSSize(width: 1000, height: 420), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                let text = "MyClip 文件整理验收\n\n项目：纸夹记忆\n第 \(turn) 批事实：验收编号 729\(turn) 已确认。\nMemory 使用 Markdown 和 Wikilink。" as NSString
                text.draw(at: NSPoint(x: 45, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
                return true
            }
            var rect = CGRect(origin: .zero, size: image.size)
            let captured = try CapturedImage(image: XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
            let context = CaptureContext(appName: "MyClip 验收", bundleID: "myclip.acceptance", windowTitle: "持续整理", windowID: 1, reason: .enter)
            sourceIDs.append(context.id)
            try await store.record(image: captured, context: context, agent: agent, organize: true)
            let claimed = try await store.claimNextJob(immediately: true)
            let job = try XCTUnwrap(claimed)
            let before = try await store.beginMemoryEditing(jobID: job.id)
            let client = turn == 1 ? original : reopened
            _ = try await client.connect(command: command)
            let conversation = try await client.conversation(directory: directory, memoryServer: server, stateFile: stateFile)
            try await client.setMode(sessionID: conversation.id, modeID: agent == .codex ? "agent" : "acceptEdits")
            if turn == 1 { sessionID = conversation.id }
            else {
                XCTAssertEqual(conversation.id, sessionID)
                XCTAssertEqual(conversation.origin, .restored)
            }
            let captures = try await store.captures(ids: [context.id])
            var prompt = KnowledgeComposer.filePrompt(captures: captures) + "\n本次是隔离目录中的软件验收，仅创建或更新 Wiki/Topics/文件验收.md，保留已有事实，将附图中的新事实加入此文件。请实际使用文件工具或 Bash 完成写入。"
            if turn == 1 { prompt += "\n另请在会话中记住短语：\(marker)。不要把这个短语写入任何文件。" }
            else { prompt += "\n更新文件后，在简短回复中附上上一轮要求只记在会话里的短语，不要把它写入文件。" }
            let response = try await client.prompt(sessionID: conversation.id, text: prompt, images: [captured.pngData])
            try response.text.write(to: root.appendingPathComponent("turn-\(turn).txt"), atomically: true, encoding: .utf8)
            XCTAssertEqual(response.stopReason, "end_turn")
            let count = try await store.finishMemoryEditing(jobID: job.id, previousRevisions: before)
            XCTAssertGreaterThan(count, 0, "Agent must actually edit Markdown on disk")
            let note = try await store.readMemory(path: "Wiki/Topics/文件验收.md")
            XCTAssertTrue(note.body.contains("729\(turn)"), "New facts must come from the image")
            XCTAssertFalse(note.body.contains(marker), "The conversation-only marker must not be stored in Memory")
            XCTAssertEqual(Set(note.sourceIDs), Set(sourceIDs))
            if turn == 1 { noteID = note.id }
            else {
                XCTAssertEqual(note.id, noteID)
                XCTAssertTrue(note.body.contains("7291"), "Earlier facts must survive the next edit")
                XCTAssertTrue(response.text.localizedCaseInsensitiveContains(marker), "The agent must retain conversation context after restart")
            }
            await client.close()
        }
        print("\(agent.name): image → direct Markdown edit → process restart → same session → second edit PASS")
    }

    func testRealAgentsGenerateThenRetrieveMemoryThroughMCP() async throws {
        guard let bin = ProcessInfo.processInfo.environment["MYCLIP_LIVE_ACP_BIN"] else {
            throw XCTSkip("Opt in with MYCLIP_LIVE_ACP_BIN; this test uses the signed-in agents.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-Acceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Acceptance library: \(root.path)")
        let store = try LibraryStore(root: root)
        let image = NSImage(size: NSSize(width: 1000, height: 500), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            let text = "MyClip 验收规则\n\n验收编号：青杉-7294\n截图只记录前台应用的焦点窗口。\n移动后静止一秒，再点击截图。\n滚动停止两秒或回车也可触发。\nMemory 使用 Markdown 和 Wikilink。" as NSString
            text.draw(at: NSPoint(x: 45, y: 120), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
            return true
        }
        var rect = CGRect(origin: .zero, size: image.size)
        let captured = try CapturedImage(image: XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/myclip-mcp")
        let server = ACPCommand(executable: binary, arguments: ["--library", root.path])
        for agent in ClipAgent.allCases where ProcessInfo.processInfo.environment["MYCLIP_LIVE_AGENT"] == nil || ProcessInfo.processInfo.environment["MYCLIP_LIVE_AGENT"] == agent.rawValue {
            var activeJob: UUID?
            let client = ACPClient()
            let listener = Task {
                for await event in client.events {
                    if case .permission(let request) = event {
                        let allowed = ["search_memories", "read_memory", "get_sources", "get_related_memories"].contains { request.title.contains($0) }
                        let option = request.options.first { $0.kind == (allowed ? "allow_once" : "reject_once") }
                        try? await client.respondToPermission(id: request.id, optionID: option?.id)
                    }
                }
            }
            do {
                let context = CaptureContext(appName: "MyClip 验收", bundleID: "myclip.acceptance", windowTitle: "记忆规则", windowID: 1, reason: .enter)
                try await store.record(image: captured, context: context, agent: agent, organize: false)
                try await store.enqueue(sourceIDs: [context.id], agent: agent)
                let claimed = try await store.claimNextJob(immediately: true)
                let job = try XCTUnwrap(claimed)
                activeJob = job.id
                _ = try await client.connect(command: ACPCommand(executable: URL(fileURLWithPath: bin).appendingPathComponent(agent.executableName), environment: ["INITIAL_AGENT_MODE": "read-only", "DISABLE_MCP_CONFIG_FILTERING": "true", "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")]))
                let session = try await client.newSession(directory: root, memoryServer: server)
                let inputs = try await store.captures(ids: [context.id])
                let prompt = KnowledgeComposer.prompt(captures: inputs, existing: []) + "\n本次是用户授权的软件验收。请新建一条标题含“\(agent.name) 验收”的测试记忆，保存图片中的验收编号和规则。不要更新其他记忆。"
                let result = try await client.prompt(sessionID: session, text: prompt, images: [captured.pngData])
                try result.text.write(to: root.appendingPathComponent("\(agent.rawValue)-response.txt"), atomically: true, encoding: .utf8)
                print("\(agent.name) stopped: \(result.stopReason); response: \(result.text.prefix(1800))")
                let drafts = try KnowledgeComposer.parse(result.text)
                XCTAssertFalse(drafts.isEmpty, "\(agent.name) must produce a memory")
                XCTAssertTrue(drafts.map(\.body).joined().contains("7294"), "Must read the marker from the image")
                XCTAssertTrue(drafts.allSatisfy { $0.path?.hasSuffix(".md") == true }, "Agent must choose a Markdown path in the new layout")
                try await store.commit(jobID: job.id, drafts: drafts)
                let previousReads = try await store.statistics().mcpReads
                let retrieval = try await client.newSession(directory: root, memoryServer: server)
                let answer = try await client.prompt(sessionID: retrieval, text: "请通过 myclip 的 search_memories 搜索“\(agent.name) 验收”，再用结果的 path 调用 read_memory 阅读。只返回找到的验收编号和 sourceIDs，不能使用文件或终端工具。", images: [])
                try answer.text.write(to: root.appendingPathComponent("\(agent.rawValue)-retrieval.txt"), atomically: true, encoding: .utf8)
                XCTAssertTrue(answer.text.contains("7294"))
                XCTAssertTrue(answer.text.lowercased().contains(context.id.uuidString.lowercased()))
                let reads = try await store.statistics().mcpReads
                XCTAssertGreaterThan(reads, previousReads, "Retrieval must really call MyClip MCP")
                if reads > previousReads && answer.text.contains("7294") && answer.text.lowercased().contains(context.id.uuidString.lowercased()) {
                    print("\(agent.name): image → Memory → independent ACP session → MCP retrieval PASS")
                } else { print("\(agent.name) retrieval failed: \(answer.text)") }
            } catch {
                if let activeJob { try? await store.finishJob(id: activeJob, state: .failed, error: error.localizedDescription) }
                XCTFail("\(agent.name) live acceptance: \(error)")
            }
            listener.cancel()
            await client.close()
        }
    }
}
