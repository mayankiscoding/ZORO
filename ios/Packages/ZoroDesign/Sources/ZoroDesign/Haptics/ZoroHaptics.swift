import SwiftUI

/// Haptic vocabulary. Few, meaningful, matched to what changed.
public enum ZoroHaptic: String, CaseIterable, Sendable {
    /// The orb started listening.
    case listenStart
    /// Selection changed (chip, segmented choice).
    case selection
    /// An action completed (item added, reminder set).
    case success
    /// Something needs attention (approval waiting, price changed).
    case attention
    /// An action failed.
    case failure
    /// The owner approved a consequential action.
    case approved

    /// The SwiftUI feedback used by `.zoroHaptic(_:trigger:)` on both platforms.
    public var feedback: SensoryFeedback {
        switch self {
        case .listenStart: .impact(weight: .light)
        case .selection: .selection
        case .success: .success
        case .attention: .warning
        case .failure: .error
        case .approved: .impact(weight: .medium)
        }
    }
}

extension View {
    /// Plays a ZORO haptic whenever `trigger` changes. Silent on Macs without a Force Touch trackpad.
    public func zoroHaptic<T: Equatable>(_ haptic: ZoroHaptic, trigger: T) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger)
    }
}

/// Imperative haptics for code outside a view update (for example when an SSE event arrives).
@MainActor
public enum ZoroHaptics {
    public static func play(_ haptic: ZoroHaptic) {
        ZoroHapticsPlatform.play(haptic)
    }
}
