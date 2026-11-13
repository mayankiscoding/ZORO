import Foundation

/// Reads numbers written as digits, English words, romanised Hindi or Devanagari.
enum NumberParsing {
    /// A plain count at `i` ("10", "ten", "das", "दस", "forty five"), and how many tokens it used.
    static func integer(in u: Utterance, at i: Int) -> (value: Int, length: Int)? {
        guard u.isFree(i) else { return nil }
        let t = u.tokens[i]
        if t.isNumeric, let v = t.intValue { return (v, 1) }
        guard let first = Lexicon.numberWords[t.norm] else { return nil }
        // "twenty five", "forty five" (tens followed by a unit)
        if first >= 20, first % 10 == 0, u.isFree(i + 1), let second = u.norm(i + 1).flatMap({ Lexicon.numberWords[$0] }), second >= 1, second <= 9 {
            return (first + second, 2)
        }
        return (first, 1)
    }

    /// A quantity that may be fractional: "2.5", "dedh", "dhai", "aadha", "sava 2", "saade teen", "paune do".
    static func quantity(in u: Utterance, at i: Int) -> (value: Double, length: Int)? {
        guard u.isFree(i) else { return nil }
        let t = u.tokens[i]
        if t.isNumeric, t.norm.contains("."), let v = Double(t.norm) { return (v, 1) }
        if let f = Lexicon.fractionWords[t.norm] {
            // "half an hour", "half hour"
            if t.norm == "half", u.isFree(i + 1), ["an", "a"].contains(u.norm(i + 1) ?? "") { return (f, 2) }
            return (f, 1)
        }
        let isSava = Lexicon.savaWords.contains(t.norm)
        let isSaade = Lexicon.saadeWords.contains(t.norm)
        let isPaune = Lexicon.pauneWords.contains(t.norm)
        if isSava || isSaade || isPaune {
            if let n = integer(in: u, at: i + 1) {
                let base = Double(n.value)
                return (isSava ? base + 0.25 : isSaade ? base + 0.5 : base - 0.25, 1 + n.length)
            }
            // "sava ghanta" = 1.25 hours, "paune ghanta" = 0.75
            return (isSava ? 1.25 : isPaune ? 0.75 : 1.5, 1)
        }
        if let n = integer(in: u, at: i) { return (Double(n.value), n.length) }
        if ["a", "an"].contains(t.norm) { return (1, 1) }
        return nil
    }
}
