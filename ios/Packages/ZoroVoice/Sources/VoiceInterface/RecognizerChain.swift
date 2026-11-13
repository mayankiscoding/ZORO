import Foundation

/// Tries a preferred recogniser (SpeechAnalyzer on 26 SDKs) and falls back to another
/// (SFSpeechRecognizer) per locale: whichever offers the better availability serves the utterance.
public actor RecognizerChain: SpeechRecognizing {
    private let primary: any SpeechRecognizing
    private let fallback: any SpeechRecognizing
    private var active: (any SpeechRecognizing)?
    /// True when the primary recogniser serves the current utterance (for diagnostics and tests).
    public private(set) var usingPrimary = false

    public init(primary: any SpeechRecognizing, fallback: any SpeechRecognizing) {
        self.primary = primary
        self.fallback = fallback
    }

    public func authorization() async -> SpeechAuthorization { await fallback.authorization() }
    public func requestAuthorization() async -> SpeechAuthorization { await fallback.requestAuthorization() }

    public func availability(locale: String) async -> RecognizerAvailability {
        let p = await primary.availability(locale: locale)
        if p == .onDevice { return p }
        let f = await fallback.availability(locale: locale)
        switch (p, f) {
        case (_, .onDevice): return .onDevice
        case (.serverOnly, _), (_, .serverOnly): return .serverOnly
        default: return f
        }
    }

    public func startUtterance(locale: String, onDeviceOnly: Bool) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        await active?.cancel()
        usingPrimary = await primary.availability(locale: locale) == .onDevice
        let chosen: any SpeechRecognizing = usingPrimary ? primary : fallback
        active = chosen
        return try await chosen.startUtterance(locale: locale, onDeviceOnly: onDeviceOnly)
    }

    public func append(_ pcm16: Data) async { await active?.append(pcm16) }
    public func endUtterance() async { await active?.endUtterance() }

    public func cancel() async {
        await active?.cancel()
        active = nil
        usingPrimary = false
    }
}
