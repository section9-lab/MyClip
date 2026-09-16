import XCTest
@testable import MyClipCore

final class CompositionTests: XCTestCase {
    func testACPProgressMessageBeforeFinalJSONIsNotTreatedAsMemory() throws {
        let text = "我会先检索相关记忆，再依据截图生成。\n{\"entries\":[{\"kind\":\"memory\",\"title\":\"验收\",\"body\":\"截图规则\",\"sourceIDs\":[\"00000000-0000-0000-0000-000000000001\"]}]}"
        let result = try KnowledgeComposer.parse(text)
        XCTAssertEqual(result.first?.body, "截图规则")
    }
    func testResultAllowsEntireJSONFenceAndEmptyResult() throws {
        let result = try KnowledgeComposer.parse("```json\n{\"entries\":[{\"kind\":\"wiki\",\"title\":\"标题\",\"body\":\"内容\",\"sourceIDs\":[\"00000000-0000-0000-0000-000000000001\"]}]}\n```")
        XCTAssertEqual(result.first?.title, "标题")
        XCTAssertEqual(try KnowledgeComposer.parse("{\"entries\":[]}").count, 0)
    }
    func testInvalidOutputIsNeverSilentlyCommitted() {
        for text in ["正在思考", "{\"entries\":[{\"kind\":\"other\"}]}", "前言 {\"entries\":[]} 后记", "{}"] {
            XCTAssertThrowsError(try KnowledgeComposer.parse(text))
        }
    }
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
