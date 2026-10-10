import CoreGraphics
import XCTest
@testable import MyClipCore

final class CapturePreparationTests: XCTestCase {
    private func image(foregroundPixels: Int = 0, background: [UInt8] = [255, 255, 255, 255],
                       foreground: [UInt8] = [0, 0, 0, 255], toolbar: Bool = true) throws -> CGImage {
        let width = 200, height = 200, top = 17
        var pixels = Array(repeating: background, count: width * height).flatMap { $0 }
        for index in 0..<(top * width + foregroundPixels) {
            guard index >= top * width || toolbar else { continue }
            let color: [UInt8] = index < top * width ? [20, 20, 20, 255] : foreground
            for channel in 0..<4 { pixels[index * 4 + channel] = color[channel] }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testWindowFilterIncludesExactly98PercentBackground() throws {
        let settings = CaptureSettings(filterStrategies: [.nearUniformImages])
        // Removing the 17-row toolbar leaves 36,600 pixels; 732 are exactly 2%.
        XCTAssertNil(try CapturedImage.prepare(image: image(foregroundPixels: 732), settings: settings, reason: .enter))
        XCTAssertNotNil(try CapturedImage.prepare(image: image(foregroundPixels: 733), settings: settings, reason: .enter))
    }

    func testSparseContentDoesNotVetoFilteringForAutomaticTriggers() throws {
        let settings = CaptureSettings(filterStrategies: [.nearUniformImages])
        for color: [UInt8] in [[255, 255, 255, 255], [228, 229, 231, 255], [24, 24, 24, 255], [0, 0, 0, 255]] {
            for reason: CaptureReason in [.enter, .clickAfterIdle, .scrollIdle] {
                XCTAssertNil(try CapturedImage.prepare(image: image(foregroundPixels: 8, background: color), settings: settings, reason: reason))
            }
        }
    }

    func testDisabledFilterAndManualCapturePreserveImages() throws {
        let picture = try image()
        XCTAssertNotNil(try CapturedImage.prepare(image: picture, settings: CaptureSettings(filterStrategies: [.similarImages]), reason: .enter))
        XCTAssertNotNil(try CapturedImage.prepare(image: picture, settings: CaptureSettings(filterStrategies: [.nearUniformImages]), reason: .manual))
    }

    func testDisplayCaptureUsesEntireImage() throws {
        let settings = CaptureSettings(scope: .focusedDisplay, filterStrategies: [.nearUniformImages])
        XCTAssertNotNil(try CapturedImage.prepare(image: image(), settings: settings, reason: .enter))
        XCTAssertNil(try CapturedImage.prepare(image: image(toolbar: false), settings: settings, reason: .enter))
    }

    func testBackgroundToleranceIsSixColorLevels() throws {
        let settings = CaptureSettings(filterStrategies: [.nearUniformImages])
        XCTAssertNil(try CapturedImage.prepare(image: image(foregroundPixels: 1000, foreground: [249, 249, 249, 255]), settings: settings, reason: .enter))
        XCTAssertNotNil(try CapturedImage.prepare(image: image(foregroundPixels: 1000, foreground: [248, 248, 248, 255]), settings: settings, reason: .enter))
    }
}
