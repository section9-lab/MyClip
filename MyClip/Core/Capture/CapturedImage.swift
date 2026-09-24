import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

public struct CapturedImage: Sendable {
    public let pngData: Data
    public let fingerprint: String
    public let width: Int
    public let height: Int
    /// Perceptual fingerprint for near-duplicate detection; nil below `BlockHash.minimumSide` where blocks are meaningless.
    public let blockHash: BlockHash?

    /// Applies automatic-capture filtering before PNG encoding, hashing, OCR or persistence.
    public static func prepare(image: CGImage, settings: CaptureSettings, reason: CaptureReason) throws -> CapturedImage? {
        if settings.filterStrategies.contains(.nearUniformImages), reason != .manual {
            // Match the validated window-corpus geometry; full-display captures keep their entire frame.
            let top = settings.scope == .focusedWindow ? Int(Double(image.height) * 0.085) : 0
            let body = CGRect(x: 0, y: top, width: image.width, height: image.height - top)
            if let analysis = CaptureContentAnalysis(image: image, contentBounds: body, analyzeRegions: false),
               analysis.backgroundFraction >= 0.98 { return nil }
        }
        return try CapturedImage(image: image)
    }

    public init(image: CGImage) throws {
        guard image.width > 0, image.height > 0, image.width * image.height <= 80_000_000,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data else { throw LibraryError.invalidImage }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var hash = SHA256()
        hash.update(data: Data("\(image.width)x\(image.height):".utf8))
        hash.update(data: Data(bytes: bytes, count: image.width * image.height * 4))
        fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let output = NSMutableData()
        guard let normalized = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw LibraryError.invalidImage }
        CGImageDestinationAddImage(destination, normalized, nil)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalidImage }
        pngData = output as Data
        width = image.width
        height = image.height
        blockHash = image.width >= BlockHash.minimumSide && image.height >= BlockHash.minimumSide ? try BlockHash(image: normalized) : nil
    }
}
