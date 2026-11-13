import CoreText
import SwiftUI

/// Whether ZORO's Devanagari serif is available to the process.
public enum ZoroFontRegistration: Equatable, Sendable {
    case registered
    /// The font could not be registered; Devanagari falls back to the system's Devanagari face.
    case unavailable(reason: String)

    public var isRegistered: Bool { self == .registered }
}

/// ZORO's bundled typeface: Tiro Devanagari Hindi (SIL Open Font License 1.1), a Devanagari serif
/// cut in the tradition of the Nirnaya Sagar Press metal types. It gives ZORO's Hindi words the same
/// bookish voice that New York gives its English ones. Latin stays in New York; only Devanagari runs
/// switch face (see `ZoroTextStyle.attributed(_:)` and `ZoroVoiceText`).
public enum ZoroFonts {
    public static let devanagariSerifPostScriptName = "TiroDevaHindi-Regular"
    public static let devanagariSerifFileName = "TiroDevanagariHindi-Regular"
    /// The OFL text that must travel with the font. It is in the same bundle.
    public static let devanagariSerifLicenceFileName = "TiroDevanagariHindi-OFL"

    /// Registers the bundled font for this process. Idempotent and thread-safe; call it once at
    /// launch. Text helpers call it too, so a missed call costs one registration on first use.
    @discardableResult
    public static func register() -> ZoroFontRegistration { registration }

    private static let registration: ZoroFontRegistration = performRegistration(
        url: ZoroResources.url(named: devanagariSerifFileName, extension: "ttf")
    )

    static func performRegistration(url: URL?) -> ZoroFontRegistration {
        guard let url else { return .unavailable(reason: "The font file is missing from the ZoroDesign bundle.") }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            let cfError = error?.takeRetainedValue()
            let code = cfError.map { CFErrorGetCode($0) } ?? 0
            if code != CTFontManagerError.alreadyRegistered.rawValue {
                let text = cfError.map { CFErrorCopyDescription($0) as String } ?? "unknown error"
                return .unavailable(reason: "Core Text could not register the font: \(text)")
            }
        }
        return resolvesDevanagariSerif()
            ? .registered
            : .unavailable(reason: "The font registered but \(devanagariSerifPostScriptName) did not resolve.")
    }

    /// True when Core Text resolves the PostScript name to the bundled face (not a substitute).
    public static func resolvesDevanagariSerif() -> Bool {
        let font = CTFontCreateWithName(devanagariSerifPostScriptName as CFString, 17, nil)
        return (CTFontCopyPostScriptName(font) as String) == devanagariSerifPostScriptName
    }

    /// Tiro's Devanagari is drawn to sit with Latin at the same size; against New York it needs a
    /// touch more to match the weight of the headline stroke to New York's x-height.
    static let devanagariSizeRatio: CGFloat = 1.04
}

/// Where Devanagari starts and stops in a string, so each script can take its own face.
public enum ZoroScript {
    public struct Run: Equatable, Sendable {
        public let text: String
        public let isDevanagari: Bool
        public init(text: String, isDevanagari: Bool) {
            self.text = text
            self.isDevanagari = isDevanagari
        }
    }

    /// Devanagari, Devanagari Extended, Vedic Extensions and Devanagari Extended-A.
    public static func isDevanagari(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0900...0x097F, 0xA8E0...0xA8FF, 0x1CD0...0x1CFF, 0x11B00...0x11B5F: true
        default: false
        }
    }

    public static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isDevanagari)
    }

    /// Splits text into alternating Devanagari and other runs. Spaces, punctuation, Latin digits and
    /// joiners belong to the run before them (or after them at the start), so a Hindi sentence stays
    /// one run and a Hinglish line splits only where the script changes.
    public static func runs(in text: String) -> [Run] {
        let kinds: [Bool?] = text.map(kind)
        guard let firstKnown = kinds.first(where: { $0 != nil }) ?? nil else {
            return text.isEmpty ? [] : [Run(text: text, isDevanagari: false)]
        }
        var runs: [Run] = []
        var current = ""
        var currentKind = firstKnown
        for (character, kind) in zip(text, kinds) {
            let resolved = kind ?? currentKind
            if resolved != currentKind, !current.isEmpty {
                runs.append(Run(text: current, isDevanagari: currentKind))
                current = ""
            }
            currentKind = resolved
            current.append(character)
        }
        if !current.isEmpty { runs.append(Run(text: current, isDevanagari: currentKind)) }
        return runs
    }

    /// true = Devanagari, false = another script, nil = neutral (takes its neighbour's script).
    private static func kind(_ character: Character) -> Bool? {
        guard let first = character.unicodeScalars.first else { return nil }
        if isDevanagari(first) { return true }
        if character.isWhitespace || character.isPunctuation || character.isNumber || character.isSymbol { return nil }
        if character.unicodeScalars.allSatisfy({ $0.properties.isJoinControl || $0.properties.isDefaultIgnorableCodePoint }) {
            return nil
        }
        return false
    }
}

extension ZoroTextStyle {
    /// The font for Devanagari in this style. ZORO's own words (the serif styles) use the bundled
    /// Devanagari serif; every other style keeps the system font, whose Devanagari fallback is the
    /// sans that pairs with SF Pro. Scales with Dynamic Type through `relativeTo:`.
    public var devanagariFont: Font {
        guard family == .serif else { return font }
        ZoroFonts.register()
        return .custom(
            ZoroFonts.devanagariSerifPostScriptName,
            size: Self.defaultPointSize(textStyle) * ZoroFonts.devanagariSizeRatio,
            relativeTo: textStyle
        )
    }

    /// The text with every Devanagari run set in `devanagariFont`. Other runs carry no font, so they
    /// take the style's own font from `.zoroText(_:)`.
    public func attributed(_ text: String) -> AttributedString {
        guard family == .serif, ZoroScript.containsDevanagari(text) else { return AttributedString(text) }
        let devanagari = devanagariFont
        var result = AttributedString()
        for run in ZoroScript.runs(in: text) {
            var part = AttributedString(run.text)
            if run.isDevanagari { part.swiftUI.font = devanagari }
            result += part
        }
        return result
    }

    /// The point size of a Dynamic Type style at the default text size (Apple HIG type tables), the
    /// base that `Font.custom(_:size:relativeTo:)` scales from.
    static func defaultPointSize(_ style: Font.TextStyle) -> CGFloat {
        #if os(macOS)
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
        #else
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
        #endif
    }
}

/// ZORO's own words, in any language: New York for Latin, the Devanagari serif for Hindi, with the
/// style's mixed-script leading. Use it wherever ZORO speaks (`.zoroVoice`, `.zoroBody`).
public struct ZoroVoiceText: View {
    let text: String
    let style: ZoroTextStyle

    public init(_ text: String, style: ZoroTextStyle = .zoroVoice) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        Text(style.attributed(text)).zoroText(style)
    }
}
