import Foundation
import ZoroCore

/// Why a session runs on the on-device engine.
public enum EngineFallbackReason: String, Sendable, Equatable {
    /// Strict private mode: no audio leaves for an external model.
    case privateMode = "private_mode"
    /// The owner chose the on-device engine.
    case onDeviceChosen = "on_device_chosen"
    /// The backend could not mint a live session (no key, provider down, offline).
    case cloudUnavailable = "cloud_unavailable"
    /// The realtime socket failed and could not be resumed.
    case socketFailed = "socket_failed"
}

public enum EnginePlan: Sendable, Equatable {
    case onDevice(EngineFallbackReason)
    case attemptCloud
}

public enum EngineDecision: Sendable, Equatable {
    case cloud
    case onDevice(EngineFallbackReason)
    case unavailable(String)

    public var kind: VoiceEngineKind? {
        switch self {
        case .cloud: .cloud
        case .onDevice: .onDevice
        case .unavailable: nil
        }
    }
}

/// Engine selection (pure). The stricter privacy mode of the session request and the owner's
/// current setting wins; a client may ask for stricter, never looser.
public enum EngineSelector {
    public static func plan(settings: VoiceSettings, options: VoiceSessionOptions, currentPrivacy: PrivacyMode? = nil) -> EnginePlan {
        let privacy = stricter(options.privacyMode, currentPrivacy)
        if privacy == .strictPrivate { return .onDevice(.privateMode) }
        let wantsCloud = options.engine == .cloud || settings.engine == .cloud
        return wantsCloud ? .attemptCloud : .onDevice(.onDeviceChosen)
    }

    /// Final decision once the cloud attempt (if any) and on-device availability are known.
    public static func resolve(plan: EnginePlan, cloudReady: Bool, onDeviceAvailable: Bool) -> EngineDecision {
        switch plan {
        case .attemptCloud where cloudReady:
            return .cloud
        case .attemptCloud:
            return onDeviceAvailable ? .onDevice(.cloudUnavailable) : .unavailable("Cloud voice is not reachable and on-device speech recognition is not available.")
        case .onDevice(let reason):
            return onDeviceAvailable ? .onDevice(reason) : .unavailable("On-device speech recognition is not available for your language on this device.")
        }
    }

    public static func stricter(_ a: PrivacyMode, _ b: PrivacyMode?) -> PrivacyMode {
        (a == .strictPrivate || b == .strictPrivate) ? .strictPrivate : .cloudIntelligence
    }
}
