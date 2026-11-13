import Foundation
import ZoroCore

/// A group of interchangeable label terms ("cap", "hat", "topi" → one group).
public struct LabelGroup: Sendable, Equatable, Hashable {
    /// The word the owner used (or the concept key).
    public var display: String
    /// Normalised English terms matched against stored labels.
    public var terms: Set<String>
    public init(display: String, terms: Set<String>) {
        self.display = display
        self.terms = terms
    }
}

/// What a search will look for, after language handling.
public struct SearchPlan: Sendable, Equatable {
    public var dateInterval: DateInterval?
    public var media: PhotoQuery.Media
    public var labelGroups: [LabelGroup]
    public var colours: [NamedColour]
    /// Leftover words: matched against recognised text and labels.
    public var freeTerms: [String]
    /// Every word must appear in the recognised text (from `contains_text`).
    public var requiredText: [String]
    /// Text for the optional text-image embedder.
    public var embeddingText: String?

    public init(
        dateInterval: DateInterval? = nil, media: PhotoQuery.Media = .any, labelGroups: [LabelGroup] = [],
        colours: [NamedColour] = [], freeTerms: [String] = [], requiredText: [String] = [], embeddingText: String? = nil
    ) {
        self.dateInterval = dateInterval
        self.media = media
        self.labelGroups = labelGroups
        self.colours = colours
        self.freeTerms = freeTerms
        self.requiredText = requiredText
        self.embeddingText = embeddingText
    }

    /// Whether anything besides date / media filters was asked for.
    public var hasContentCriteria: Bool {
        !labelGroups.isEmpty || !colours.isEmpty || !freeTerms.isEmpty || !requiredText.isEmpty
    }
}

/// Resolves relative day words in English, Hindi and Hinglish ("yesterday", "kal", "पिछले हफ्ते").
/// "kal" / "कल" means yesterday here: photos are always in the past.
public struct RelativeDateParser: Sendable {
    public var calendar: Calendar

    public init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2  // weeks start on Monday
        self.calendar = calendar
    }

    private enum Span: Hashable { case day(Int), week(Int), month(Int) }

    private static let words: [Span: [String]] = [
        .day(-2): ["day before yesterday", "parson", "parso", "परसों"],
        .day(0): ["today", "aaj", "आज"],
        .day(-1): ["yesterday", "kal", "कल"],
        .week(-1): ["last week", "pichhle hafte", "pichle hafte", "पिछले हफ्ते", "पिछले हफ़्ते"],
        .week(0): ["this week", "is hafte", "इस हफ्ते", "इस हफ़्ते"],
        .month(-1): ["last month", "pichhle mahine", "pichle mahine", "पिछले महीने"],
        .month(0): ["this month", "is mahine", "इस महीने"],
    ]

    /// Longest phrases first so "day before yesterday" wins over "yesterday".
    private static let phrases: [(String, Span)] = {
        var out: [(String, Span)] = []
        for (span, list) in words {
            for word in list { out.append((TextNormalizer.normalize(word), span)) }
        }
        return out.sorted { a, b in
            let la = a.0.split(separator: " ").count, lb = b.0.split(separator: " ").count
            return la == lb ? a.0 < b.0 : la > lb
        }
    }()

    /// Finds the first relative date phrase; returns the interval and the token indices it used.
    public func parse(_ tokens: [String], now: Date) -> (interval: DateInterval, consumed: Set<Int>)? {
        for (phrase, span) in Self.phrases {
            let words = phrase.split(separator: " ").map(String.init)
            guard words.count <= tokens.count else { continue }
            for start in 0...(tokens.count - words.count) where Array(tokens[start..<(start + words.count)]) == words {
                guard let interval = interval(span, now: now) else { return nil }
                return (interval, Set(start..<(start + words.count)))
            }
        }
        return nil
    }

    private func interval(_ span: Span, now: Date) -> DateInterval? {
        switch span {
        case .day(let offset):
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            return calendar.dateInterval(of: .day, for: day).map(Self.inclusive)
        case .week(let offset):
            guard let day = calendar.date(byAdding: .weekOfYear, value: offset, to: now) else { return nil }
            return calendar.dateInterval(of: .weekOfYear, for: day).map(Self.inclusive)
        case .month(let offset):
            guard let day = calendar.date(byAdding: .month, value: offset, to: now) else { return nil }
            return calendar.dateInterval(of: .month, for: day).map(Self.inclusive)
        }
    }

    private static func inclusive(_ i: DateInterval) -> DateInterval {
        DateInterval(start: i.start, end: i.end.addingTimeInterval(-0.001))
    }
}

