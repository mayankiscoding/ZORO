#if canImport(AVFoundation)
import AVFoundation
import Foundation
import ZoroCore

/// AVSpeechSynthesizer, one sentence per `speak` call, events from its delegate.
public final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var current: (utterance: AVSpeechUtterance, continuation: AsyncStream<SynthesisEvent>.Continuation)?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func availableVoices() async -> [SpeechVoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            let gender: VoiceSettings.Gender? =
                switch v.gender {
                case .male: .male
                case .female: .female
                default: nil
                }
            let quality: Int =
                switch v.quality {
                case .enhanced: 1
                case .premium: 2
                default: 0
                }
            return SpeechVoiceDescriptor(id: v.identifier, name: v.name, language: v.language, gender: gender, quality: quality)
        }
    }

    public func speak(_ request: SpeechUtteranceRequest) async -> AsyncStream<SynthesisEvent> {
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = request.voiceId.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: request.language)
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, request.rate))
        utterance.pitchMultiplier = request.pitch
        utterance.postUtteranceDelay = 0
        let (stream, continuation) = AsyncStream<SynthesisEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let previous = lock.withLock {
            let p = current
            current = (utterance, continuation)
            return p
        }
        if let previous {
            previous.continuation.yield(.cancelled)
            previous.continuation.finish()
        }
        synthesizer.speak(utterance)
        return stream
    }

    public func stop() async {
        synthesizer.stopSpeaking(at: .immediate)
        let previous = lock.withLock {
            let p = current
            current = nil
            return p
        }
        previous?.continuation.yield(.cancelled)
        previous?.continuation.finish()
    }

    private func send(_ event: SynthesisEvent, for utterance: AVSpeechUtterance, finish: Bool) {
        let target: AsyncStream<SynthesisEvent>.Continuation? = lock.withLock {
            guard let c = current, c.utterance === utterance else { return nil }
            if finish { current = nil }
            return c.continuation
        }
        target?.yield(event)
        if finish { target?.finish() }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        send(.started, for: utterance, finish: false)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        send(.word, for: utterance, finish: false)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        send(.finished, for: utterance, finish: true)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        send(.cancelled, for: utterance, finish: true)
    }
}
#endif
