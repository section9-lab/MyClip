import CoreGraphics
import Foundation

/// Pixel evidence; callers choose the filtering policy. Bounds use original image pixels, with the origin at the top left.
/// Regions are inspected only when requested and for color candidates; an empty list alone does not establish blankness.
public struct CaptureContentAnalysis: Sendable {
    public struct Region: Sendable, Equatable {
        public let bounds: CGRect
        public let pixelCount: Int
        public let maximumDifference: UInt8
    }

    public let bounds: CGRect
    public let backgroundRGB: [UInt8]
    public let backgroundFraction: Double
    public let regions: [Region]
    public let regionsTruncated: Bool
    public var isCandidate: Bool { backgroundFraction >= 0.99 }

    /// No content-area crop or browser-control exclusion is inferred from the pixels.
    /// Invalid geometry or images above the capture pipeline's 4096 × 4096 pixel budget return nil.
    public init?(image: CGImage, contentBounds: CGRect? = nil, analyzeRegions: Bool = true) {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let body = contentBounds ?? imageBounds
        guard image.height > 0, image.width > 0, image.width <= 16_777_216 / image.height,
              body.origin.x.isFinite, body.origin.y.isFinite, body.width.isFinite, body.height.isFinite,
              body.width >= 1, body.height >= 1, body == body.integral, imageBounds.contains(body),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: imageBounds)

        let width = Int(body.width), height = Int(body.height), count = width * height
        let left = Int(body.minX), top = Int(body.minY)
        var histograms = Array(repeating: Array(repeating: 0, count: 256), count: 3)
        for y in 0..<height {
            for x in 0..<width {
                let offset = ((top + y) * image.width + left + x) * 4
                for channel in 0..<3 { histograms[channel][Int(pixels[offset + channel])] += 1 }
            }
        }
        let background: [UInt8] = histograms.map { histogram in
            var total = 0
            for value in 0..<256 {
                total += histogram[value]
                if total > (count - 1) / 2 { return UInt8(value) }
            }
            return 0
        }
        var differences = [UInt8](repeating: 0, count: count)
        var backgroundPixels = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = ((top + y) * image.width + left + x) * 4
                var difference = 255 - Int(pixels[offset + 3])
                for channel in 0..<3 { difference = max(difference, abs(Int(pixels[offset + channel]) - Int(background[channel]))) }
                differences[y * width + x] = UInt8(difference)
                if difference <= 6 { backgroundPixels += 1 }
            }
        }
        bounds = body
        backgroundRGB = background
        let fraction = Double(backgroundPixels) / Double(count)
        backgroundFraction = fraction
        guard analyzeRegions, fraction >= 0.99 else {
            regions = []; regionsTruncated = false
            return
        }

        // The coarse tolerance is deliberately absent here: a one-level difference or one pixel is still evidence.
        var found: [Region] = []
        var stack: [Int] = []
        var truncated = false
        for start in 0..<count where differences[start] != 0 {
            guard found.count < 256 else { truncated = true; break }
            var minX = start % width, maxX = minX, minY = start / width, maxY = minY
            var area = 0, maximum = differences[start]
            differences[start] = 0
            stack.append(start)
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                area += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for nextY in max(0, y - 1)...min(height - 1, y + 1) {
                    for nextX in max(0, x - 1)...min(width - 1, x + 1) {
                        let next = nextY * width + nextX
                        if differences[next] != 0 {
                            maximum = max(maximum, differences[next])
                            differences[next] = 0
                            stack.append(next)
                        }
                    }
                }
            }
            found.append(Region(bounds: CGRect(x: left + minX, y: top + minY, width: maxX - minX + 1, height: maxY - minY + 1),
                                pixelCount: area, maximumDifference: maximum))
        }
        regions = found
        regionsTruncated = truncated
    }
}
