import Foundation
import ZoroCore

/// Whether the backend can be reached right now (network up and the ZORO server answering).
public enum BackendReachability: String, Sendable, CaseIterable {
    case online, offline
}

public enum RouteTarget: String, Sendable, Equatable {
    /// Run the local intent on this device now.
    case onDevice = "on_device"
    /// Send the turn to the ZORO backend.
    case backend
    /// Neither is possible right now (offline and the device does not understand the request).
    case unavailable
}

public enum RouteReason: String, Sendable, Equatable {
    /// A device-only command (alarm, timer, music, photo search, open a section) understood with all its details.
    case deviceOnlyIntent = "device_only_intent"
    /// Another local command understood with all its details (reminder, calendar lookup).
    case localIntent = "local_intent"
    /// Not a command the device handles alone: the backend (agents, memory, models) takes it.
    case needsBackend = "needs_backend"
    /// The device recognised a command but a detail is missing; the backend can ask for it.
    case incompleteLocalIntent = "incomplete_local_intent"
    /// Offline and the device cannot handle this alone.
    case backendUnreachable = "backend_unreachable"
    /// Offline, recognised, but a detail is missing: the app asks the owner for it on the device.
    case incompleteOffline = "incomplete_offline"
}

/// Where one turn runs, and what the turn may use. Pure value: the same inputs always give the same decision.
public struct RouteDecision: Sendable, Equatable {
    public var target: RouteTarget
    public var reason: RouteReason
    /// The understood command when `target == .onDevice` (or when it is incomplete).
    public var intent: LocalIntent?
    /// The privacy mode to send with the turn. A client may ask for stricter, never looser, so this is the
    /// owner's current mode.
    public var privacyMode: PrivacyMode
    /// False in strict private mode: no external inference for this turn.
    public var allowsExternalInference: Bool

    public init(target: RouteTarget, reason: RouteReason, intent: LocalIntent? = nil, privacyMode: PrivacyMode) {
        self.target = target
        self.reason = reason
        self.intent = intent
        self.privacyMode = privacyMode
        self.allowsExternalInference = privacyMode == .cloudIntelligence && target == .backend
    }

    public var runsOnDevice: Bool { target == .onDevice }
}

/// Decides on-device vs backend from the privacy mode, connectivity and whether the intent is device-only.
///
/// 1. A local command with every detail runs on the device, online or not: it is faster and needs no server.
///    Device-only commands (alarm, timer, music, photos, open a section) never go to the backend.
/// 2. Anything else goes to the backend when it is reachable, carrying the owner's privacy mode
///    (strict private: no external inference; cloud mode: approved providers only).
/// 3. Offline and not understood: unavailable, with the reason, so the app says what to do.
public enum IntentRouter {
    public static func decide(
        intent: LocalIntent?, privacyMode: PrivacyMode, reachability: BackendReachability,
        minimumConfidence: Double = LocalIntentClassifier.minimumActionableConfidence
    ) -> RouteDecision {
        if let intent, intent.confidence >= minimumConfidence {
            let reason: RouteReason = LocalIntentTools.isDeviceOnly(intent.name) ? .deviceOnlyIntent : .localIntent
            return RouteDecision(target: .onDevice, reason: reason, intent: intent, privacyMode: privacyMode)
        }
        switch reachability {
        case .online:
            return RouteDecision(
                target: .backend, reason: intent == nil ? .needsBackend : .incompleteLocalIntent, intent: intent,
                privacyMode: privacyMode)
        case .offline:
            return RouteDecision(
                target: .unavailable, reason: intent == nil ? .backendUnreachable : .incompleteOffline, intent: intent,
                privacyMode: privacyMode)
        }
    }

    /// Classifies and routes in one call.
    public static func route(
        _ text: String, languageHint: String? = nil, classifier: any LocalIntentClassifying, privacyMode: PrivacyMode,
        reachability: BackendReachability
    ) async -> RouteDecision {
        let intent = await classifier.classify(text, languageHint: languageHint)
        return decide(intent: intent, privacyMode: privacyMode, reachability: reachability)
    }
}
