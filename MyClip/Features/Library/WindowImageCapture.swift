import CoreImage
import ScreenCaptureKit
import MyClipCore

@MainActor
enum WindowImageCapture {
    static func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        return try await SingleFrameCapture().capture(filter: filter, configuration: configuration)
    }
}

// macOS 13 uses the same window/application filter with a one-frame stream.
@MainActor
private final class SingleFrameCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var timeout: Task<Void, Never>?

    func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                self.stream = stream
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "MyClip.Screenshot"))
                    Task {
                        do { try await stream.startCapture() }
                        catch { finish(.failure(error)) }
                    }
                    timeout = Task {
                        do { try await Task.sleep(for: .seconds(5)); finish(.failure(LibraryError.invalidImage)) }
                        catch { }
                    }
                } catch { finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        let source = CIImage(cvPixelBuffer: buffer)
        guard let image = CIContext().createCGImage(source, from: source.extent) else { return }
        Task { @MainActor in self.finish(.success(image)) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }

    private func finish(_ result: Result<CGImage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
        continuation.resume(with: result)
    }
}
