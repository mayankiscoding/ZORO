import SwiftUI

/// Neutrals are system semantic colours on both platforms, so they follow the user's appearance,
/// Increase Contrast and (on macOS) the window's vibrancy. Platform mappings live in
/// `ZoroNeutralsAppKit.swift` and `iOS/ZoroNeutralsUIKit.swift`. Only the reference values below
/// are hard-coded, for contrast tests.
public enum ZoroNeutral {
    /// Screen background.
    public static var background: Color { PlatformNeutrals.background }
    /// Card and grouped-content fill.
    public static var raised: Color { PlatformNeutrals.raised }
    /// Inset fill inside a card (table stripes, chips, secondary buttons).
    public static var inset: Color { PlatformNeutrals.inset }
    /// Hairlines and separators.
    public static var hairline: Color { PlatformNeutrals.hairline }
}

/// Reference values of system neutrals used by contrast tests (iOS light / dark).
public enum ZoroNeutralReference {
    public static let lightBackground = RGB(0xFFFFFF)
    public static let lightGroupedBackground = RGB(0xF2F2F7)
    public static let darkBackground = RGB(0x000000)
    public static let darkSecondaryBackground = RGB(0x1C1C1E)
}
