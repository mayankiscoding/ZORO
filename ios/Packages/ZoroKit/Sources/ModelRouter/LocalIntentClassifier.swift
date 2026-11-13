import Foundation
import ZoroCore

/// Understands the commands the device can do alone and offline: alarm, timer, reminder, calendar
/// lookup, music control, photo search and opening a section of the app, in English, Hindi and Hinglish.
///
/// Rules first (deterministic, no model, no network). When the rules find nothing and the text is
/// English, an optional on-device model may normalise the phrasing; its answer goes through the same
/// rules again. Returns nil for anything else, which then goes to the backend.
///
/// Confidence: `0.9...` when every required slot was found; `0.5` when the command is recognised but
/// a required slot is missing (the router then asks for the detail or hands the turn to the backend).
public struct LocalIntentClassifier: LocalIntentClassifying {
    /// Below this the device does not act alone.
    public static let minimumActionableConfidence = 0.75

    public var clock: @Sendable () -> Date
    public var timeZone: TimeZone
    /// A reminder with a day but no time is due at this local hour (an assumption, stated, not data).
    public var dateOnlyReminderHour: Int
    public var assist: (any OnDeviceIntentAssisting)?

    public init(
        clock: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current, dateOnlyReminderHour: Int = 9,
        assist: (any OnDeviceIntentAssisting)? = nil
    ) {
        self.clock = clock
        self.timeZone = timeZone
        self.dateOnlyReminderHour = dateOnlyReminderHour
        self.assist = assist
    }

    public func classify(_ text: String, languageHint: String?) async -> LocalIntent? {
        let identification = LanguageIdentifier.identify(text)
        let language = Self.resolve(identification, hint: languageHint)
        if let result = classifyByRules(text, language: language), result.confidence >= Self.minimumActionableConfidence {
            return result
        }
        let partial = classifyByRules(text, language: language)
        guard language == .english, identification.confidence >= 0.5, let assist, !Task.isCancelled, await assist.isAvailable() else {
            return partial
        }
        guard let guess = try? await assist.guess(for: text), let command = guess.canonicalCommand,
              var assisted = classifyByRules(command, language: .english), assisted.confidence >= Self.minimumActionableConfidence
        else { return partial }
        assisted.confidence = min(assisted.confidence, 0.85)
        return assisted
    }

    /// Synchronous rule-based path (also used by the model-assisted path and by tests).
    public func classifyByRules(_ text: String, language: SpokenLanguage? = nil) -> LocalIntent? {
        let lang = language ?? LanguageIdentifier.identify(text).language
        let ctx = Context(parser: TemporalParser(now: clock(), timeZone: timeZone), reminderHour: dateOnlyReminderHour, photos: PhotoQueryParser(clock: clock, timeZone: timeZone))
        let utterance = Utterance(text)
        guard utterance.count > 0 else { return nil }
        let matchers: [(Utterance, Context) -> Match?] = [
            Self.openSection, Self.timer, Self.reminder, Self.alarm, Self.calendar, Self.music, Self.photos,
        ]
        for matcher in matchers {
            if let m = matcher(utterance, ctx) {
                return LocalIntent(name: m.name, tool: LocalIntentTools.tool(for: m.name), confidence: m.confidence, slots: m.slots, language: lang.rawValue)
            }
        }
        return nil
    }

    static func resolve(_ id: LanguageIdentification, hint: String?) -> SpokenLanguage {
        if id.confidence < 0.6, let hint, let hinted = SpokenLanguage(rawValue: hint.lowercased()) { return hinted }
        return id.language
    }

    // MARK: Matching

    struct Context {
        let parser: TemporalParser
        let reminderHour: Int
        let photos: PhotoQueryParser
    }

    struct Match {
        var name: String
        var confidence: Double
        var slots: JSONObject
    }

    private static let complete = 0.92
    private static let incomplete = 0.5

    // MARK: Timer

    static func timer(_ original: Utterance, _ ctx: Context) -> Match? {
        var u = original
        guard u.contains(any: Lexicon.timerWords) else { return nil }
        let when = ctx.parser.parse(&u, direction: .future)
        guard let seconds = when.durationSeconds, seconds > 0 else {
            return Match(name: LocalIntentName.timer, confidence: incomplete, slots: [:])
        }
        return Match(name: LocalIntentName.timer, confidence: complete, slots: ["seconds": .number(Double(seconds))])
    }

    // MARK: Alarm

