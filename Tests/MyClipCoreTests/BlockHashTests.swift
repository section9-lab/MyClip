import CoreGraphics
import XCTest
@testable import MyClipCore

final class BlockHashTests: XCTestCase {
    /// A 720×640 "window": light background, dark text lines every 24px, a title bar on top.
    private func frame(_ draw: (CGContext) -> Void = { _ in }) throws -> CGImage {
        let width = 720, height = 640
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.96, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.85, alpha: 1)); context.fill(CGRect(x: 0, y: height - 40, width: width, height: 40))
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        for line in stride(from: 60, to: height - 80, by: 24) {
            context.fill(CGRect(x: 40, y: line, width: 300 + (line * 7) % 320, height: 10))
        }
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    func testIdenticalFramesHaveNoDistance() throws {
        let a = try BlockHash(image: frame()), b = try BlockHash(image: frame())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.compare(to: b).verdict, .identical)
    }

    func testCursorBlinkAndClockTickAreTheSameScene() throws {
        let base = try BlockHash(image: frame())
        let cursor = try BlockHash(image: frame { $0.setFillColor(CGColor(gray: 0.1, alpha: 1)); $0.fill(CGRect(x: 356, y: 300, width: 2, height: 14)) })
        let clock = try BlockHash(image: frame { $0.setFillColor(CGColor(gray: 0.3, alpha: 1)); $0.fill(CGRect(x: 640, y: 610, width: 50, height: 12)) })
        XCTAssertEqual(base.compare(to: cursor).verdict, .sameScene)
        XCTAssertEqual(base.compare(to: clock).verdict, .sameScene)
    }

    func testToastInACornerIsALocalUpdate() throws {
        let base = try BlockHash(image: frame())
        let toast = try BlockHash(image: frame {
            $0.setFillColor(CGColor(gray: 0.2, alpha: 1)); $0.fill(CGRect(x: 420, y: 60, width: 260, height: 120))
            $0.setFillColor(CGColor(gray: 0.95, alpha: 1)); $0.fill(CGRect(x: 440, y: 80, width: 220, height: 20))
        })
        let comparison = base.compare(to: toast)
        XCTAssertEqual(comparison.verdict, .localUpdate)
        let region = try XCTUnwrap(comparison.changedRegion)
        XCTAssertGreaterThanOrEqual(region.x, 4, "The change sits on the right-hand side")
    }

    func testScrolledContentIsANewScene() throws {
        let base = try BlockHash(image: frame())
        let scrolled = try BlockHash(image: frame {
            $0.setFillColor(CGColor(gray: 0.96, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 720, height: 600))
            $0.setFillColor(CGColor(gray: 0.15, alpha: 1))
            for line in stride(from: 72, to: 560, by: 24) { $0.fill(CGRect(x: 40, y: line, width: 320 + (line * 11) % 300, height: 10)) }
        })
        XCTAssertEqual(base.compare(to: scrolled).verdict, .newScene)
    }

    func testDifferentDocumentIsANewScene() throws {
        let base = try BlockHash(image: frame())
        let other = try BlockHash(image: frame { $0.setFillColor(CGColor(gray: 0.1, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 720, height: 600)) })
        XCTAssertEqual(base.compare(to: other).verdict, .newScene)
    }

    func testRoundTripsThroughData() throws {
        let hash = try BlockHash(image: frame())
        XCTAssertEqual(hash.data.count, BlockHash.byteCount)
        XCTAssertEqual(BlockHash(data: hash.data), hash)
        XCTAssertNil(BlockHash(data: Data(count: 10)))
    }

    func testConnectivity() {
        XCTAssertTrue(BlockComparison.isConnected([0, 1, 9]))
        XCTAssertFalse(BlockComparison.isConnected([0, 63]))
        XCTAssertTrue(BlockComparison.isConnected([]))
    }
}
