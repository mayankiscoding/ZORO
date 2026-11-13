import SwiftUI

/// An sRGB colour stored as exact 8-bit components, so tokens can be tested without a renderer.
public struct RGB: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(_ hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    public var hexString: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio between two colours (1...21).
    public func contrastRatio(against other: RGB) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1)
    }

    public static let white = RGB(0xFFFFFF)
    public static let black = RGB(0x000000)
}

/// The five ZORO hues. Neutrals are always system semantic colours.
public enum ZoroHue: String, CaseIterable, Sendable {
    /// Indigo. Primary accent, controls, ZORO's presence.
    case neel
    /// Peacock teal. Positive, available, working.
    case mor
    /// Marigold. ZORO speaking, attention, stale prices. Fill and decoration only in light mode.
    case genda
    /// Lac red. Errors, declines, destructive actions.
    case lac
    /// Moonstone grey-blue. Strict private mode.
    case moonstone

    /// The four appearance variants of a hue.
    public struct Variants: Hashable, Sendable {
        public let light: RGB
        public let dark: RGB
        public let lightHighContrast: RGB
        public let darkHighContrast: RGB
    }

    public var variants: Variants {
        switch self {
        case .neel:
            Variants(light: RGB(0x2A2F8F), dark: RGB(0x5B62E0), lightHighContrast: RGB(0x1D2170), darkHighContrast: RGB(0x9CA1FF))
        case .mor:
            Variants(light: RGB(0x0B7F86), dark: RGB(0x19B5B0), lightHighContrast: RGB(0x065C61), darkHighContrast: RGB(0x5FDCD6))
        case .genda:
            Variants(light: RGB(0xD98A00), dark: RGB(0xFFB321), lightHighContrast: RGB(0x8A5600), darkHighContrast: RGB(0xFFCB66))
        case .lac:
            Variants(light: RGB(0xB5302A), dark: RGB(0xFF6B5E), lightHighContrast: RGB(0x8C1E19), darkHighContrast: RGB(0xFF9D94))
        case .moonstone:
            Variants(light: RGB(0x6E7A8A), dark: RGB(0xA9B4C2), lightHighContrast: RGB(0x4A5462), darkHighContrast: RGB(0xD0D7E0))
        }
    }

    /// The variant for an appearance. Pure, so it is unit-tested.
    public func rgb(scheme: ColorScheme, highContrast: Bool) -> RGB {
        let v = variants
        switch (scheme, highContrast) {
        case (.dark, true): return v.darkHighContrast
        case (.dark, false): return v.dark
        case (_, true): return v.lightHighContrast
        default: return v.light
        }
    }

    /// White or black, whichever reads better on this hue as a fill (for example lac in dark mode
    /// takes black labels).
    public func labelOnFill(scheme: ColorScheme, highContrast: Bool) -> RGB {
        let fill = rgb(scheme: scheme, highContrast: highContrast)
        return RGB.white.contrastRatio(against: fill) >= RGB.black.contrastRatio(against: fill) ? .white : .black
    }

    public func color(scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
        rgb(scheme: scheme, highContrast: contrast == .increased).color
    }

    /// Whether the standard variants may carry body text (WCAG 4.5:1) on the system background in
    /// light mode and on the secondary system background (#1C1C1E) in dark mode. Measured, not
    /// declared: neel, genda and moonstone are fills, glyph tints and large text only. Increase
    /// Contrast variants are text-safe for every hue (tested).
    public var isTextSafeAtStandardContrast: Bool {
        variants.light.contrastRatio(against: .white) >= 4.5
            && variants.dark.contrastRatio(against: ZoroNeutralReference.darkSecondaryBackground) >= 4.5
    }
}

/// A `ShapeStyle` that resolves a ZORO hue from the SwiftUI environment (colour scheme and
/// Increase Contrast), so it is correct in previews, ImageRenderer and both platforms without
/// UIKit or AppKit dynamic colours.
public struct ZoroColor: ShapeStyle, Hashable, Sendable {
    public let hue: ZoroHue
    public init(_ hue: ZoroHue) { self.hue = hue }

    public func resolve(in environment: EnvironmentValues) -> Color {
        hue.color(scheme: environment.colorScheme, contrast: environment.colorSchemeContrast)
    }
}

extension ShapeStyle where Self == ZoroColor {
    public static var neel: ZoroColor { ZoroColor(.neel) }
    public static var mor: ZoroColor { ZoroColor(.mor) }
    public static var genda: ZoroColor { ZoroColor(.genda) }
    public static var lac: ZoroColor { ZoroColor(.lac) }
    public static var moonstone: ZoroColor { ZoroColor(.moonstone) }
}

/// Semantic roles. Feature code uses roles, not hues.
public enum ZoroRole: CaseIterable, Sendable {
    case accent, positive, attention, critical, privateMode

    public var hue: ZoroHue {
        switch self {
        case .accent: .neel
        case .positive: .mor
        case .attention: .genda
        case .critical: .lac
        case .privateMode: .moonstone
        }
    }

    public var style: ZoroColor { ZoroColor(hue) }
}
