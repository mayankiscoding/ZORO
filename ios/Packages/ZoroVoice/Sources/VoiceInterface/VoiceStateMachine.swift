import Foundation
import ZoroCore

/// The voice session's phases (design spec section 9). `privateOffline` is the resting phase of a
/// strict-private session between turns: nothing is listening, and nothing leaves the owner's devices
/// except the turn to their own server. It is shown as ZoroCore's `.private` (moonstone orb).
public enum VoicePhase: String, Sendable, CaseIterable, Equatable {
    case idle, listening, processing, delegating, toolExecution, speaking, error, privateOffline

    public var sessionState: VoiceSessionState {
        switch self {
        case .idle: .idle
        case .listening: .listening
        case .processing: .processing
        case .delegating: .delegating
        case .toolExecution: .toolExecution
        case .speaking: .speaking
        case .error: .error
        case .privateOffline: .private
        }
    }

    /// A turn is in flight or being spoken.
    public var isBusy: Bool {
        switch self {
        case .processing, .delegating, .toolExecution, .speaking: true
        default: false
        }
    }

    public var isResting: Bool { self == .idle || self == .privateOffline || self == .error }
}

public enum VoiceTrigger: Sendable, Equatable {
    case start
    case stop
    /// The owner's utterance is final and was sent as a turn.
    case utteranceSubmitted
    /// Route decided or an agent started.
    case agentsWorking
    case toolStarted
    case toolFinished(agentsStillWorking: Bool)
    /// The first reply audio (system speech or model audio) started.
    case replyAudioStarted
    /// The reply finished (spoken to the end, or a turn with nothing to say).
    case replyFinished
    /// The owner spoke over the reply, or `interrupt()`.
    case bargeIn
    case failed
    /// The error was shown; settle.
    case recovered
}

/// The full transition table (pure). `rest` is where the session settles after a reply or an error:
/// `.listening` for a continuing session (cloud, wake phrase), `.privateOffline` in strict private
/// mode, otherwise `.idle`. Returns nil when the trigger does not apply in this phase.
public enum VoiceStateMachine {
    public static func next(_ phase: VoicePhase, _ trigger: VoiceTrigger, rest: VoicePhase) -> VoicePhase? {
        switch (trigger, phase) {
        case (.stop, .idle): return nil
        case (.stop, _): return .idle
        case (.failed, .error): return nil
        case (.failed, _): return .error

        case (.start, .idle), (.start, .privateOffline), (.start, .error): return .listening
        case (.start, _): return nil

        case (.utteranceSubmitted, .listening): return .processing
        case (.utteranceSubmitted, _): return nil

        case (.agentsWorking, .processing), (.agentsWorking, .toolExecution): return .delegating
        case (.agentsWorking, _): return nil

        case (.toolStarted, .processing), (.toolStarted, .delegating): return .toolExecution
        case (.toolStarted, _): return nil

        case (.toolFinished(let still), .toolExecution): return still ? .delegating : .processing
        case (.toolFinished, _): return nil

        // The realtime model may answer straight from listening.
        case (.replyAudioStarted, .listening), (.replyAudioStarted, .processing), (.replyAudioStarted, .delegating),
            (.replyAudioStarted, .toolExecution):
            return .speaking
        case (.replyAudioStarted, _): return nil

        case (.replyFinished, let p) where p.isBusy: return rest
        case (.replyFinished, _): return nil

        case (.bargeIn, let p) where p.isBusy: return .listening
        case (.bargeIn, _): return nil

        case (.recovered, .error): return rest == .listening ? .listening : rest
        case (.recovered, _): return nil
        }
    }
}
