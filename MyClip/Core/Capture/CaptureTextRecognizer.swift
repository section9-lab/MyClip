import Foundation
import Vision

public enum CaptureTextRecognizer {
    public static func recognize(_ data: Data) -> String? {
        autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(data: data).perform([request])
                return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(128_000))
            } catch { return nil }
        }
    }
}
