import CoreGraphics
import Foundation

/// A perceptual fingerprint of a screenshot made of 64 block-level dHashes (8 columns × 8 rows).
/// Two frames of the same window are compared block by block, so a blinking cursor or a ticking
/// clock touches one block while scrolled content touches most of them.
public struct BlockHash: Sendable, Equatable {
    public static let columns = 8
    public static let rows = 8
    /// Each block is sampled at 8×8 grey pixels and coded into 64 bits: 32 horizontal gradients, 16 vertical
    /// gradients and a 16-bit brightness thermometer, so a block that merely turns from light to dark still differs.
    static let blockWidth = 8
    static let blockHeight = 8
    public static let byteCount = columns * rows * 8
    /// Smaller images are compared pixel-exactly only; their blocks would be a handful of pixels each.
    public static let minimumSide = 256

    public let blocks: [UInt64]

    public init(image: CGImage) throws {
        let width = Self.columns * Self.blockWidth
        let height = Self.rows * Self.blockHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw LibraryError.invalidImage }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var blocks: [UInt64] = []
        blocks.reserveCapacity(Self.columns * Self.rows)
        for row in 0..<Self.rows {
            for column in 0..<Self.columns {
                func pixel(_ x: Int, _ y: Int) -> Int { Int(pixels[(row * Self.blockHeight + y) * width + column * Self.blockWidth + x]) }
                var bits: UInt64 = 0
                var sum = 0
                for y in 0..<Self.blockHeight {
                    for x in 0..<Self.blockWidth { sum += pixel(x, y) }
                    // 4 horizontal comparisons per row, pairs (0,1) (2,3) (4,5) (6,7).
                    for x in stride(from: 0, to: Self.blockWidth, by: 2) { bits = bits << 1 | (pixel(x, y) > pixel(x + 1, y) ? 1 : 0) }
                }
                // 16 vertical comparisons on a 4×4 lattice, pairs of rows (0,1) (2,3) (4,5) (6,7).
                for y in stride(from: 0, to: Self.blockHeight, by: 2) {
                    for x in stride(from: 0, to: Self.blockWidth, by: 2) { bits = bits << 1 | (pixel(x, y) > pixel(x, y + 1) ? 1 : 0) }
                }
                // Brightness as a thermometer code: hamming distance grows with the brightness change.
                let level = min(15, sum / (Self.blockWidth * Self.blockHeight) / 16)
                bits = bits << 16 | (level == 0 ? 0 : (UInt64(1) << UInt64(level)) - 1)
                blocks.append(bits)
            }
        }
        self.blocks = blocks
    }

    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        blocks = (0..<(Self.columns * Self.rows)).map { index in
            data[index * 8..<(index + 1) * 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
    }

    public init?(hex: String) {
        guard hex.count == Self.byteCount * 2 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(data: Data(bytes))
    }

    public var hex: String { data.map { String(format: "%02x", $0) }.joined() }

    public var data: Data {
        var result = Data(capacity: Self.byteCount)
        for block in blocks { for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8(truncatingIfNeeded: block >> UInt64(shift))) } }
        return result
    }

    /// Hamming distance per block, in row-major order.
    public func distances(to other: BlockHash) -> [Int] {
        zip(blocks, other.blocks).map { ($0 ^ $1).nonzeroBitCount }
    }

    public func compare(to other: BlockHash) -> BlockComparison { BlockComparison(distances: distances(to: other)) }
}

/// What changed between two frames of the same window, and what that means for storage.
public struct BlockComparison: Sendable, Equatable {
    public enum Verdict: String, Sendable { case identical, sameScene, localUpdate, newScene }

    /// Bits that may flip inside a block before it counts as changed (anti-aliasing, cursor, sub-pixel jitter).
    public static let blockNoise = 6
    /// Up to this many scattered changed blocks is still the same picture.
    public static let sameSceneBlocks = 3
    /// Changes confined to the outermost row/column (title bar, status bar, scroll bar) are still the same picture.
    public static let edgeBlocks = 12
    /// A single connected patch of up to this many blocks is a local update: a toast, a new line in a field.
    public static let localUpdateBlocks = 12

    public let distances: [Int]
    public let changedBlocks: [Int]

    public init(distances: [Int]) {
        self.distances = distances
        changedBlocks = distances.indices.filter { distances[$0] > Self.blockNoise }
    }

    public var verdict: Verdict {
        if changedBlocks.isEmpty { return distances.allSatisfy({ $0 == 0 }) ? .identical : .sameScene }
        if changedBlocks.count <= Self.sameSceneBlocks { return .sameScene }
        if changedBlocks.count <= Self.edgeBlocks, changedBlocks.allSatisfy(Self.isEdge) { return .sameScene }
        if changedBlocks.count <= Self.localUpdateBlocks, Self.isConnected(changedBlocks) { return .localUpdate }
        return .newScene
    }

    /// Bounding box of the change in block units (column, row, columns, rows), or nil when nothing changed.
    public var changedRegion: (x: Int, y: Int, width: Int, height: Int)? {
        guard !changedBlocks.isEmpty else { return nil }
        let xs = changedBlocks.map { $0 % BlockHash.columns }, ys = changedBlocks.map { $0 / BlockHash.columns }
        return (xs.min()!, ys.min()!, xs.max()! - xs.min()! + 1, ys.max()! - ys.min()! + 1)
    }

    private static func isEdge(_ index: Int) -> Bool {
        let x = index % BlockHash.columns, y = index / BlockHash.columns
        return x == 0 || y == 0 || x == BlockHash.columns - 1 || y == BlockHash.rows - 1
    }

    /// True when the blocks form one 4-connected component.
    static func isConnected(_ blocks: [Int]) -> Bool {
        guard let start = blocks.first else { return true }
        let set = Set(blocks)
        var seen: Set<Int> = [start]
        var stack = [start]
        while let index = stack.popLast() {
            let x = index % BlockHash.columns, y = index / BlockHash.columns
            let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                .filter { $0.0 >= 0 && $0.0 < BlockHash.columns && $0.1 >= 0 && $0.1 < BlockHash.rows }
                .map { $0.1 * BlockHash.columns + $0.0 }
            for neighbour in neighbours where set.contains(neighbour) && seen.insert(neighbour).inserted { stack.append(neighbour) }
        }
        return seen.count == set.count
    }
}
