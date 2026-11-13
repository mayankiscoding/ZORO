import Foundation
import ZoroCore

/// Parses the owner's words into ZoroCore's contract `PhotoQuery` without a network or a model: dates resolved in the
/// owner's time zone, colour and object words in English, Hindi and Hinglish. Used offline, and as the
/// reference for what the backend `vision` package produces.
public struct PhotoQueryParser: Sendable {
    public var clock: @Sendable () -> Date
    public var timeZone: TimeZone
    public var limit: Int

    public init(clock: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current, limit: Int = 30) {
        self.clock = clock
        self.timeZone = timeZone
        self.limit = limit
    }

    public func parse(_ text: String) -> PhotoQuery {
        var u = Utterance(text)
        return parse(&u, original: text)
    }

    func parse(_ u: inout Utterance, original: String) -> PhotoQuery {
        let parser = TemporalParser(now: clock(), timeZone: timeZone)
        let when = parser.parse(&u, direction: .past, allowBareHour: false)

        var from: CalendarDate?
        var to: CalendarDate?
        if let range = when.range {
            from = CalendarDate(date: range.start, timeZone: timeZone)
            to = CalendarDate(date: parser.addDays(-1, to: range.end), timeZone: timeZone)
        } else if let day = when.dayStart {
            from = CalendarDate(date: day, timeZone: timeZone)
            to = from
        }

        var colors: [String] = []
        var labels: [String] = []
        var media = PhotoQuery.Media.any
        for token in u.tokens {
            if let color = Lexicon.colors[token.norm], !colors.contains(color) { colors.append(color) }
            if let found = Lexicon.photoLabels[token.norm] {
                for label in found where !labels.contains(label) { labels.append(label) }
            }
            if Lexicon.screenshotNouns.contains(token.norm) { media = .screenshot }
        }
        return PhotoQuery(
            text: original.trimmingCharacters(in: .whitespacesAndNewlines), dateFrom: from, dateTo: to, colors: colors,
            labels: labels, containsText: Self.quotedText(original) ?? Self.saidText(u), media: media, limit: limit)
    }

    /// Text inside double quotes: `screenshot of "boarding pass"`.
    private static func quotedText(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        let quotes: Set<UInt32> = [0x22, 0x201C, 0x201D]
        guard let start = scalars.firstIndex(where: { quotes.contains($0.value) }),
              let end = scalars[(start + 1)...].firstIndex(where: { quotes.contains($0.value) }), end > start + 1
        else { return nil }
        let inner = String(String.UnicodeScalarView(scalars[(start + 1)..<end])).trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }

    /// "that says hello", "saying sale 50% off": the rest of the sentence after the cue.
    private static func saidText(_ u: Utterance) -> String? {
        guard let i = u.tokens.indices.first(where: { ["says", "saying", "reads"].contains(u.tokens[$0].norm) }) else { return nil }
        let rest = ((i + 1)..<u.count).filter(u.isFree).map { u.tokens[$0].text }.joined(separator: " ")
        return rest.isEmpty ? nil : rest
    }
}
