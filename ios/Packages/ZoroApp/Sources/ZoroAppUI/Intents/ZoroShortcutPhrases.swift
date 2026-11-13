import Foundation

/// The App Shortcuts catalogue, mirrored from `AppTargetTemplates/ZOROShortcuts.swift` (the provider must
/// be compiled in the app target) and `AppTargetTemplates/AppShortcuts.xcstrings` (Hindi phrases).
/// Tests parse both files and check that they match this catalogue, that every phrase carries the
/// application-name token exactly once, and that the counts are within Apple's limits.
///
/// Keys use the String Catalog form: `${applicationName}` for the app name and `${parameter}` for a
/// parameter, as in `AppShortcuts.xcstrings`. English and Hinglish phrases are in code (Siri's English
/// (India) recognises Latin-script Hinglish); Devanagari phrases are the `hi` localisation.
public enum ZoroShortcutPhrases {
    public static let appNameToken = "${applicationName}"

    public enum Script: String, Sendable, Equatable { case english, hinglish }

    public struct Phrase: Sendable, Equatable {
        /// The phrase as written in code / the String Catalog key.
        public var key: String
        public var script: Script
        /// The `hi` localisation of this phrase.
        public var hindi: String

        public init(_ key: String, _ script: Script, hindi: String) {
            self.key = key
            self.script = script
            self.hindi = hindi
        }
    }

    public struct Shortcut: Sendable, Equatable {
        /// The intent type's name.
        public var intent: String
        public var shortTitle: String
        public var systemImageName: String
        public var phrases: [Phrase]

        public init(intent: String, shortTitle: String, systemImageName: String, phrases: [Phrase]) {
            self.intent = intent
            self.shortTitle = shortTitle
            self.systemImageName = systemImageName
            self.phrases = phrases
        }
    }

    /// Apple allows at most 10 App Shortcuts per app (WWDC22 "Implement App Shortcuts with App Intents").
    public static let maxShortcuts = 10
    /// Phrases after expanding each parameter's cases; Apple's documented ceiling is 1,000 per app.
    public static let maxExpandedPhrases = 1_000
    /// Kept short so they fit Spotlight and Shortcuts tiles.
    public static let maxShortTitleLength = 24
    /// Apple's guidance: one parameter per phrase.
    public static let maxParametersPerPhrase = 1

    /// Number of values each phrase parameter can take, for the expansion count.
    public static let parameterCaseCounts: [String: Int] = [
        "section": AppSection.allCases.count,
        "period": SpendingPeriod.allCases.count,
        "category": SpendingCategory.allCases.count,
    ]

