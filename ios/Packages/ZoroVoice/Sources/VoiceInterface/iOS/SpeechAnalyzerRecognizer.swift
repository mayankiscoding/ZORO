// UNVERIFIED-ON-HOST
// SpeechAnalyzer / SpeechTranscriber are new in the 26 SDKs (iOS 26, macOS 26); this host has Swift
// 6.1 and the macOS 15 SDK, so the file is not compiled here. Declarations checked against
// developer.apple.com documentation JSON (2026-11-13): SpeechTranscriber.isAvailable,
// supportedLocale(equivalentTo:) async, installedLocales async,
// init(locale:transcriptionOptions:reportingOptions:attributeOptions:), ReportingOption.volatileResults,
// results (AsyncSequence of Result; Result.text: AttributedString, isFinal via SpeechModuleResult),
// SpeechAnalyzer(modules:options:), bestAvailableAudioFormat(compatibleWith:) async,
// start(inputSequence:) async throws, finalizeAndFinishThroughEndOfInput() async throws,
// cancelAndFinishNow() async, AnalyzerInput(buffer: AVAudioPCMBuffer).
// Hindi (hi-IN) support is not documented; availability is checked at runtime and the session falls
// back to SFSpeechRecognizer.
#if compiler(>=6.2) && canImport(Speech)
import AVFAudio
import Foundation
import Speech

@available(iOS 26.0, macOS 26.0, *)
public actor SpeechAnalyzerRecognizer: SpeechRecognizing {
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)

    public init() {}

    public static var isSupported: Bool { SpeechTranscriber.isAvailable }

    public func authorization() async -> SpeechAuthorization {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    public func requestAuthorization() async -> SpeechAuthorization {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized ? .authorized : (status == .restricted ? .restricted : .denied))
            }
        }
    }

    /// On-device only: a locale counts as available once its model is installed.
    public func availability(locale: String) async -> RecognizerAvailability {
        guard SpeechTranscriber.isAvailable else { return .unavailable("SpeechTranscriber is not available on this device") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            return .unavailable("\(locale) is not supported")
        }
        let installed = await SpeechTranscriber.installedLocales
        let id = supported.identifier(.bcp47)
        return installed.contains { $0.identifier(.bcp47) == id } ? .onDevice : .unavailable("the \(locale) speech model is not installed")
    }

    public func startUtterance(locale: String, onDeviceOnly: Bool) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        await cancel()
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw VoiceError.recognitionUnavailable(locales: [locale], onDeviceRequired: true)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        converter = nil
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputStream)
        self.analyzer = analyzer
        self.input = inputContinuation

        let (stream, continuation) = AsyncThrowingStream<TranscriptUpdate, Error>.makeStream()
        resultsTask = Task {
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        continuation.yield(TranscriptUpdate(text: finalized, isFinal: false))
                    } else {
                        continuation.yield(TranscriptUpdate(text: finalized + text, isFinal: false))
                    }
                }
                continuation.yield(TranscriptUpdate(text: finalized, isFinal: true))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    public func append(_ pcm16: Data) async {
        guard let input, let sourceFormat, !pcm16.isEmpty else { return }
        let frames = pcm16.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)),
            let channel = buffer.int16ChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(channel, base, frames * 2) }
        }
        input.yield(AnalyzerInput(buffer: convert(buffer) ?? buffer))
    }

    public func endUtterance() async {
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    }

    public func cancel() async {
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = analyzerFormat, target != buffer.format else { return nil }
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: target) }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }
}
#endif
