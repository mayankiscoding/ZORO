import SwiftUI

/// Spacing on a 4-point grid. Components scale these with `@ScaledMetric` where text sits inside.
public enum ZoroSpace: CGFloat, CaseIterable, Sendable {
    case hair = 2
    case xs = 4
    case s = 8
    case m = 12
    case l = 16
    case xl = 24
    case xxl = 32
    case xxxl = 48

    public var value: CGFloat { rawValue }
}

/// Corner radii follow hierarchy: the bigger the surface, the rounder. Always continuous corners.
/// Chips and badges are capsules.
public enum ZoroRadius: CGFloat, CaseIterable, Sendable {
    /// Inline fills: table stripes, image wells.
    case inset = 8
    /// Buttons and text fields.
    case control = 12
    /// Cards.
    case card = 20
    /// Sheets and the approval block.
    case sheet = 28

    public var value: CGFloat { rawValue }
    public var shape: RoundedRectangle { RoundedRectangle(cornerRadius: rawValue, style: .continuous) }
}

/// Line weights.
public enum ZoroStroke {
    /// The rekha: one hairline that carries the voice screen.
    public static let rekha: CGFloat = 1
    /// Increase Contrast rekha.
    public static let rekhaHighContrast: CGFloat = 2
    public static let hairline: CGFloat = 0.5

    /// The rekha is drawn in the label colour at this opacity: present, never loud.
    public static func rekhaOpacity(highContrast: Bool) -> Double { highContrast ? 0.7 : 0.32 }
}
