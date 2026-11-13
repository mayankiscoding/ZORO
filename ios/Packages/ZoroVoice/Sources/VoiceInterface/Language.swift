import Foundation
import ZoroCore

/// The three ways the owner speaks.
public enum SpokenLanguage: String, Sendable, CaseIterable, Codable {
    case en, hi, hinglish

    /// Accepts "en", "hi", "hinglish" and locale identifiers such as "hi-IN" or "en_IN".
    public init?(code: String) {
        let c = code.lowercased().replacingOccurrences(of: "_", with: "-")
        if c == "hinglish" || c.hasPrefix("hi-latn") {
            self = .hinglish
        } else if c == "hi" || c.hasPrefix("hi-") {
            self = .hi
        } else if c == "en" || c.hasPrefix("en-") {
            self = .en
        } else {
            return nil
        }
    }

    public init?(_ setting: VoiceSettings.Language) {
        switch setting {
        case .auto: return nil
        case .en: self = .en
        case .hi: self = .hi
        case .hinglish: self = .hinglish
        }
    }
}

/// Script plus lexicon language identification, the same approach as the backend's ingest step.
public enum LanguageIdentifier {
    /// Romanised Hindi function words and common verbs. Words that are also common English words
    /// ("to", "me", "main", "the") are left out on purpose.
    static let hinglishLexicon: Set<String> = [
        "hai", "hain", "ho", "hoga", "hogi", "tha", "thi", "kya", "kyun", "kyon", "kaise", "kaisa", "kaisi", "nahi", "nahin",
        "nhi", "mujhe", "mujhko", "mera", "meri", "mere", "tum", "tumhe", "tera", "teri", "aap", "aapka", "aapki", "apna",
        "karo", "karna", "kar", "kardo", "karde", "kijiye", "chahiye", "batao", "bata", "bataiye", "kal", "aaj", "abhi",
        "kitna", "kitne", "kitni", "kab", "kahan", "kaun", "yeh", "ye", "woh", "wo", "accha", "acha", "achha", "theek",
        "thik", "bhai", "yaar", "haan", "ko", "ka", "ki", "ke", "mein", "hum", "humko", "raha", "rahi", "rahe",
        "gaya", "gayi", "diya", "dena", "lena", "bhejo", "chalao", "bajao", "lagao", "sunao", "dikhao", "wala", "wali",
        "kuch", "sab", "bahut", "zyada", "jyada", "paisa", "paise", "ghar", "kaam", "subah", "shaam", "raat", "aur",
        "lekin", "matlab", "bolo", "suno", "dekho", "chalo", "jaldi", "thoda", "mat", "agar", "toh", "phir", "fir",
        "baje", "wapas", "dobara",
    ]

    public static func devanagariRatio(_ text: String) -> Double {
        var deva = 0
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic || (0x0900...0x097F).contains(scalar.value) {
            letters += 1
            if (0x0900...0x097F).contains(scalar.value) { deva += 1 }
        }
        return letters == 0 ? 0 : Double(deva) / Double(letters)
    }

    public static func identify(_ text: String) -> SpokenLanguage {
        let ratio = devanagariRatio(text)
        if ratio >= 0.5 { return .hi }
        if ratio > 0 { return .hinglish }
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return .en }
        let hits = words.filter { hinglishLexicon.contains($0) }.count
        if hits >= 2 || (hits == 1 && words.count <= 3) { return .hinglish }
        return .en
    }
}

/// Which recogniser locale to try first, and which voice language speaks a sentence.
public enum LocaleSelector {
    /// Ordered candidates; the session takes the first one the recogniser supports.
    /// Hinglish is usually spoken with Latin-script words, so en-IN (which knows Indian names and
    /// many Hindi loanwords) leads and hi-IN follows.
    public static func recognitionLocales(setting: VoiceSettings.Language, hint: String?, last: SpokenLanguage?) -> [String] {
        let language = SpokenLanguage(setting) ?? hint.flatMap(SpokenLanguage.init(code:)) ?? last
        switch language {
        case .en: return ["en-IN", "en-US"]
        case .hi: return ["hi-IN", "en-IN"]
        case .hinglish: return ["en-IN", "hi-IN"]
        case nil: return ["en-IN", "hi-IN", "en-US"]
        }
    }

    /// Devanagari sentences are spoken by a Hindi voice; Latin-script English and Hinglish by an
    /// Indian English voice, which reads romanised Hindi far better than a Hindi voice does.
    public static func synthesisLanguage(for sentence: String) -> String {
        LanguageIdentifier.devanagariRatio(sentence) >= 0.5 ? "hi-IN" : "en-IN"
    }
}

/// Optional wake phrase, honoured only while a session is already active (never background listening).
public struct WakePhrase: Sendable, Equatable {
    public var phrases: [String]

    public init(phrases: [String] = ["hey zoro", "ok zoro", "okay zoro", "zoro", "हे ज़ोरो", "हे जोरो", "ज़ोरो", "जोरो"]) {
        // Longest first so "hey zoro" wins over "zoro".
        self.phrases = phrases.map(Self.normalize).sorted { $0.count > $1.count }
    }

    /// The request after the wake phrase, or nil when the utterance does not start with it.
    public func strip(_ transcript: String) -> String? {
        let text = Self.normalize(transcript)
        for phrase in phrases where text.hasPrefix(phrase) {
            let rest = text.dropFirst(phrase.count)
            if let first = rest.first, first.isLetter || first.isNumber { continue }
            return rest.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
                .precomposedStringWithCanonicalMapping
        }
        return nil
    }

    static func normalize(_ s: String) -> String {
        s.decomposedStringWithCanonicalMapping.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }
}
