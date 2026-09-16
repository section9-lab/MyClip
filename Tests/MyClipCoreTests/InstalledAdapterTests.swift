import XCTest
@testable import MyClipCore

@MainActor
final class InstalledAdapterTests: XCTestCase {
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
}
