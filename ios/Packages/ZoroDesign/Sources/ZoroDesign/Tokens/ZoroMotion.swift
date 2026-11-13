import SwiftUI

/// Motion tokens. Motion answers the owner (opening, confirming, showing what changed); the orb is
/// the only thing that moves on its own.
public enum ZoroMotion: String, CaseIterable, Sendable {
    /// Press feedback, chip selection.
    case quick
    /// Cards appearing, rows updating.
    case standard
    /// Sheets, the approval block, state changes of the voice screen.
    case emphasized
    /// The orb settling after an error shake.
    case settle

    /// Seconds.
    public var duration: Double {
        switch self {
        case .quick: 0.15
        case .standard: 0.28
        case .emphasized: 0.45
        case .settle: 0.8
        }
    }

    /// The curve: critically-damped springs for things the owner moved, ease-out for things ZORO moved.
    public var animation: Animation {
        switch self {
        case .quick: .snappy(duration: duration, extraBounce: 0)
        case .standard: .smooth(duration: duration, extraBounce: 0)
        case .emphasized: .spring(duration: duration, bounce: 0.12)
        case .settle: .easeOut(duration: duration)
        }
    }

    /// Under Reduce Motion every token becomes a short cross-fade: opacity only, no travel or bounce.
    public func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: ZoroMotion.reducedDuration) : animation
    }

    public static let reducedDuration: Double = 0.2

    /// Orb breath period at rest, seconds.
    public static let orbBreathPeriod: Double = 4.2
}

extension View {
    /// Animates `value` changes with a motion token, honouring Reduce Motion.
    public func zoroAnimation<V: Equatable>(_ motion: ZoroMotion, value: V) -> some View {
        modifier(ZoroAnimationModifier(motion: motion, value: value))
    }
}

private struct ZoroAnimationModifier<V: Equatable>: ViewModifier {
    let motion: ZoroMotion
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}
