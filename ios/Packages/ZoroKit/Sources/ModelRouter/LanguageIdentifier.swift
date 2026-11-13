import Foundation

/// The three languages ZORO speaks. Raw values are the wire codes (`lang` in tool contexts).
public enum SpokenLanguage: String, Sendable, CaseIterable, Codable {
    case english = "en"
    case hindi = "hi"
    case hinglish
}

public struct LanguageIdentification: Sendable, Equatable {
    public var language: SpokenLanguage
    /// 0...1. 0 means there was nothing to judge (empty text, digits only).
    public var confidence: Double
    /// Share of word tokens written in Devanagari.
    public var devanagariShare: Double
    /// Devanagari and Latin words both appear.
    public var isMixedScript: Bool
    /// Number of romanised Hindi words found (Latin-script text only).
    public var romanHindiWords: Int

    public init(language: SpokenLanguage, confidence: Double, devanagariShare: Double, isMixedScript: Bool, romanHindiWords: Int) {
        self.language = language
        self.confidence = confidence
        self.devanagariShare = devanagariShare
        self.isMixedScript = isMixedScript
        self.romanHindiWords = romanHindiWords
    }
}

/// On-device language id from script plus a romanised-Hindi lexicon. Deterministic, no model.
///
/// - Devanagari only: Hindi.
/// - Latin only: English, unless romanised Hindi words make up a real share of the words: Hinglish.
/// - Both scripts: Hindi when Devanagari words are at least half of the words (ZORO then answers in
///   Devanagari, matching the owner's script), otherwise Hinglish.
public enum LanguageIdentifier {
    public static func identify(_ text: String) -> LanguageIdentification {
        let tokens = Tokenizer.tokenize(text).filter { !$0.isNumeric }
        guard !tokens.isEmpty else {
            return LanguageIdentification(language: .english, confidence: 0, devanagariShare: 0, isMixedScript: false, romanHindiWords: 0)
        }
        let dev = tokens.filter(\.isDevanagari).count
        let latin = tokens.count - dev
        let share = Double(dev) / Double(tokens.count)

        if latin == 0 {
            return LanguageIdentification(language: .hindi, confidence: 0.97, devanagariShare: 1, isMixedScript: false, romanHindiWords: 0)
        }
        if dev > 0 {
            let latinTokens = tokens.filter { !$0.isDevanagari }
            let romanHindi = romanHindiCount(latinTokens)
            if share > 0.5 {
                return LanguageIdentification(language: .hindi, confidence: 0.75 + 0.2 * share, devanagariShare: share, isMixedScript: true, romanHindiWords: romanHindi)
            }
            return LanguageIdentification(language: .hinglish, confidence: 0.7, devanagariShare: share, isMixedScript: true, romanHindiWords: romanHindi)
        }

        let strong = tokens.filter { Lexicon.romanHindiStrong.contains($0.norm) }.count
        let weak = strong > 0 ? tokens.filter { Lexicon.romanHindiWeak.contains($0.norm) && !Lexicon.romanHindiStrong.contains($0.norm) }.count : 0
        let score = Double(strong) + 0.5 * Double(weak)
        let ratio = score / Double(tokens.count)
        if strong >= 2 || (strong >= 1 && ratio >= 0.2) {
            return LanguageIdentification(
                language: .hinglish, confidence: min(0.98, 0.6 + 0.1 * Double(strong) + 0.2 * ratio), devanagariShare: 0,
                isMixedScript: false, romanHindiWords: strong)
        }
        let englishWords = tokens.filter { Lexicon.englishFunction.contains($0.norm) }.count
        let confidence = min(0.95, 0.55 + 0.07 * Double(englishWords) - (strong > 0 ? 0.15 : 0))
        return LanguageIdentification(language: .english, confidence: confidence, devanagariShare: 0, isMixedScript: false, romanHindiWords: strong)
    }

    private static func romanHindiCount(_ tokens: [Token]) -> Int {
        tokens.filter { Lexicon.romanHindiStrong.contains($0.norm) }.count
    }
}
