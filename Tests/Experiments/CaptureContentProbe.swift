import Foundation
import ImageIO

/// Offline runner compiled alongside CaptureContentAnalysis.swift. It never writes to the screenshot library.
@main
enum CaptureContentProbe {
    struct Sample: Decodable {
        let sample: String
        let path: String
        let contentBounds: [Double]?
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "CaptureContentProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: capture-content-probe manifest.json"])
        }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for (index, sample) in samples.enumerated() {
            let result: [String: Any] = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: sample.path) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    return ["sample": sample.sample, "status": "unavailable", "reason": "image"]
                }
                var bounds: CGRect?
                if let values = sample.contentBounds {
                    guard values.count == 4 else { return ["sample": sample.sample, "status": "unavailable", "reason": "bounds"] }
                    bounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                }
                let started = ProcessInfo.processInfo.systemUptime
                guard let analysis = CaptureContentAnalysis(image: image, contentBounds: bounds) else {
                    return ["sample": sample.sample, "status": "unavailable", "reason": "analysis"]
                }
                return ["sample": sample.sample,
                        "status": analysis.isCandidate ? (analysis.regions.isEmpty ? "uniform_candidate" : "candidate_with_regions") : "not_candidate",
                        "backgroundRGB": analysis.backgroundRGB,
                        "backgroundFraction": analysis.backgroundFraction,
                        "regionsTruncated": analysis.regionsTruncated,
                        "regions": analysis.regions.map { region in
                            ["bounds": [region.bounds.minX, region.bounds.minY, region.bounds.width, region.bounds.height],
                             "pixelCount": region.pixelCount, "maximumDifference": region.maximumDifference] as [String: Any]
                        },
                        "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000]
            }
            var line = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            line.append(10)
            try FileHandle.standardOutput.write(contentsOf: line)
            if (index + 1) % 100 == 0 {
                try FileHandle.standardError.write(contentsOf: Data("Analyzed \(index + 1)/\(samples.count)\n".utf8))
            }
        }
    }
}
