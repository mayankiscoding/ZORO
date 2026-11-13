import Foundation

/// One searchable idea with its words in English, Hindi (Devanagari) and Hinglish (romanised Hindi).
/// `english` words double as the label terms matched against Vision classification identifiers.
public struct Concept: Sendable, Hashable {
    public var key: String
    public var english: [String]
    public var hindi: [String]
    public var hinglish: [String]

    public init(_ key: String, en: [String], hi: [String], hinglish: [String]) {
        self.key = key
        self.english = en
        self.hindi = hi
        self.hinglish = hinglish
    }

    /// Normalised English terms used to match stored labels.
    public var labelTerms: Set<String> {
        Set(([key] + english).map(TextNormalizer.normalize).filter { !$0.isEmpty })
    }

    var allWords: [String] { [key] + english + hindi + hinglish }
}

/// Maps words and short phrases in three languages to concepts, longest phrase first.
public struct SynonymLexicon: Sendable {
    public let concepts: [Concept]
    private let index: [String: [Int]]
    private let maxPhraseWords: Int

    public init(concepts: [Concept]) {
        self.concepts = concepts
        var index = [String: [Int]]()
        var longest = 1
        for (i, concept) in concepts.enumerated() {
            for word in concept.allWords {
                let normal = TextNormalizer.normalize(word)
                guard !normal.isEmpty else { continue }
                longest = max(longest, normal.split(separator: " ").count)
                if !(index[normal]?.contains(i) ?? false) { index[normal, default: []].append(i) }
            }
        }
        self.index = index
        self.maxPhraseWords = longest
    }

    /// Concepts a single word or phrase belongs to.
    public func concepts(for phrase: String) -> [Concept] {
        (index[TextNormalizer.normalize(phrase)] ?? []).map { concepts[$0] }
    }

    /// English label terms for a word in any of the three languages; the word itself when unknown.
    public func expand(_ phrase: String) -> Set<String> {
        let found = concepts(for: phrase)
        guard !found.isEmpty else {
            let normal = TextNormalizer.normalize(phrase)
            return normal.isEmpty ? [] : [normal]
        }
        return found.reduce(into: Set<String>()) { $0.formUnion($1.labelTerms) }
    }

    /// Greedy longest-match scan over normalised tokens.
    /// Returns the matched concepts and the indices of tokens they consumed.
    public func scan(_ tokens: [String]) -> (matches: [(phrase: String, concepts: [Concept])], consumed: Set<Int>) {
        var matches: [(String, [Concept])] = []
        var consumed = Set<Int>()
        var i = 0
        while i < tokens.count {
            var matched = false
            for length in stride(from: min(maxPhraseWords, tokens.count - i), through: 1, by: -1) {
                let phrase = tokens[i..<(i + length)].joined(separator: " ")
                if let hits = index[phrase] {
                    matches.append((phrase, hits.map { concepts[$0] }))
                    consumed.formUnion(i..<(i + length))
                    i += length
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }
        return (matches, consumed)
    }
}

/// Colour words in English, Hindi and Hinglish (with gender/number inflections) → `NamedColour`.
public struct ColourLexicon: Sendable {
    private let index: [String: NamedColour]

    public init(words: [NamedColour: [String]]) {
        var index = [String: NamedColour]()
        for (colour, list) in words {
            index[colour.rawValue] = colour
            for word in list { index[TextNormalizer.normalize(word)] = colour }
        }
        self.index = index
    }

    public func colour(for word: String) -> NamedColour? { index[TextNormalizer.normalize(word)] }

    public static let standard = ColourLexicon(words: [
        .red: ["red", "maroon", "crimson", "scarlet", "laal", "lal", "laal rang", "लाल", "मरून"],
        .orange: ["orange", "saffron", "narangi", "naarangi", "kesari", "kesariya", "bhagwa", "नारंगी", "केसरिया", "भगवा"],
        .yellow: ["yellow", "gold", "golden", "mustard", "peela", "pila", "peeli", "pili", "peele", "sunehra", "sunehri",
                  "पीला", "पीली", "पीले", "सुनहरा", "सुनहरी"],
        .green: ["green", "olive", "lime", "hara", "hari", "hare", "haraa", "हरा", "हरी", "हरे"],
        .teal: ["teal", "cyan", "turquoise", "aqua", "firozi", "phirozi", "fīrozī", "फ़िरोज़ी", "फिरोजी"],
        .blue: ["blue", "navy", "sky blue", "neela", "nila", "neeli", "nili", "neele", "aasmani", "asmani",
                "नीला", "नीली", "नीले", "आसमानी"],
        .purple: ["purple", "violet", "lavender", "baingani", "bainganee", "jamuni", "बैंगनी", "जामुनी"],
        .pink: ["pink", "magenta", "gulabi", "gulaabi", "गुलाबी"],
        .brown: ["brown", "chocolate", "bhura", "bhoora", "bhuri", "bhure", "भूरा", "भूरी", "भूरे"],
        .beige: ["beige", "cream", "tan", "khaki", "off white", "kreem", "क्रीम"],
        .black: ["black", "kala", "kaala", "kali", "kaali", "kale", "kaale", "काला", "काली", "काले"],
        .white: ["white", "safed", "safaid", "sufaid", "saphed", "सफ़ेद", "सफेद"],
        .grey: ["grey", "gray", "silver", "sleti", "sleti rang", "saleti", "स्लेटी", "सलेटी"],
    ])
}
