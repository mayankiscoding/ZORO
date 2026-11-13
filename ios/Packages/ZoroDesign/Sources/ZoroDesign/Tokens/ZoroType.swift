import SwiftUI

/// The ZORO type scale. Every style is built on a Dynamic Type text style, so it scales with the
/// user's text size setting; nothing uses a fixed point size.
///
/// - SF Pro Expanded semibold: titles and money amounts.
/// - New York (system serif): ZORO's own words.
/// - SF Pro: interface text and the owner's words.
/// - Monospaced digits for every figure.
public enum ZoroTextStyle: String, CaseIterable, Sendable {
    /// Screen titles ("Spaces", "Activity").
    case title
    /// Card and section titles.
    case heading
    /// Hero amount (basket total, monthly spend).
    case amountHero
    /// Amount inside a card or row.
    case amount
    /// ZORO speaking, on the voice screen.
    case zoroVoice
    /// ZORO's words inside cards and threads.
    case zoroBody
    /// The owner's transcribed words, hanging below the rekha.
    case ownerVoice
    /// Interface body text.
    case body
    /// Secondary lines, row details.
    case detail
    /// Source and timestamp lines, captions.
    case caption

    public enum Family: String, Sendable { case expanded, serif, standard }

    public var family: Family {
        switch self {
        case .title, .heading, .amountHero, .amount: .expanded
        case .zoroVoice, .zoroBody: .serif
        case .ownerVoice, .body, .detail, .caption: .standard
        }
    }

    /// The Dynamic Type style this token scales with.
    public var textStyle: Font.TextStyle {
        switch self {
        case .title: .largeTitle
        case .heading: .headline
        case .amountHero: .largeTitle
        case .amount: .title3
        case .zoroVoice: .title2
        case .zoroBody: .body
        case .ownerVoice: .title3
        case .body: .body
        case .detail: .subheadline
        case .caption: .caption
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .title, .heading, .amountHero, .amount: .semibold
        case .zoroVoice, .zoroBody, .ownerVoice, .body, .detail, .caption: .regular
        }
    }

    public var usesMonospacedDigits: Bool {
        switch self {
        case .amountHero, .amount, .caption, .detail: true
        default: false
        }
    }

    /// Extra leading in points at the default size, for lines that may mix Devanagari and Latin.
    /// Devanagari's matras rise above the cap height and need the room.
    public var mixedScriptLeading: CGFloat {
        switch self {
        case .zoroVoice, .ownerVoice: 6
        case .zoroBody, .body: 4
        case .detail, .caption: 2
        case .title, .heading, .amountHero, .amount: 0
        }
    }

    public var font: Font {
        var font: Font
        switch family {
        case .expanded: font = .system(textStyle, design: .default, weight: weight).width(.expanded)
        case .serif: font = .system(textStyle, design: .serif, weight: weight)
        case .standard: font = .system(textStyle, design: .default, weight: weight)
        }
        if usesMonospacedDigits { font = font.monospacedDigit() }
        return font
    }
}

private struct ZoroTextModifier: ViewModifier {
    let style: ZoroTextStyle
    @ScaledMetric private var leading: CGFloat

    init(style: ZoroTextStyle) {
        self.style = style
        _leading = ScaledMetric(wrappedValue: style.mixedScriptLeading, relativeTo: style.textStyle)
    }

    func body(content: Content) -> some View {
        content.font(style.font).lineSpacing(leading)
    }
}

extension View {
    /// Applies a ZORO text style: font, digit spacing and scaled mixed-script leading.
    public func zoroText(_ style: ZoroTextStyle) -> some View {
        modifier(ZoroTextModifier(style: style))
    }
}
