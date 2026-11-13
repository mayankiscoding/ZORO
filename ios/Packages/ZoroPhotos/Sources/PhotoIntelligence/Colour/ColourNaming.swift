import Foundation

/// The named colours the index understands. Raw values are the English names used on the wire.
public enum NamedColour: String, Sendable, Codable, CaseIterable, Hashable {
    case red, orange, yellow, green, teal, blue, purple, pink, brown, beige, black, white, grey
}

/// A colour in the OKLab perceptual space (Björn Ottosson, 2020).
public struct OKLab: Sendable, Equatable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// From 8-bit sRGB.
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self = OKLab.fromLinear(
            r: SRGBTable.linear[Int(red)], g: SRGBTable.linear[Int(green)], b: SRGBTable.linear[Int(blue)])
    }

    static func fromLinear(r: Double, g: Double, b: Double) -> OKLab {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return OKLab(
            l: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    /// Chroma (distance from the grey axis).
    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// Hue angle in degrees, 0..<360.
    public var hueDegrees: Double {
        let h = atan2(b, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }
}

/// sRGB transfer function, precomputed for every 8-bit value.
enum SRGBTable {
    static let linear: [Double] = (0...255).map { v in
        let c = Double(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}

/// Maps a perceptual colour to the name a person would use. Boundaries were set from the OKLCh
/// coordinates of reference colours (CSS named colours) and are covered by tests.
public struct ColourNamer: Sendable {
    /// Below this chroma a colour counts as black, grey or white.
    public var achromaticChroma: Double = 0.04

    public init() {}

    public func name(_ c: OKLab) -> NamedColour {
        let lightness = c.l
        let chroma = c.chroma
        if lightness < 0.20 { return .black }
        if chroma < achromaticChroma {
            if lightness < 0.30 { return .black }
            if lightness >= 0.92 { return .white }
            return .grey
        }
        let h = c.hueDegrees
        switch h {
        case 345..<360, 0..<15:
            return lightness >= 0.65 ? .pink : .red
        case 15..<40:
            return .red
        case 40..<80:
            if lightness >= 0.70 && chroma < 0.11 { return .beige }
            return lightness < 0.66 ? .brown : .orange
        case 80..<125:
            if lightness >= 0.70 && chroma < 0.11 { return .beige }
            if lightness < 0.62 { return h < 95 ? .brown : .green }
            return .yellow
        case 125..<175:
            return .green
        case 175..<215:
            return .teal
        case 215..<290:
            return .blue
        default:  // 290..<345
            return (h >= 320 && lightness >= 0.65) ? .pink : .purple
        }
    }

    public func name(red: UInt8, green: UInt8, blue: UInt8) -> NamedColour {
        name(OKLab(red: red, green: green, blue: blue))
    }
}
