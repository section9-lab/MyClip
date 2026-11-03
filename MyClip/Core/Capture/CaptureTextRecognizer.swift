import Foundation
import Vision

public enum CaptureTextRecognitionLevel: Sendable { case fast, accurate }

public enum CaptureTextRecognizer {
    public static func recognize(_ data: Data, level: CaptureTextRecognitionLevel = .accurate) -> String? {
        autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = level == .fast ? .fast : .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.automaticallyDetectsLanguage = level == .accurate
            request.usesLanguageCorrection = level == .accurate
            do {
                try VNImageRequestHandler(data: data).perform([request])
                return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n").prefix(128_000))
            } catch { return nil }
        }
    }
}
