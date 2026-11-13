import Foundation
import ZoroCore

/// What the owner did with the orb or the talk button.
public enum VoiceGesture: Sendable, Equatable {
    case tap
    case holdBegan
    case holdEnded
}

/// What the shell asks the voice session to do.
public enum VoiceCommand: Sendable, Equatable {
    case start
    /// Abandon listening: nothing heard is sent.
    case stop
    /// End of the owner's utterance (hold-to-talk released): send what was heard.
    case finishListening
    /// Barge-in: stop speech and cancel the turn.
    case interrupt
    /// Barge-in followed by listening (hold while ZORO speaks or works).
    case interruptAndStart
    case none

    /// Tap-to-talk toggles; hold-to-talk listens while held and sends on release. Pure, so every pair is tested.
    public static func forGesture(_ gesture: VoiceGesture, in state: VoiceSessionState) -> VoiceCommand {
        switch (gesture, state) {
        case (.tap, .idle), (.tap, .private), (.tap, .error): .start
        case (.tap, .listening): .stop
        case (.tap, .processing), (.tap, .delegating), (.tap, .toolExecution), (.tap, .speaking): .interrupt
        case (.holdBegan, .idle), (.holdBegan, .private), (.holdBegan, .error): .start
        case (.holdBegan, .listening): .none
        case (.holdBegan, _): .interruptAndStart
        case (.holdEnded, .listening): .finishListening
        case (.holdEnded, _): .none
        }
    }
}

/// Permissions the shell primes before first use. Each feature package primes its own (Photos,
/// Health, Music); the shell handles the ones voice and approvals need.
public enum AppPermission: String, Sendable, CaseIterable, Identifiable {
    case microphone
    case speechRecognition
    case notifications

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .speechRecognition: "Speech recognition"
        case .notifications: "Notifications"
        }
    }

    /// The one sentence shown before the system prompt (voice-and-copy.md section 8).
    public var purpose: String {
        switch self {
        case .microphone: "ZORO listens only while the orb is listening, after you press or tap."
        case .speechRecognition: "Your words are turned into text on this device."
        case .notifications: "ZORO tells you when an approval is waiting or a task finishes."
        }
    }

    public var symbol: String {
        switch self {
        case .microphone: "mic"
        case .speechRecognition: "text.bubble"
        case .notifications: "bell"
        }
    }

    /// Shown when the owner turned the permission off.
    public var deniedMessage: String {
        switch self {
        case .microphone: "ZORO needs the microphone to hear you. Turn it on in Settings."
        case .speechRecognition: "Speech recognition is off for ZORO. Turn it on in Settings, or type instead."
        case .notifications: "Notifications are off for ZORO. Turn them on in Settings to hear about waiting approvals."
        }
    }
}

public enum PermissionStatus: String, Sendable, Equatable {
    case notDetermined, granted, denied, unavailable
}

/// Reads and requests system permissions. The system implementation is `SystemPermissionPriming`;
/// tests use a fake, so no test ever shows a system prompt.
public protocol PermissionPriming: Sendable {
    func status(of permission: AppPermission) async -> PermissionStatus
    /// Shows the system prompt (only when the status is `notDetermined`).
    func request(_ permission: AppPermission) async -> PermissionStatus
}

/// Where voice permissions stand before listening starts.
public enum VoicePermissionGate: Sendable, Equatable {
    case ready
    /// Show the purpose sentence, then ask.
    case prime(AppPermission)
    case denied(AppPermission)

    /// Microphone first, then speech recognition. Pure.
    public static func evaluate(microphone: PermissionStatus, speech: PermissionStatus) -> VoicePermissionGate {
        for (permission, status) in [(AppPermission.microphone, microphone), (.speechRecognition, speech)] {
            switch status {
            case .granted: continue
            case .notDetermined: return .prime(permission)
            case .denied, .unavailable: return .denied(permission)
            }
        }
        return .ready
    }
}

/// Supplies the facts suggestion chips are drawn from.
public protocol HomeContextProviding: Sendable {
    func suggestionContext() async -> SuggestionContext
}

/// Reads what the core API knows (waiting approvals). The shopping package can supply a provider
/// that adds the basket.
public struct APIHomeContext: HomeContextProviding {
    let api: any ZoroAPI
    public init(api: any ZoroAPI) { self.api = api }

    public func suggestionContext() async -> SuggestionContext {
        let approvals = (try? await api.pendingApprovals())?.count ?? 0
        return SuggestionContext(basketItemCount: nil, pendingApprovalCount: approvals)
    }
}
