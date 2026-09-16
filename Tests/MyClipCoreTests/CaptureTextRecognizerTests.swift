import XCTest
import AppKit
@testable import MyClipCore

@MainActor
final class CaptureTextRecognizerTests: XCTestCase {
    func testRecognizesChineseAndEnglishFromScreenshotPixels() throws {
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
        let pixels = try CapturedImage(image: cgImage)
        let text = try XCTUnwrap(CaptureTextRecognizer.recognize(pixels.pngData))
        XCTAssertTrue(text.contains("MyClip"), text)
        XCTAssertTrue(text.contains("截图"), text)
    }
}
