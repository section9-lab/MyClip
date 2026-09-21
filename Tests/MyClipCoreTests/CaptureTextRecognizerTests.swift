import XCTest
import AppKit
@testable import MyClipCore

@MainActor
final class CaptureTextRecognizerTests: XCTestCase {
    func testScreenshotDocumentIsRecognizedFromPixelsAndSearchable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try textImage()
        let store = try LibraryStore(root: root)
        let context = fixtureContext()
        try await store.record(image: image, context: context, agent: .codex, organize: false)
        let pending = try await store.nextImageForTextIndex()
        XCTAssertEqual(pending?.id, image.fingerprint)
        async let first = store.recognizeImageText(id: image.fingerprint)
        async let repeated = store.recognizeImageText(id: image.fingerprint)
        let (text, sharedText) = try await (first, repeated)
        XCTAssertEqual(text, sharedText)
        XCTAssertTrue(text.contains("MyClip"), text)
        XCTAssertTrue(text.contains("截图"), text)
        let captures = try await store.captures(ids: [context.id])
        let capture = try XCTUnwrap(captures.first)
        XCTAssertEqual(try String(contentsOf: capture.textURL, encoding: .utf8), text)
        let results = try await store.snapshot(query: "MyClip")
        XCTAssertEqual(results.captures.map(\.id), [context.id])
        let next = try await store.nextImageForTextIndex()
        XCTAssertNil(next)
    }

    func testFailedRecognitionCanRetryWithoutBlockingOtherImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let image = try fixtureImage()
        let other = try fixtureImage(changed: true)
        try await store.record(image: image, context: fixtureContext(), agent: .codex, organize: false)
        try await store.record(image: other, context: fixtureContext(at: 200), agent: .codex, organize: false)
        let url = root.appendingPathComponent("Images/\(image.fingerprint).png")
        try Data("not an image".utf8).write(to: url)
        do {
            _ = try await store.recognizeImageText(id: image.fingerprint)
            XCTFail("Invalid pixels must fail rather than produce an empty document")
        } catch LibraryError.textRecognitionFailed { }
        let needsIndex = try await store.imageNeedsTextIndex(image.fingerprint)
        XCTAssertTrue(needsIndex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("txt").path))
        let next = try await store.nextImageForTextIndex(excluding: [image.fingerprint])
        XCTAssertEqual(next?.id, other.fingerprint)
        try image.pngData.write(to: url)
        let retried = try await store.recognizeImageText(id: image.fingerprint)
        XCTAssertEqual(retried, "")
    }

    func testExpiredScreenshotDoesNotProduceDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let image = try fixtureImage()
        try await store.record(image: image, context: fixtureContext(), agent: .codex, organize: false)
        try await store.expireImages(before: Date(timeIntervalSince1970: 500))
        do {
            _ = try await store.recognizeImageText(id: image.fingerprint)
            XCTFail("Expired screenshots must stay expired")
        } catch LibraryError.missingSource { }
    }

    func testRecognizesChineseAndEnglishFromScreenshotPixels() throws {
        let pixels = try textImage()
        let text = try XCTUnwrap(CaptureTextRecognizer.recognize(pixels.pngData))
        XCTAssertTrue(text.contains("MyClip"), text)
        XCTAssertTrue(text.contains("截图"), text)
    }

    private func textImage() throws -> CapturedImage {
        let image = NSImage(size: NSSize(width: 800, height: 200), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("MyClip 中文截图检索" as NSString).draw(at: NSPoint(x: 40, y: 70), withAttributes: [
                .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black
            ])
            return true
        }
        var rect = NSRect(x: 0, y: 0, width: 800, height: 200)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        return try CapturedImage(image: cgImage)
    }
}
