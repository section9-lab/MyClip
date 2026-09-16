import XCTest
@testable import MyClipCore

@MainActor
final class MCPAccessTests: XCTestCase {
    func testDisablingMCPBlocksExistingSessionsAndReenableRestoresAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let server = MemoryMCP(store: store)
        _ = await server.respond("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}")
        let read = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"read_memory\",\"arguments\":{\"path\":\"Memory.md\"}}}"
        let before = await server.respond(read)
        XCTAssertTrue(before?.contains("\"isError\":false") == true)
        let reads = try await store.statistics().mcpReads
        try MemoryMCP.setEnabled(false, in: root)
        try MemoryMCP.setEnabled(false, in: root)
        XCTAssertFalse(MemoryMCP.isEnabled(in: root))
        for name in ["read_memory", "search_memories", "get_related_memories", "get_sources"] {
            let arguments = name == "search_memories" ? "{\"query\":\"\"}" : "{\"path\":\"Memory.md\"}"
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
