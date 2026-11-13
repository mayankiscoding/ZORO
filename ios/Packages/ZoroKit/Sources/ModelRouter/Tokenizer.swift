import Foundation

/// One word of an utterance. `text` keeps the owner's spelling (for titles and queries); `norm` is the
/// matching form: lower-case Latin, Devanagari without nukta, chandrabindu folded into anusvara.
struct Token: Equatable, Sendable {
    var text: String
    var norm: String
    var isDevanagari: Bool
    var isNumeric: Bool

    var intValue: Int? { isNumeric ? Int(norm) : nil }
}

enum Script {
    static func isDevanagari(_ scalar: Unicode.Scalar) -> Bool { (0x0900...0x097F).contains(scalar.value) }
    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) || (0xC0...0x24F).contains(scalar.value)
    }

    /// Devanagari digits to ASCII.
    static func asciiDigits(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if (0x0966...0x096F).contains(s.value), let ascii = Unicode.Scalar(0x30 + (s.value - 0x0966)) {
                out.append(ascii)
            } else {
                out.append(s)
            }
        }
        return String(out)
    }

    static func normalize(_ word: String) -> String {
        var out = String.UnicodeScalarView()
        for s in word.unicodeScalars {
            switch s.value {
            case 0x093C, 0x200C, 0x200D, 0x27, 0x2019: continue  // nukta, joiners, apostrophes
            case 0x0901: out.append(Unicode.Scalar(0x0902)!)  // chandrabindu -> anusvara
            default: out.append(s)
            }
        }
        return String(out).lowercased()
    }
}

enum Tokenizer {
    private enum Class { case letter, digit, other }

    private static func classify(_ s: Unicode.Scalar) -> Class {
        switch s.properties.generalCategory {
        case .decimalNumber:
            return (0x30...0x39).contains(s.value) ? .digit : .other
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return .letter
        default:
            return .other
        }
    }

    /// Splits on spaces and punctuation, and between digits and letters ("6pm", "10मिनट"). Keeps "6:30",
    /// "6.30" and "1,000" together and apostrophes inside words.
    static func tokenize(_ input: String) -> [Token] {
        let text = Script.asciiDigits(input.precomposedStringWithCanonicalMapping)
        let scalars = Array(text.unicodeScalars)
        var tokens: [Token] = []
        var current = String.UnicodeScalarView()
        var currentClass: Class = .other

        func flush() {
            guard !current.isEmpty else { return }
            let word = String(current)
            let norm = Script.normalize(word)
            if !norm.isEmpty {
                let numeric = currentClass == .digit
                tokens.append(Token(
                    text: word, norm: norm, isDevanagari: current.contains(where: Script.isDevanagari), isNumeric: numeric))
            }
            current = String.UnicodeScalarView()
        }

        for (i, s) in scalars.enumerated() {
            let cls = classify(s)
            if cls == .other {
                let prev = i > 0 ? scalars[i - 1] : nil
                let next = i + 1 < scalars.count ? scalars[i + 1] : nil
                if [0x3A, 0x2E, 0x2C].contains(s.value), let p = prev, let n = next,
                   classify(p) == .digit, classify(n) == .digit, currentClass == .digit, !current.isEmpty {
                    current.append(s)  // "6:30" stays one token
                    continue
                }
                if s.value == 0x27 || s.value == 0x2019, let p = prev, let n = next,
                   classify(p) == .letter, classify(n) == .letter {
                    current.append(s)  // "what's"
                    continue
                }
                flush()
                if s.value == 0x40 {  // "@" is a word of its own
                    tokens.append(Token(text: "@", norm: "@", isDevanagari: false, isNumeric: false))
                }
                continue
            }
            if !current.isEmpty, cls != currentClass { flush() }
            currentClass = cls
            current.append(s)
        }
        flush()
        return tokens
    }
}

/// A tokenised utterance with a consumed flag per token, so slot extractors can claim words and the
/// rest becomes the reminder title or the music query.
struct Utterance: Sendable {
    let original: String
    var tokens: [Token]
    var consumed: [Bool]

    init(_ text: String) {
        original = text
        tokens = Tokenizer.tokenize(text)
        consumed = Array(repeating: false, count: tokens.count)
    }

    var count: Int { tokens.count }
    func norm(_ i: Int) -> String? { tokens.indices.contains(i) ? tokens[i].norm : nil }
    func isFree(_ i: Int) -> Bool { tokens.indices.contains(i) && !consumed[i] }

    mutating func consume(_ range: Range<Int>) {
        for i in range where consumed.indices.contains(i) { consumed[i] = true }
    }
    mutating func consume(_ i: Int) { if consumed.indices.contains(i) { consumed[i] = true } }

    func contains(any words: Set<String>) -> Bool { tokens.indices.contains { isFree($0) && words.contains(tokens[$0].norm) } }
    func firstIndex(in words: Set<String>) -> Int? { tokens.indices.first { isFree($0) && words.contains(tokens[$0].norm) } }

    /// Index of `phrase` (consecutive normalised words) among free tokens.
    func index(ofPhrase phrase: [String]) -> Int? {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return nil }
        for start in 0...(tokens.count - phrase.count) {
            if phrase.indices.allSatisfy({ isFree(start + $0) && tokens[start + $0].norm == phrase[$0] }) { return start }
        }
        return nil
    }

    /// The still-free words, trimmed at both ends by `leading` / `trailing` filler words.
    func remainder(dropping drop: Set<String> = [], leading: Set<String> = [], trailing: Set<String> = []) -> [Token] {
        var words = tokens.indices.filter { isFree($0) && !drop.contains(tokens[$0].norm) }.map { tokens[$0] }
        while let last = words.last, trailing.contains(last.norm) { words.removeLast() }
        while let first = words.first, leading.contains(first.norm) { words.removeFirst() }
        return words
    }
}
