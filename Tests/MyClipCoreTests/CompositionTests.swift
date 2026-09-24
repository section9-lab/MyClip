import XCTest
@testable import MyClipCore

final class CompositionTests: XCTestCase {
    func testFocusMatchesOwnerAndFrameRatherThanMouseLocation() {
        let frame = CGRect(x: 100, y: 40, width: 800, height: 600)
        let windows = [WindowCandidate(id: 1, processID: 2, frame: frame, title: "Notes"),
                       WindowCandidate(id: 2, processID: 3, frame: frame, title: "Notes")]
        XCTAssertEqual(FocusedWindowMatcher.match(processID: 3, frame: frame, title: "Notes", candidates: windows), 2)
        XCTAssertNil(FocusedWindowMatcher.match(processID: 4, frame: frame, title: "Notes", candidates: windows))
    }
    func testAmbiguousOrChangedWindowNeverFallsBackToDesktop() {
        let frame = CGRect(x: 100, y: 40, width: 800, height: 600)
        let windows = [WindowCandidate(id: 1, processID: 3, frame: frame, title: "Notes"),
                       WindowCandidate(id: 2, processID: 3, frame: frame, title: "Notes")]
        XCTAssertNil(FocusedWindowMatcher.match(processID: 3, frame: frame, title: "Notes", candidates: windows))
        XCTAssertNil(FocusedWindowMatcher.match(processID: 3, frame: frame.offsetBy(dx: 100, dy: 0), title: "Notes", candidates: windows))
        XCTAssertNil(FocusedWindowMatcher.match(processID: 3, frame: frame, title: "Changed", candidates: windows))
    }
}
