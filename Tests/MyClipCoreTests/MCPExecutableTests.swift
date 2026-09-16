import XCTest
@testable import MyClipCore

@MainActor
final class MCPExecutableTests: XCTestCase {
    func testStdioMemoryRetrievalAndReadOnlyBoundary() async throws {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/myclip-mcp")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), "Build the shipped MCP executable")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let context = fixtureContext()
        try await store.record(image: fixtureImage(), context: context, agent: .codex, organize: true)
        let claimed = try await store.claimNextJob(immediately: true)
        try await store.commit(jobID: XCTUnwrap(claimed).id, drafts: [KnowledgeDraft(kind: .memory, title: "上海出差", body: "会议地点已确认。", sourceIDs: [context.id])])
        let proc = Process(), input = Pipe(), output = Pipe()
        proc.executableURL = binary; proc.arguments = ["--library", root.path]
        proc.standardInput = input; proc.standardOutput = output
        try proc.run()
        let requests = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_memories","arguments":{"query":"上海"}}}
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_memory","arguments":{}}}
        """
        try input.fileHandleForWriting.write(contentsOf: Data((requests + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        let replies = try String(decoding: data, as: UTF8.self).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(replies.count, 4, "Notifications must not produce responses")
        XCTAssertEqual((replies[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]] != nil, true)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("上海出差"))
        XCTAssertNotNil(replies[3]["error"])
        let unchanged = try await store.snapshot()
        XCTAssertEqual(unchanged.entries.filter { !$0.isRootDocument }.count, 1)
    }
}
