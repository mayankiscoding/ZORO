#if canImport(Speech)
import AVFAudio
import Foundation
import Speech

/// Apple speech recognition (SFSpeechRecognizer) with streamed partial results. On-device
/// recognition is required in strict private mode and preferred otherwise when the locale supports it.
/// Hindi on-device support varies by device and OS; `availability(locale:)` checks it at runtime.
public actor SFSpeechRecognizerEngine: SpeechRecognizing {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)

    public init() {}

    public func authorization() async -> SpeechAuthorization {
        Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    public func requestAuthorization() async -> SpeechAuthorization {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: Self.map($0)) }
        }
    }

    public func availability(locale: String) async -> RecognizerAvailability {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            return .unavailable("\(locale) is not supported")
        }
        guard r.isAvailable else { return .unavailable("speech recognition for \(locale) is not available right now") }
        return r.supportsOnDeviceRecognition ? .onDevice : .serverOnly
    }

    public func startUtterance(locale: String, onDeviceOnly: Bool) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        await cancel()
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)), r.isAvailable else {
            throw VoiceError.recognitionUnavailable(locales: [locale], onDeviceRequired: onDeviceOnly)
        }
        if onDeviceOnly, !r.supportsOnDeviceRecognition {
            throw VoiceError.recognitionUnavailable(locales: [locale], onDeviceRequired: true)
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = onDeviceOnly || r.supportsOnDeviceRecognition
        req.taskHint = .dictation
        req.addsPunctuation = true
        let (stream, continuation) = AsyncThrowingStream<TranscriptUpdate, Error>.makeStream()
        task = r.recognitionTask(with: req) { result, error in
            if let result {
                continuation.yield(TranscriptUpdate(text: result.bestTranscription.formattedString, isFinal: result.isFinal))
                if result.isFinal {
                    continuation.finish()
                    return
                }
            }
            if let error { continuation.finish(throwing: error) }
        }
        recognizer = r
        request = req
        return stream
    }

    public func append(_ pcm16: Data) async {
        guard let request, let format, !pcm16.isEmpty else { return }
        let frames = pcm16.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let channel = buffer.int16ChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(channel, base, frames * 2)
        }
        request.append(buffer)
    }

    public func endUtterance() async {
        request?.endAudio()
    }

    public func cancel() async {
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        recognizer = nil
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechAuthorization {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
#endif
