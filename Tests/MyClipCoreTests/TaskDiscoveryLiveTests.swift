import XCTest
@testable import MyClipCore

@MainActor
final class TaskDiscoveryLiveTests: XCTestCase {
    func testAgentFindsTaskFromMemoryWithoutEditingIt() async throws {
        guard let bin = ProcessInfo.processInfo.environment["MYCLIP_LIVE_ACP_BIN"] else {
            throw XCTSkip("Opt in with MYCLIP_LIVE_ACP_BIN; this test uses the signed-in agent.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-Task-Acceptance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let initial = try await store.snapshot()
        let memory = try XCTUnwrap(initial.entries.first { $0.relativePath == "Now.md" })
        try await store.updateEntry(id: memory.id, title: "蓝杉项目", body: "# 蓝杉项目\n\n用户已明确安排下一步：校验蓝杉项目的导出字段。该工作还未开始。\n这是一条软件验收用的合成记录。", expectedRevision: memory.revision)
        let updated = try await store.readMemory(memory.id)
        let original = try String(contentsOf: updated.fileURL, encoding: .utf8)
        let client = ACPClient()
        addTeardownBlock { await client.close() }
        let listener = Task {
            for await event in client.events {
                if case .permission(let request) = event {
                    let allowed = ["memory_get", "memory_search"].contains { request.title.contains($0) }
                    let option = request.options.first { $0.kind == (allowed ? "allow_once" : "reject_once") }
                    try? await client.respondToPermission(id: request.id, optionID: option?.id)
                }
            }
        }
        defer { listener.cancel() }
        let command = ACPCommand(executable: URL(fileURLWithPath: bin).appendingPathComponent("codex-acp"), environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")])
        _ = try await client.connect(command: command)
        let session = try await client.newSession(directory: root.appendingPathComponent("Memory"))
        let response = try await client.prompt(sessionID: session, text: TaskComposer.discoveryPrompt(memories: [updated], tasks: []), images: [])
        XCTAssertEqual(response.stopReason, "end_turn")
        let drafts = try TaskComposer.parse(response.text)
        XCTAssertFalse(drafts.isEmpty, "The explicit work task must be discovered")
        try await store.ingestTaskSuggestions(drafts, allowedSourceIDs: [], allowedMemoryIDs: [memory.id])
        let tasks = try await store.workTasks()
        XCTAssertTrue(tasks.contains { $0.title.contains("导出字段") && $0.status == .candidate && $0.evidence.contains { $0.memoryIDs.contains(memory.id) } })
        XCTAssertEqual(try String(contentsOf: updated.fileURL, encoding: .utf8), original)
        await client.close()
    }
}
