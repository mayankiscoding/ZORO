import Foundation
import ZoroCore

// MARK: - Speech recognition

public struct TranscriptUpdate: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public enum RecognizerAvailability: Sendable, Equatable {
    /// Recognition runs entirely on this device.
    case onDevice
    /// Only Apple's server recognition supports this locale (not allowed in strict private mode).
    case serverOnly
    case unavailable(String)
}

public enum SpeechAuthorization: String, Sendable, Equatable {
    case notDetermined, denied, restricted, authorized
}

/// One utterance at a time: start, feed 16 kHz mono PCM16, end, read partial and final text.
public protocol SpeechRecognizing: Sendable {
    func authorization() async -> SpeechAuthorization
    /// Shows the system prompt when not determined; call only from a user action.
    func requestAuthorization() async -> SpeechAuthorization
    func availability(locale: String) async -> RecognizerAvailability
    func startUtterance(locale: String, onDeviceOnly: Bool) async throws -> AsyncThrowingStream<TranscriptUpdate, Error>
    func append(_ pcm16: Data) async
    /// No more audio: the recogniser delivers its final result and finishes the stream.
    func endUtterance() async
    func cancel() async
}

// MARK: - Speech synthesis

public struct SpeechUtteranceRequest: Sendable, Equatable {
    public var text: String
    public var language: String
    public var voiceId: String?
    public var rate: Float
    public var pitch: Float
    public init(text: String, language: String, voiceId: String?, rate: Float, pitch: Float) {
        self.text = text
        self.language = language
        self.voiceId = voiceId
        self.rate = rate
        self.pitch = pitch
    }
}

public enum SynthesisEvent: String, Sendable, Equatable {
    case started, word, finished, cancelled
}

public protocol SpeechSynthesizing: Sendable {
    func availableVoices() async -> [SpeechVoiceDescriptor]
    /// Speaks one sentence; the stream ends after `.finished` or `.cancelled`.
    func speak(_ request: SpeechUtteranceRequest) async -> AsyncStream<SynthesisEvent>
    /// Stops at once (barge-in); the current stream ends with `.cancelled`.
    func stop() async
}

// MARK: - Backend

/// The slice of the backend a voice session needs.
public protocol VoiceBackend: Sendable {
    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error>
    func cancelTurn(id: String) async throws
    /// `POST /v1/voice/live-session`.
    func liveSessionGrant() async throws -> LiveSessionGrant
}

/// Monotonic time and sleeping, injectable for tests.
public protocol VoiceClock: Sendable {
    func now() -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemVoiceClock: VoiceClock {
    private let origin = ContinuousClock.now
    public init() {}
    public func now() -> TimeInterval {
        let d = ContinuousClock.now - origin
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .milliseconds(Int(max(0, seconds) * 1000)))
    }
}

// MARK: - Errors

public enum VoiceError: Error, Sendable, Equatable, LocalizedError {
    case microphoneDenied
    case speechRecognitionDenied
    case recognitionUnavailable(locales: [String], onDeviceRequired: Bool)
    case audio(String)
    /// The ZORO server could not be reached; retrying may work.
    case network(String)
    case turnFailed(TurnError)
    case liveSession(String)
    case backend(ZoroError)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "ZORO can't use the microphone. Allow it in Settings, then tap the orb again."
        case .speechRecognitionDenied: "Speech recognition is off for ZORO. Allow it in Settings, or type instead."
        case .recognitionUnavailable(let locales, let onDevice):
            onDevice
                ? "On-device speech recognition isn't available here for \(locales.joined(separator: ", ")). Type instead, or switch to cloud mode."
                : "Speech recognition isn't available for \(locales.joined(separator: ", ")). Type instead."
        case .audio(let m): "Audio stopped working: \(m). Tap the orb to try again."
        case .network: "Couldn't reach your ZORO server. Check the connection, then try again."
        case .turnFailed(let e): e.message
        case .liveSession: "Cloud voice disconnected. ZORO switched to on-device voice."
        case .backend(let e): e.errorDescription
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .network, .liveSession: true
        case .turnFailed(let e): e.retryable
        case .backend(let e): e.isRetryable
        default: false
        }
    }

    public static func from(_ error: Error) -> VoiceError {
        if let v = error as? VoiceError { return v }
        let z = ZoroError.wrap(error)
        switch z {
        case .transport(let m): return .network(m)
        case .timeout: return .network("timed out")
        case .turnFailed(let e): return .turnFailed(e)
        default: return .backend(z)
        }
    }
}

// MARK: - Session events for the UI

public enum VoiceSessionEvent: Sendable, Equatable {
    case phase(VoicePhase)
    case engine(VoiceEngineKind, fallback: EngineFallbackReason?)
    case listeningLocale(String)
    case partialTranscript(String)
    case finalTranscript(String, language: SpokenLanguage)
    /// Reply text as it streams (both engines).
    case replyText(String)
    /// Every backend turn event, for cards, approvals and agent activity.
    case turn(TurnEvent)
    case latency(TurnLatency)
    case error(VoiceError)
}
