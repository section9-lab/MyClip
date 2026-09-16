@preconcurrency import AVFAudio
import CoreMedia
import Foundation
@preconcurrency import Speech

/// Lightweight speech recognition result (text + timing).
struct SpeechSegment: Sendable {
    let text: String
    let isFinal: Bool
    let startTime: TimeInterval
    let duration: TimeInterval
}

@MainActor
final class SpeechTranscriptionService {
    typealias ResultHandler = @MainActor @Sendable (SpeechSegment) -> Void
    typealias ErrorHandler = @MainActor @Sendable (String) -> Void

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var currentFormat: AVAudioFormat?
    private var audioInputStreamer: AudioInputStreamer?

    func start(
        locale: Locale,
        onResult: @escaping ResultHandler,
        onError: @escaping ErrorHandler
    ) async throws {
        await stop()

        guard SpeechTranscriber.isAvailable else {
            throw SpeechTranscriptionError.transcriberUnavailable
        }

        let selectedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(
            locale: selectedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        let modules: [any SpeechModule] = [transcriber]
        let assetStatus = await AssetInventory.status(forModules: modules)
        switch assetStatus {
        case .installed:
            break
        case .supported:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        default:
            throw SpeechTranscriptionError.speechAssetsUnavailable(Self.assetStatusDescription(assetStatus))
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: inputFormat
        ) ?? inputFormat

        currentFormat = analysisFormat

        var streamContinuation: AsyncStream<AnalyzerInput>.Continuation?
        let inputSequence = AsyncStream<AnalyzerInput> { continuation in
            streamContinuation = continuation
            inputContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.inputContinuation = nil
                }
            }
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: analysisFormat)

        resultTask = Task.detached(priority: .userInitiated) {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let segment = SpeechSegment(
                        text: text,
                        isFinal: result.isFinal,
                        startTime: result.range.start.seconds,
                        duration: result.range.duration.seconds
                    )
                    await MainActor.run {
                        onResult(segment)
                    }
                }
            } catch {
                await MainActor.run {
                    onError(error.localizedDescription)
                }
            }
        }

        let audioInputStreamer = AudioInputStreamer(
            inputFormat: inputFormat,
            analysisFormat: analysisFormat,
            continuation: streamContinuation
        )
        self.audioInputStreamer = audioInputStreamer

        try startEngine(
            inputFormat: inputFormat,
            audioInputStreamer: audioInputStreamer
        )

        analyzerTask = Task.detached(priority: .userInitiated) {
            do {
                try await analyzer.start(inputSequence: inputSequence)
            } catch {
                await MainActor.run {
                    onError(error.localizedDescription)
                }
            }
        }
    }

    func stop() async {
        let analyzerToFinish = analyzer
        let analyzerTaskToAwait = analyzerTask
        let resultTaskToAwait = resultTask

        inputContinuation?.finish()
        inputContinuation = nil
        audioInputStreamer = nil

        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        if let analyzerToFinish {
            do {
                try await analyzerToFinish.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzerToFinish.cancelAndFinishNow()
            }
        }

        await analyzerTaskToAwait?.value
        await resultTaskToAwait?.value

        analyzerTask = nil
        resultTask = nil
        analyzer = nil
        currentFormat = nil
    }

    private func startEngine(
        inputFormat: AVAudioFormat,
        audioInputStreamer: AudioInputStreamer
    ) throws {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat,
            block: AudioInputTap.makeBlock(streamer: audioInputStreamer)
        )

        engine.prepare()
        try engine.start()
    }

    private static func assetStatusDescription(_ status: AssetInventory.Status) -> String {
        switch status {
        case .unsupported:
            "unsupported"
        case .supported:
            "supported"
        case .downloading:
            "downloading"
        case .installed:
            "installed"
        @unknown default:
            "unknown"
        }
    }
}

enum SpeechTranscriptionError: LocalizedError {
    case transcriberUnavailable
    case speechAssetsUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .transcriberUnavailable:
            "SpeechTranscriber is currently unavailable."
        case .speechAssetsUnavailable(let status):
            "Speech recognition assets are unavailable: \(status)."
        }
    }
}

private enum AudioInputTap {
    static func makeBlock(streamer: AudioInputStreamer) -> AVAudioNodeTapBlock {
        { buffer, _ in
            streamer.accept(buffer)
        }
    }
}

private final class AudioInputStreamer: @unchecked Sendable {
    private let inputFormat: AVAudioFormat
    private let analysisFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let continuation: AsyncStream<AnalyzerInput>.Continuation?
    private let lock = NSLock()
    private var inputStartTime = CMTime.zero

    init(
        inputFormat: AVAudioFormat,
        analysisFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation?
    ) {
        self.inputFormat = inputFormat
        self.analysisFormat = analysisFormat
        if inputFormat == analysisFormat {
            self.converter = nil
        } else {
            self.converter = AVAudioConverter(from: inputFormat, to: analysisFormat)
        }
        self.continuation = continuation
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer {
            lock.unlock()
        }

        let analyzerBuffer: AVAudioPCMBuffer?
        if inputFormat == analysisFormat {
            analyzerBuffer = buffer
        } else {
            analyzerBuffer = convert(buffer)
        }

        guard let analyzerBuffer else {
            return
        }

        let input = AnalyzerInput(buffer: analyzerBuffer, bufferStartTime: inputStartTime)
        inputStartTime = inputStartTime + CMTime(
            value: CMTimeValue(analyzerBuffer.frameLength),
            timescale: CMTimeScale(analysisFormat.sampleRate)
        )

        continuation?.yield(input)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else {
            return nil
        }

        let ratio = analysisFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        let provider = ConverterInputProvider(buffer: buffer)
        var conversionError: NSError?
        converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            provider.provideInput(outStatus)
        }

        return conversionError == nil ? convertedBuffer : nil
    }
}

private final class ConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provideInput(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if didProvideInput {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideInput = true
        outStatus.pointee = .haveData
        return buffer
    }
}