/// Turns a contract PhotoQuery into a `SearchPlan`.
///
/// When the backend already extracted `labels` / `colors`, those are used as given (expanded through
/// the synonym lexicon) and the text only feeds the embedder. When only `text` is present (the device
/// parsing offline), the text is scanned for date phrases, colour words, concept words and leftovers.
public struct QueryInterpreter: Sendable {
    public var lexicon: SynonymLexicon
    public var colourLexicon: ColourLexicon
    public var dates: RelativeDateParser

    public init(lexicon: SynonymLexicon = .standard, colourLexicon: ColourLexicon = .standard, timeZone: TimeZone) {
        self.lexicon = lexicon
        self.colourLexicon = colourLexicon
        self.dates = RelativeDateParser(timeZone: timeZone)
    }

    public func plan(for request: PhotoQuery, now: Date) -> SearchPlan {
        var plan = SearchPlan(dateInterval: request.dateInterval(in: dates.calendar.timeZone), media: request.media)
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.embeddingText = trimmed.isEmpty ? nil : trimmed
        plan.requiredText = request.containsText.map(TextNormalizer.tokens) ?? []

        let structured = !request.labels.isEmpty || !request.colors.isEmpty
        if structured {
            for colour in request.colors {
                appendColour(colourLexicon.colour(for: colour), to: &plan)
            }
            for label in request.labels { appendLabel(label, to: &plan) }
            return plan
        }

        var tokens = TextNormalizer.tokens(trimmed)
        if let found = dates.parse(tokens, now: now) {
            if plan.dateInterval == nil { plan.dateInterval = found.interval }
            tokens = tokens.enumerated().filter { !found.consumed.contains($0.offset) }.map(\.element)
        }
        var remaining: [String] = []
        for token in tokens {
            if let colour = colourLexicon.colour(for: token) {
                appendColour(colour, to: &plan)
            } else {
                remaining.append(token)
            }
        }
        let scan = lexicon.scan(remaining)
        for match in scan.matches {
            if match.concepts.contains(where: { $0.key == "screenshot" }) && plan.media == .any {
                plan.media = .screenshot
                continue
            }
            appendGroup(LabelGroup(display: match.phrase, terms: match.concepts.reduce(into: Set()) { $0.formUnion($1.labelTerms) }), to: &plan)
        }
        for (i, token) in remaining.enumerated() where !scan.consumed.contains(i) {
            guard !QueryStopwords.all.contains(token), token.count >= 2, !plan.freeTerms.contains(token) else { continue }
            plan.freeTerms.append(token)
        }
        return plan
    }

    private func appendColour(_ colour: NamedColour?, to plan: inout SearchPlan) {
        guard let colour, !plan.colours.contains(colour) else { return }
        plan.colours.append(colour)
    }

    private func appendLabel(_ label: String, to plan: inout SearchPlan) {
        let normal = TextNormalizer.normalize(label)
        guard !normal.isEmpty else { return }
        appendGroup(LabelGroup(display: normal, terms: lexicon.expand(normal)), to: &plan)
    }

    /// Groups that share a term are merged ("cap" and "hat" are one thing to look for).
    private func appendGroup(_ group: LabelGroup, to plan: inout SearchPlan) {
        if let i = plan.labelGroups.firstIndex(where: { !$0.terms.isDisjoint(with: group.terms) }) {
            plan.labelGroups[i].terms.formUnion(group.terms)
        } else {
            plan.labelGroups.append(group)
        }
    }
}
