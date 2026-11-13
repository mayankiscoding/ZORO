import Foundation
import ZoroCore

/// Latency of one voice turn, in seconds. Measured, never promised.
public struct TurnLatency: Sendable, Equatable {
    public var engine: VoiceEngineKind
    /// Owner starts speaking → first partial transcript on screen.
    public var firstPartial: TimeInterval?
    /// Owner stops speaking → first sign of work (turn event or model output).
    public var firstFeedback: TimeInterval?
    /// Owner stops speaking → first reply audio.
    public var firstAudio: TimeInterval?
    /// Owner stops speaking → reply finished.
    public var roundTrip: TimeInterval?

    public init(engine: VoiceEngineKind, firstPartial: TimeInterval? = nil, firstFeedback: TimeInterval? = nil, firstAudio: TimeInterval? = nil, roundTrip: TimeInterval? = nil) {
        self.engine = engine
        self.firstPartial = firstPartial
        self.firstFeedback = firstFeedback
        self.firstAudio = firstAudio
        self.roundTrip = roundTrip
    }
}

/// Collects the marks of one turn. Each mark is recorded once; later marks of the same kind are ignored.
public struct LatencyTracker: Sendable, Equatable {
    public private(set) var listeningStart: TimeInterval?
    public private(set) var speechStart: TimeInterval?
    public private(set) var firstPartial: TimeInterval?
    public private(set) var utteranceEnd: TimeInterval?
    public private(set) var firstFeedback: TimeInterval?
    public private(set) var firstAudio: TimeInterval?

    public init() {}

    public mutating func markListening(_ t: TimeInterval) { if listeningStart == nil { listeningStart = t } }
    public mutating func markSpeechStart(_ t: TimeInterval) { if speechStart == nil { speechStart = t } }
    public mutating func markPartial(_ t: TimeInterval) { if firstPartial == nil { firstPartial = t } }
    public mutating func markUtteranceEnd(_ t: TimeInterval) { if utteranceEnd == nil { utteranceEnd = t } }
    public mutating func markFeedback(_ t: TimeInterval) { if utteranceEnd != nil, firstFeedback == nil { firstFeedback = t } }
    public mutating func markFirstAudio(_ t: TimeInterval) {
        guard firstAudio == nil else { return }
        if utteranceEnd == nil { utteranceEnd = t }
        firstAudio = t
        markFeedback(t)
    }

    public var hasUtterance: Bool { utteranceEnd != nil }

    public func complete(at t: TimeInterval, engine: VoiceEngineKind) -> TurnLatency {
        func since(_ a: TimeInterval?, _ b: TimeInterval?) -> TimeInterval? {
            guard let a, let b else { return nil }
            return max(0, b - a)
        }
        return TurnLatency(
            engine: engine,
            firstPartial: since(speechStart ?? listeningStart, firstPartial),
            firstFeedback: since(utteranceEnd, firstFeedback),
            firstAudio: since(utteranceEnd, firstAudio),
            roundTrip: since(utteranceEnd, t))
    }

    public mutating func reset() { self = LatencyTracker() }
}

/// Rolling summary of recent turns (medians, so one slow network turn does not hide the norm).
public struct LatencySummary: Sendable, Equatable {
    public var turns: Int
    public var medianFirstPartial: TimeInterval?
    public var medianFirstFeedback: TimeInterval?
    public var medianFirstAudio: TimeInterval?
    public var medianRoundTrip: TimeInterval?

    public init(_ samples: [TurnLatency]) {
        turns = samples.count
        medianFirstPartial = Self.median(samples.compactMap(\.firstPartial))
        medianFirstFeedback = Self.median(samples.compactMap(\.firstFeedback))
        medianFirstAudio = Self.median(samples.compactMap(\.firstAudio))
        medianRoundTrip = Self.median(samples.compactMap(\.roundTrip))
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}