    static func alarm(_ original: Utterance, _ ctx: Context) -> Match? {
        var u = original
        let explicit = u.contains(any: Lexicon.alarmWords)
        let wake = u.contains(any: Lexicon.wakeWords) || u.index(ofPhrase: ["wake", "me"]) != nil || u.index(ofPhrase: ["wake", "me", "up"]) != nil
        guard explicit || wake else { return nil }
        let when = ctx.parser.parse(&u, direction: .future)
        guard let instant = ctx.parser.resolveInstant(when, style: .morning, defaultHour: 7), when.hasTime || when.durationSeconds != nil else {
            // "wake" words alone are too weak to claim the command.
            return explicit ? Match(name: LocalIntentName.alarm, confidence: incomplete, slots: [:]) : nil
        }
        var slots: JSONObject = ["time": .string(ctx.parser.clockString(instant))]
        if when.repeating { slots["repeat_days"] = .array(when.repeatDays.map { .string($0) }) }
        return Match(name: LocalIntentName.alarm, confidence: complete, slots: slots)
    }

    // MARK: Reminder

    private static let reminderTrailing: Set<String> = [
        "ka", "ki", "ke", "ko", "to", "for", "a", "an", "the", "lagao", "laga", "lagana", "lagado", "lagaiye", "do", "dena", "de", "dijiye",
        "kar", "karo", "kijiye", "ek", "please", "mujhe", "me", "set", "add", "create", "make", "pls", "zoro", "and", "aur", "that", "about",
        "का", "की", "के", "को", "लगाओ", "लगा", "लगाना", "दो", "देना", "दे", "दीजिए", "कर", "करो", "कीजिए", "एक", "मुझे", "कृपया", "और",
        "me", "mein", "में", "tak", "तक", "pe", "par", "पर", "se", "से", "bhi", "भी", "toh", "तो",
    ]
    private static let reminderLeading: Set<String> = [
        "me", "mujhe", "mera", "meri", "mere", "to", "that", "about", "for", "a", "an", "the", "set", "add", "create", "make", "ek",
        "ki", "ke", "ka", "ko", "please", "pls", "i", "need", "want", "should", "must", "zoro", "can", "you", "could", "also", "and", "aur",
        "मुझे", "मेरा", "मेरी", "मेरे", "एक", "कृपया", "की", "के", "का", "को", "और", "me", "mein", "में", "bhi", "भी", "toh", "तो",
        "reminder", "remind", "रिमाइंडर", "lagao", "लगाओ", "bas", "zara", "ज़रा", "जरा",
    ]
    private static let remindSecond: Set<String> = ["dilana", "dilao", "dila", "dilaye", "dilado", "dilaiye", "dilaiyega", "दिलाना", "दिलाओ", "दिला", "दिलाइए", "दिलादो", "दिलाएं", "दिलाइएगा"]
    private static let remindWords: Set<String> = ["remind", "reminder", "reminders", "रिमाइंडर", "रिमाइंड", "reminderr"]

    static func reminder(_ original: Utterance, _ ctx: Context) -> Match? {
        var u = original
        var triggered = false
        for i in 0..<u.count where u.isFree(i) {
            let w = u.tokens[i].norm
            if remindWords.contains(w) { u.consume(i); triggered = true }
            else if w == "yaad" || w == "याद", i + 1 < u.count,
                    let j = (i + 1...min(i + 2, u.count - 1)).first(where: { u.isFree($0) && remindSecond.contains(u.tokens[$0].norm) }) {
                u.consume(i)
                u.consume(j)
                triggered = true
            }
        }
        guard triggered else { return nil }
        let when = ctx.parser.parse(&u, direction: .future)
        let title = u.remainder(leading: reminderLeading, trailing: reminderTrailing).map(\.text).joined(separator: " ")
        guard !title.isEmpty else { return Match(name: LocalIntentName.reminder, confidence: incomplete, slots: [:]) }
        var slots: JSONObject = ["title": .string(title)]
        if let due = ctx.parser.resolveInstant(when, style: .daytime, defaultHour: ctx.reminderHour) {
            slots["due_at"] = .string(ctx.parser.isoString(due))
        }
        return Match(name: LocalIntentName.reminder, confidence: complete, slots: slots)
    }

    // MARK: Calendar lookup