    public static let all: [Shortcut] = [
        Shortcut(intent: "AskZoroIntent", shortTitle: "Ask ZORO", systemImageName: "circle.circle", phrases: [
            Phrase("Ask ${applicationName}", .english, hindi: "${applicationName} से पूछें"),
            Phrase("Ask ${applicationName} something", .english, hindi: "${applicationName} से कुछ पूछें"),
            Phrase("${applicationName} se poochho", .hinglish, hindi: "${applicationName} से पूछो"),
            Phrase("${applicationName} se kuch poochna hai", .hinglish, hindi: "${applicationName} से कुछ पूछना है"),
        ]),
        Shortcut(intent: "StartVoiceIntent", shortTitle: "Talk to ZORO", systemImageName: "waveform", phrases: [
            Phrase("Talk to ${applicationName}", .english, hindi: "${applicationName} से बात करें"),
            Phrase("Start ${applicationName} voice", .english, hindi: "${applicationName} वॉइस शुरू करें"),
            Phrase("${applicationName} se baat karo", .hinglish, hindi: "${applicationName} से बात करो"),
        ]),
        Shortcut(intent: "CheckSpendingIntent", shortTitle: "Check spending", systemImageName: "indianrupeesign", phrases: [
            Phrase("Ask ${applicationName} how much I spent ${period}", .english, hindi: "${applicationName} से पूछें ${period} कितना खर्च हुआ"),
            Phrase("Ask ${applicationName} how much I spent on ${category}", .english, hindi: "${applicationName} से पूछें ${category} पर कितना खर्च हुआ"),
            Phrase("Check my spending in ${applicationName}", .english, hindi: "${applicationName} में मेरा खर्च देखें"),
            Phrase("${applicationName} se poochho ${period} kitna kharch hua", .hinglish, hindi: "${applicationName} से पूछो ${period} कितना खर्च हुआ"),
        ]),
        Shortcut(intent: "CompareBasketIntent", shortTitle: "Compare basket", systemImageName: "basket", phrases: [
            Phrase("Compare my basket with ${applicationName}", .english, hindi: "${applicationName} से मेरी बास्केट की तुलना करें"),
            Phrase("Ask ${applicationName} to compare my basket", .english, hindi: "${applicationName} से बास्केट की कीमतें मिलाएँ"),
            Phrase("${applicationName} basket compare karo", .hinglish, hindi: "${applicationName} बास्केट की तुलना करो"),
        ]),
        Shortcut(intent: "PlayMusicIntent", shortTitle: "Play music", systemImageName: "music.note", phrases: [
            Phrase("Play music with ${applicationName}", .english, hindi: "${applicationName} से गाना चलाएँ"),
            Phrase("Ask ${applicationName} to play something", .english, hindi: "${applicationName} से कुछ चलवाएँ"),
            Phrase("${applicationName} gaana chalao", .hinglish, hindi: "${applicationName} गाना चलाओ"),
        ]),
        Shortcut(intent: "RememberThisIntent", shortTitle: "Remember this", systemImageName: "brain", phrases: [
            Phrase("Ask ${applicationName} to remember something", .english, hindi: "${applicationName} से कुछ याद रखने को कहें"),
            Phrase("Remember this with ${applicationName}", .english, hindi: "${applicationName} यह याद रखें"),
            Phrase("${applicationName} yaad rakhna", .hinglish, hindi: "${applicationName} याद रखना"),
        ]),
        Shortcut(intent: "FindPhotoIntent", shortTitle: "Find a photo", systemImageName: "photo.on.rectangle", phrases: [
            Phrase("Find a photo with ${applicationName}", .english, hindi: "${applicationName} से फ़ोटो ढूँढें"),
            Phrase("Search photos in ${applicationName}", .english, hindi: "${applicationName} में फ़ोटो खोजें"),
            Phrase("${applicationName} photo dhoondo", .hinglish, hindi: "${applicationName} फ़ोटो ढूँढो"),
        ]),
        Shortcut(intent: "SwitchToPrivateModeIntent", shortTitle: "Private mode", systemImageName: "lock.shield", phrases: [
            Phrase("Turn on private mode in ${applicationName}", .english, hindi: "${applicationName} में प्राइवेट मोड चालू करें"),
            Phrase("Switch ${applicationName} to private mode", .english, hindi: "${applicationName} को प्राइवेट मोड में करें"),
            Phrase("${applicationName} private mode on karo", .hinglish, hindi: "${applicationName} प्राइवेट मोड चालू करो"),
        ]),
        Shortcut(intent: "OpenSectionIntent", shortTitle: "Open a section", systemImageName: "square.grid.2x2", phrases: [
            Phrase("Open ${section} in ${applicationName}", .english, hindi: "${applicationName} में ${section} खोलें"),
            Phrase("Show ${applicationName} ${section}", .english, hindi: "${applicationName} का ${section} दिखाएँ"),
            Phrase("${applicationName} mein ${section} kholo", .hinglish, hindi: "${applicationName} में ${section} खोलो"),
        ]),
    ]

    /// Parameter names in a phrase ("${period}" → "period"), excluding the app name.
    public static func parameters(in phrase: String) -> [String] {
        var names: [String] = []
        var rest = phrase[...]
        while let start = rest.range(of: "${"), let end = rest[start.upperBound...].firstIndex(of: "}") {
            let name = String(rest[start.upperBound..<end])
            if name != "applicationName" { names.append(name) }
            rest = rest[rest.index(after: end)...]
        }
        return names
    }

    public static func occurrences(of token: String, in phrase: String) -> Int {
        phrase.components(separatedBy: token).count - 1
    }

    /// How many phrases Siri learns once each parameter is expanded to its cases.
    public static var expandedPhraseCount: Int {
        all.flatMap(\.phrases).reduce(0) { total, phrase in
            let perScript = parameters(in: phrase.key).reduce(1) { $0 * (parameterCaseCounts[$1] ?? 1) }
            return total + perScript * 2 // the code phrase plus its Hindi localisation
        }
    }

    /// The phrase the tip shows, with the app's name filled in and a trailing ellipsis.
    public static func tipPhrase(_ language: ZoroLanguage, appName: String = "ZORO") -> String {
        let ask = all[0].phrases
        let raw: String
        switch language {
        case .english: raw = ask.first { $0.script == .english }!.key
        case .hindi: raw = ask[0].hindi
        case .hinglish: raw = ask.first { $0.script == .hinglish }!.key
        }
        var spoken = raw.replacingOccurrences(of: appNameToken, with: appName)
        if language == .english, let first = spoken.first { spoken = first.lowercased() + spoken.dropFirst() }
        return "\(spoken) …"
    }
}
