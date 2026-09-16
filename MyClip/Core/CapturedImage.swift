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
    }
}