    static func calendar(_ original: Utterance, _ ctx: Context) -> Match? {
        var u = original
        guard u.contains(any: Lexicon.calendarWords) else { return nil }
        if u.contains(any: Lexicon.calendarBlockers) || u.contains(any: Lexicon.photoNouns) || u.contains(any: Lexicon.screenshotNouns) { return nil }
        if let i = u.firstIndex(in: ["schedule", "शेड्यूल"]), u.isFree(i + 1), ["a", "an", "ek", "एक"].contains(u.norm(i + 1) ?? "") { return nil }
        let singular = u.contains(any: ["meeting", "appointment", "event", "मीटिंग", "अपॉइंटमेंट", "इवेंट"])
        let nextOne = u.contains(any: Lexicon.nextWords) && singular
        let when = ctx.parser.parse(&u, direction: .future)
        var slots: JSONObject = [:]
        if let range = when.range {
            slots["from"] = .string(ctx.parser.isoString(range.start))
            slots["to"] = .string(ctx.parser.isoString(range.end))
        } else if let day = when.dayStart {
            slots["from"] = .string(ctx.parser.isoString(day))
            slots["to"] = .string(ctx.parser.isoString(ctx.parser.addDays(1, to: day)))
        } else {
            slots["from"] = .string(ctx.parser.isoString(ctx.parser.now))
        }
        if nextOne && when.dayStart == nil && when.range == nil { slots["limit"] = .number(1) }
        let confident = when.dayStart != nil || when.range != nil || nextOne
        return Match(name: LocalIntentName.calendarLookup, confidence: confident ? complete : 0.85, slots: slots)
    }

    // MARK: Music

    private static let queryLeading: Set<String> = Lexicon.musicFillers
    private static let queryTrailing: Set<String> = Lexicon.musicFillers

    static func music(_ original: Utterance, _ ctx: Context) -> Match? {
        var u = original
        let hasNoun = u.contains(any: Lexicon.musicNouns)
        let provider = u.contains(any: Lexicon.spotifyWords) ? "spotify_app" : "apple_music"
        func result(_ action: String, query: String? = nil, confidence: Double = complete) -> Match {
            var slots: JSONObject = ["provider": .string(provider), "action": .string(action)]
            if let query { slots["query"] = .string(query) }
            return Match(name: LocalIntentName.musicControl, confidence: confidence, slots: slots)
        }
        let sparse = u.count <= 3
        if u.contains(any: Lexicon.pauseWords) { return result("pause") }
        if u.contains(any: Lexicon.stopWords), hasNoun || u.count == 1 { return result("pause") }
        if u.contains(any: Lexicon.nextTrack), hasNoun || sparse { return result("next") }
        if u.contains(any: Lexicon.previousTrack), hasNoun || u.count <= 2 { return result("previous") }
        guard u.contains(any: Lexicon.playWords) else { return nil }

        // Remove the command words, the app name and "music"/"song" nouns; what is left is what to play.
        for i in 0..<u.count where u.isFree(i) {
            let w = u.tokens[i].norm
            if Lexicon.playWords.contains(w) || Lexicon.musicNouns.contains(w) || Lexicon.spotifyWords.contains(w) { u.consume(i) }
            else if Lexicon.appleMusicWords.contains(w), u.norm(i + 1) == "music" || u.norm(i + 1) == "म्यूजिक" { u.consume(i) }
        }
        let words = u.remainder(leading: queryLeading, trailing: queryTrailing)
        let query = words.map(\.text).joined(separator: " ")
        return query.isEmpty ? result("play") : result("search_play", query: query)
    }

    // MARK: Photos

    static func photos(_ original: Utterance, _ ctx: Context) -> Match? {
        var u = original
        guard u.contains(any: Lexicon.photoNouns) || u.contains(any: Lexicon.screenshotNouns) else { return nil }
        if u.contains(any: Lexicon.photoBlockers) { return nil }
        let query = ctx.photos.parse(&u, original: original.original)
        let filtered = !query.isUnfiltered
        return Match(name: LocalIntentName.photoSearch, confidence: filtered ? complete : 0.8, slots: ["query": .object(query.json)])
    }

    // MARK: Open a section

    static func openSection(_ original: Utterance, _ ctx: Context) -> Match? {
        var u = original
        var section: String?
        for (phrase, id) in Lexicon.sectionPhrases {
            if let i = u.index(ofPhrase: phrase) { section = id; u.consume(i..<(i + phrase.count)); break }
        }
        if section == nil {
            for i in 0..<u.count where u.isFree(i) {
                if let id = Lexicon.sectionWords.first(where: { $0.value.contains(u.tokens[i].norm) })?.key {
                    section = id
                    u.consume(i)
                    break
                }
            }
        }
        guard let section else { return nil }
        let hasVerb = u.contains(any: Lexicon.openVerbs) || original.index(ofPhrase: ["take", "me"]) != nil
        guard hasVerb || (u.count == 1 && original.count == 1) else { return nil }
        let leftover = u.remainder(dropping: Lexicon.openVerbs.union(Lexicon.openFillers).union(["take"]))
        guard leftover.isEmpty else { return nil }
        return Match(name: LocalIntentName.openSection, confidence: complete, slots: ["section": .string(section)])
    }
}
