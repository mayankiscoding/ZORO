import Foundation

/// Splits streamed reply text into speakable sentences as deltas arrive, so speech starts after the
/// first sentence instead of the whole reply. Handles the Devanagari danda (। and ॥), English and
/// Hindi abbreviations, initials, decimals ("3.5", "₹1,299.50"), dotted names ("zoro.app") and
/// ellipses. A "." only ends a sentence once the following character is known, so a sentence is never
/// cut inside "Dr. Rao"; the danda and line breaks end one immediately.
public struct SentenceChunker: Sendable, Equatable {
    /// Longest sentence before a forced split at a comma or space (keeps speech starting quickly).
    public var maxLength: Int
    private var buffer = ""

    public static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "vs", "etc", "eg", "e.g", "ie", "i.e", "approx", "rs", "inc",
        "ltd", "dept", "govt", "avg", "fig", "vol", "a.m", "p.m", "jan", "feb", "apr", "jun", "jul", "aug", "sep",
        "sept", "oct", "nov", "dec",
        "डॉ", "श्री", "सं", "रु", "क्र", "पृ",
    ]

    static let immediateTerminators: Set<Character> = ["।", "॥", "\n"]
    static let lookaheadTerminators: Set<Character> = [".", "!", "?", "…"]
    static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "”", "’", "»"]

    public init(maxLength: Int = 220) {
        self.maxLength = maxLength
    }

    public var pendingText: String { buffer }

    /// Adds a delta and returns every sentence it completed, in order.
    public mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var sentences: [String] = []
        while let (sentence, rest) = nextSentence() {
            buffer = rest
            if let s = Self.clean(sentence) { sentences.append(s) }
        }
        return sentences
    }

    /// The remaining text when the reply has ended.
    public mutating func flush() -> String? {
        defer { buffer = "" }
        return Self.clean(buffer)
    }

    public mutating func reset() { buffer = "" }

    // MARK: - Scanning

    private func nextSentence() -> (String, String)? {
        let chars = Array(buffer)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if Self.immediateTerminators.contains(c) {
                return split(chars, after: absorbTrailing(chars, from: i))
            }
            if Self.lookaheadTerminators.contains(c) {
                switch decide(chars, at: i) {
                case .boundary(let end): return split(chars, after: end)
                case .notBoundary: break
                case .needMoreText: return forcedSplit(chars, limit: i)
                }
            }
            i += 1
        }
        return forcedSplit(chars, limit: chars.count)
    }

    private enum Decision { case boundary(Int), notBoundary, needMoreText }

    private func decide(_ chars: [Character], at i: Int) -> Decision {
        let c = chars[i]
        // Runs like "?!", "..." and closing quotes belong to the sentence.
        let end = absorbTrailing(chars, from: i)
        guard end + 1 < chars.count else { return .needMoreText }
        let next = chars[end + 1]
        guard next.isWhitespace else {
            // "3.5", "zoro.app", "e.g" — a full stop inside a token.
            return c == "." ? .notBoundary : (next.isLetter || next.isNumber ? .notBoundary : .boundary(end))
        }
        if c == "." {
            let word = precedingWord(chars, before: i)
            if Self.abbreviations.contains(word.lowercased()) { return .notBoundary }
            // A single Latin initial: "A. R. Rahman".
            if word.count == 1, let f = word.first, f.isLetter, f.isASCII { return .notBoundary }
            // Look past the space: a lowercase Latin word continues the sentence ("approx. five").
            var j = end + 1
            while j < chars.count, chars[j].isWhitespace, chars[j] != "\n" { j += 1 }
            if j >= chars.count { return .needMoreText }
            if let f = chars[j].unicodeScalars.first, chars[j].isLowercase, f.isASCII { return .notBoundary }
        }
        return .boundary(end)
    }

    private func absorbTrailing(_ chars: [Character], from i: Int) -> Int {
        var end = i
        while end + 1 < chars.count,
            Self.closers.contains(chars[end + 1]) || Self.lookaheadTerminators.contains(chars[end + 1])
                || Self.immediateTerminators.contains(chars[end + 1]) && chars[end + 1] != "\n"
        {
            end += 1
        }
        return end
    }

    private func precedingWord(_ chars: [Character], before i: Int) -> String {
        var j = i - 1
        while j >= 0, !chars[j].isWhitespace, !Self.closers.contains(chars[j]), chars[j] != "(" { j -= 1 }
        return String(chars[(j + 1)..<i])
    }

    private func split(_ chars: [Character], after end: Int) -> (String, String) {
        (String(chars[0...end]), String(chars[(end + 1)...]))
    }

    /// Splits an over-long run at its last comma (or space) before the limit.
    private func forcedSplit(_ chars: [Character], limit: Int) -> (String, String)? {
        guard limit > maxLength else { return nil }
        let window = chars[0..<maxLength]
        let breakers: [Character] = [",", ";", ":", "—", "–"]
        if let idx = window.lastIndex(where: { breakers.contains($0) }), idx > maxLength / 3 {
            return split(chars, after: idx)
        }
        if let idx = window.lastIndex(where: { $0 == " " }), idx > 0 {
            return split(chars, after: idx)
        }
        return split(chars, after: maxLength - 1)
    }

    static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return t
    }
}
