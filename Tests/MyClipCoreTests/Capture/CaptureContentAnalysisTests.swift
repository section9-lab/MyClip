import CoreGraphics
import XCTest
@testable import MyClipCore

final class CaptureContentAnalysisTests: XCTestCase {
    private func image(width: Int = 200, height: Int = 160, background: [UInt8] = [255, 255, 255, 255],
                       marks: [(CGRect, [UInt8])] = []) throws -> CGImage {
        var pixels = Array(repeating: background, count: width * height).flatMap { $0 }
        for (rect, color) in marks {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    for channel in 0..<4 { pixels[(y * width + x) * 4 + channel] = color[channel] }
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testUniformColorsHaveNoResidualRegions() throws {
        for color: [UInt8] in [[255, 255, 255, 255], [228, 229, 231, 255], [24, 24, 24, 255], [20, 180, 90, 255]] {
            let analysis = try XCTUnwrap(CaptureContentAnalysis(image: image(background: color)))
            XCTAssertTrue(analysis.isCandidate)
            XCTAssertEqual(analysis.backgroundRGB, Array(color.prefix(3)))
            XCTAssertEqual(analysis.backgroundFraction, 1)
            XCTAssertEqual(analysis.regions, [])
            XCTAssertFalse(analysis.regionsTruncated)
        }
    }

    func testBackgroundOnlyAnalysisSkipsRegionsWithoutChangingFraction() throws {
        let picture = try image(marks: [(CGRect(x: 10, y: 20, width: 8, height: 8), [0, 0, 0, 255])])
        let detailed = try XCTUnwrap(CaptureContentAnalysis(image: picture))
        let backgroundOnly = try XCTUnwrap(CaptureContentAnalysis(image: picture, analyzeRegions: false))
        XCTAssertFalse(detailed.regions.isEmpty)
        XCTAssertTrue(backgroundOnly.regions.isEmpty)
        XCTAssertEqual(backgroundOnly.backgroundFraction, detailed.backgroundFraction)
        XCTAssertEqual(backgroundOnly.backgroundRGB, detailed.backgroundRGB)
    }

    func testCandidateThresholdIncludesExactlyOnePercentForeground() throws {
        for (count, candidate) in [(200, true), (201, false)] {
            let marks = (0..<count).map { (CGRect(x: $0 % 200, y: $0 / 200, width: 1, height: 1), [UInt8](repeating: 0, count: 3) + [255]) }
            let analysis = try XCTUnwrap(CaptureContentAnalysis(image: image(width: 200, height: 100, marks: marks)))
            XCTAssertEqual(analysis.isCandidate, candidate)
            XCTAssertEqual(analysis.backgroundFraction, 1 - Double(count) / 20_000, accuracy: 0.000001)
            if !candidate { XCTAssertTrue(analysis.regions.isEmpty, "Only candidates need region analysis") }
        }
    }

    func testOneLevelOfContrastStillProducesARegion() throws {
        let rect = CGRect(x: 31, y: 42, width: 20, height: 3)
        let analysis = try XCTUnwrap(CaptureContentAnalysis(image: image(marks: [(rect, [254, 255, 255, 255])])))
        XCTAssertEqual(analysis.backgroundFraction, 1, "The coarse color tolerance may include faint content")
        let region = try XCTUnwrap(analysis.regions.first)
        XCTAssertEqual(region.bounds, rect)
        XCTAssertEqual(region.pixelCount, 60)
        XCTAssertEqual(region.maximumDifference, 1, "The precise pass must not reuse the coarse tolerance")
    }

    func testThinLineAndCornerPixelAreNotDiscarded() throws {
        let line = CGRect(x: 10, y: 100, width: 120, height: 1)
        let corner = CGRect(x: 199, y: 159, width: 1, height: 1)
        let analysis = try XCTUnwrap(CaptureContentAnalysis(image: image(marks: [(line, [80, 80, 80, 255]), (corner, [0, 0, 0, 255])])))
        XCTAssertTrue(analysis.isCandidate)
        XCTAssertEqual(analysis.regions.map(\.bounds), [line, corner])
        XCTAssertEqual(analysis.regions.map(\.pixelCount), [120, 1])
    }

    func testDiagonalPixelsUseEightNeighbourConnectivity() throws {
        let points = [(10, 11), (11, 12), (20, 30)]
        let marks = points.map { (CGRect(x: $0.0, y: $0.1, width: 1, height: 1), [UInt8(0), 0, 0, 255]) }
        let analysis = try XCTUnwrap(CaptureContentAnalysis(image: image(marks: marks)))
        XCTAssertEqual(analysis.regions.count, 2)
        XCTAssertEqual(analysis.regions[0].bounds, CGRect(x: 10, y: 11, width: 2, height: 2))
        XCTAssertEqual(analysis.regions[0].pixelCount, 2)
    }

    func testCallerSuppliesContentBoundsAndRegionsUseImageCoordinates() throws {
        let body = CGRect(x: 10, y: 20, width: 80, height: 90)
        let dot = CGRect(x: 60, y: 80, width: 2, height: 2)
        let picture = try image(marks: [(CGRect(x: 0, y: 0, width: 200, height: 20), [0, 0, 0, 255]), (dot, [0, 0, 0, 255])])
        let analysis = try XCTUnwrap(CaptureContentAnalysis(image: picture, contentBounds: body))
        XCTAssertTrue(analysis.isCandidate)
        XCTAssertEqual(analysis.regions.map(\.bounds), [dot])
        XCTAssertEqual(analysis.bounds, body)
        XCTAssertFalse(try XCTUnwrap(CaptureContentAnalysis(image: picture)).isCandidate, "There is no automatic top-edge crop")
    }

    func testSmallNumberRemainsInspectable() throws {
        let points = [(40, 50), (41, 50), (42, 50), (43, 50), (42, 51), (42, 52), (41, 53), (41, 54)]
        let marks = points.map { (CGRect(x: $0.0, y: $0.1, width: 1, height: 1), [UInt8(0), 0, 0, 255]) }
        let analysis = try XCTUnwrap(CaptureContentAnalysis(image: image(marks: marks)))
        XCTAssertTrue(analysis.isCandidate)
        XCTAssertEqual(analysis.regions.count, 1, "One region is still content that needs inspection")
        XCTAssertEqual(analysis.regions[0].bounds, CGRect(x: 40, y: 50, width: 4, height: 5))
        XCTAssertEqual(analysis.regions[0].pixelCount, 8)
    }

    func testBottomRightControlIsNotAutomaticallyIgnored() throws {
        let control = CGRect(x: 180, y: 145, width: 15, height: 8)
        let analysis = try XCTUnwrap(CaptureContentAnalysis(image: image(marks: [(control, [145, 145, 145, 255])])))
        XCTAssertTrue(analysis.isCandidate)
        XCTAssertEqual(analysis.regions.map(\.bounds), [control])
    }

    func testRegionLimitIsExplicitWhenFaintNoiseHasManyComponents() throws {
        let marks = (0..<300).map { (CGRect(x: ($0 % 90) * 2, y: ($0 / 90) * 2, width: 1, height: 1), [UInt8(254), 255, 255, 255]) }
        let analysis = try XCTUnwrap(CaptureContentAnalysis(image: image(marks: marks)))
        XCTAssertTrue(analysis.isCandidate)
        XCTAssertTrue(analysis.regionsTruncated)
        XCTAssertEqual(analysis.regions.count, 256)
    }

    func testTransparentImageIsNotTreatedAsAnOpaqueUniformBackground() throws {
        let analysis = try XCTUnwrap(CaptureContentAnalysis(image: image(background: [0, 0, 0, 0])))
        XCTAssertFalse(analysis.isCandidate)
    }

    func testInvalidContentBoundsReturnNoAnalysis() throws {
        let picture = try image()
        for bounds in [CGRect.zero, CGRect(x: -1, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 201, height: 160),
                       CGRect(x: 0.5, y: 0, width: 10, height: 10), CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            XCTAssertNil(CaptureContentAnalysis(image: picture, contentBounds: bounds))
        }
    }
}
