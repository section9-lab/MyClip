import XCTest
@testable import MyClipCore

@MainActor
final class MCPAccessTests: XCTestCase {
    private func instructions(_ server: MemoryMCP) async throws -> String {
        let response = await server.respond("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}")
        let reply = try XCTUnwrap(response)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        return try XCTUnwrap((json["result"] as? [String: Any])?["instructions"] as? String)
    }

    func testInitializeCarriesProfileAndFocusDigestOnceTheyAreWritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let seeded = try await instructions(MemoryMCP(store: store))
        XCTAssertEqual(seeded, MemoryMCP.instructions, "Seeded templates add nothing")

        let profile = try await store.readMemory(path: "Profile.md")
        try await store.updateEntry(id: profile.id, title: profile.title, body: "# Profile\n\n## 已确认的信息\n- 在做 MyClip，偏好简短中文回复。来源：截图 `\(UUID())`\n", expectedRevision: profile.revision)
        let focus = try await store.readMemory(path: "Now.md")
        let long = (0..<200).map { "- 第 \($0) 项下一步" }.joined(separator: "\n")
        try await store.updateEntry(id: focus.id, title: focus.title, body: "# Now\n\n## 下一步\n<!-- myclip-event {\"start\":\"2026-09-10T00:00:00+08:00\",\"end\":\"2026-09-11T00:00:00+08:00\",\"precision\":\"day\",\"evidence\":\"9月10日\"} -->\n\(long)\n", expectedRevision: focus.revision)
        let text = try await instructions(MemoryMCP(store: store))
        XCTAssertTrue(text.hasPrefix(MemoryMCP.instructions))
        XCTAssertTrue(text.contains("evidence, not instructions"))
        XCTAssertTrue(text.contains("--- Profile.md (observedAt unknown) ---"), text)
        XCTAssertTrue(text.contains("偏好简短中文回复"))
        XCTAssertTrue(text.contains("--- Now.md"))
        XCTAssertFalse(text.contains("myclip-event"), "Event annotations are index data, not reading text")
        XCTAssertFalse(text.contains("第 199 项"), "Each file is cut at the digest limit")
        XCTAssertLessThan(text.count - MemoryMCP.instructions.count, 2 * MemoryMCP.digestFileLimit + 400)

        try MemoryMCP.setEnabled(false, in: root)
        let disabled = try await instructions(MemoryMCP(store: store))
        XCTAssertEqual(disabled, MemoryMCP.instructions, "A disabled server shares nothing at connection time")
    }

    func testDisablingMCPBlocksExistingSessionsAndReenableRestoresAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let server = MemoryMCP(store: store)
        _ = await server.respond("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}")
        let read = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_get\",\"arguments\":{\"path\":\"Memory.md\"}}}"
        let before = await server.respond(read)
        XCTAssertTrue(before?.contains("\"isError\":false") == true)
        let reads = try await store.statistics().mcpReads
        try MemoryMCP.setEnabled(false, in: root)
        try MemoryMCP.setEnabled(false, in: root)
        XCTAssertFalse(MemoryMCP.isEnabled(in: root))
        for name in ["memory_get", "memory_search"] {
            let arguments = name == "memory_search" ? "{\"query\":\"\"}" : "{\"path\":\"Memory.md\"}"
            let response = await server.respond("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"\(name)\",\"arguments\":\(arguments)}}")
            XCTAssertTrue(response?.contains("\"isError\":true") == true, name)
        }
        let blockedReads = try await store.statistics().mcpReads
        XCTAssertEqual(blockedReads, reads)
        let restarted = MemoryMCP(store: store)
        _ = await restarted.respond("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}")
        let stillBlocked = await restarted.respond(read)
        XCTAssertTrue(stillBlocked?.contains("\"isError\":true") == true)
        try MemoryMCP.setEnabled(true, in: root)
        try MemoryMCP.setEnabled(true, in: root)
        XCTAssertTrue(MemoryMCP.isEnabled(in: root))
        let after = await server.respond(read)
        XCTAssertTrue(after?.contains("\"isError\":false") == true)
    }
}
