import XCTest
@testable import MyClipCore

final class AgentExpressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testPermissionAndFailureOverrideRecentCompletion() {
        var state = ClipAgentState()
        state.lastCompleted = now
        for phase in [ClipAgentState.Phase.permission, .failed] {
            state.phase = phase
            XCTAssertEqual(state.expression(at: now), .attention)
        }
    }

    func testNewWorkOverridesPreviousSuccess() {
        var state = ClipAgentState()
        state.phase = .working
        state.lastCompleted = now
        XCTAssertEqual(state.expression(at: now), .working)
    }

    func testSuccessExpiresAndDoesNotAppearBeforeCompletion() {
        var state = ClipAgentState()
        state.phase = .ready
        XCTAssertEqual(state.expression(at: now), .idle)
        state.lastCompleted = now
        XCTAssertEqual(state.expression(at: now.addingTimeInterval(-0.01)), .idle)
        XCTAssertEqual(state.expression(at: now), .happy)
        XCTAssertEqual(state.expression(at: now.addingTimeInterval(1.99)), .happy)
        XCTAssertEqual(state.expression(at: now.addingTimeInterval(2)), .idle)
    }

    func testConnectionAndInstallationDoNotPretendToOrganizeMemory() {
        var state = ClipAgentState()
        state.lastCompleted = now
        for phase in [ClipAgentState.Phase.connecting, .installing] {
            state.phase = phase
            XCTAssertEqual(state.expression(at: now), .idle)
            XCTAssertTrue(state.busy)
        }
        state.phase = .disconnected
        XCTAssertEqual(state.expression(at: now), .asleep)
    }
}
