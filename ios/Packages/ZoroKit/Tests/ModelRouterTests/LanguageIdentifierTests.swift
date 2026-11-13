import Testing
@testable import ModelRouter

@Suite struct LanguageIdentifierTests {
    typealias Sample = (String, SpokenLanguage)

    static let english: [Sample] = [
        ("set an alarm for six thirty", .english),
        ("what is the weather like today", .english),
        ("play some music", .english),
        ("show me photos from yesterday", .english),
        ("remind me to call mom", .english),
        ("open settings", .english),
        ("how much did I spend on food last month", .english),
        ("can you pause the music", .english),
        ("I want to buy a new phone", .english),
        ("what's on my calendar", .english),
        ("next meeting", .english),
        ("compare prices of the iPhone 17", .english),
    ]
    static let hindi: [Sample] = [
        ("मुझे कल सुबह उठा देना", .hindi),
        ("आज का मौसम कैसा है", .hindi),
        ("गाना चलाओ", .hindi),
        ("मेरी तस्वीरें दिखाओ", .hindi),
        ("पांच मिनट का टाइमर लगाओ", .hindi),
        ("सेटिंग्स खोलो", .hindi),
        ("मुझे याद दिलाना कि दूध लाना है", .hindi),
        ("कल की मीटिंग कब है", .hindi),
        ("मेरा खर्च दिखाओ", .hindi),
        ("अलार्म बंद करो", .hindi),
    ]
    static let hinglish: [Sample] = [
        ("kal subah 6 baje alarm laga do", .hinglish),
        ("mujhe yaad dilana ki doodh lana hai", .hinglish),
        ("gaana chalao", .hinglish),
        ("meri photos dikhao", .hinglish),
        ("kitna kharcha hua is mahine", .hinglish),
        ("aaj ka weather kaisa hai", .hinglish),
        ("5 minute ka timer lagao", .hinglish),
        ("arijit singh ke gaane bajao", .hinglish),
        ("mera schedule batao", .hinglish),
        ("yaar thoda music chala do", .hinglish),
        ("tum kya kar rahe ho", .hinglish),
        ("call mom kal", .hinglish),
    ]
    /// Devanagari and Latin words in one sentence.
    static let mixedScript: [Sample] = [
        ("मुझे photo दिखाओ", .hindi),
        ("alarm सेट करो", .hindi),
        ("Spotify पर गाना चलाओ", .hindi),
        ("show राहुल की photos", .hinglish),
        ("play kesariya वाला गाना", .hinglish),
        ("Call मम्मी", .hinglish),
    ]

    static let all: [Sample] = english + hindi + hinglish + mixedScript

    @Test func tableHasEnoughSamplesInEveryLanguage() {
        #expect(Self.all.count >= 30)
        #expect(Self.english.count >= 10 && Self.hindi.count >= 10 && Self.hinglish.count >= 10)
    }

    @Test(arguments: LanguageIdentifierTests.all)
    func identifiesLanguage(sample: Sample) {
        let result = LanguageIdentifier.identify(sample.0)
        #expect(result.language == sample.1, "\(sample.0) -> \(result.language)")
        #expect(result.confidence > 0.5)
    }

    @Test func mixedScriptIsFlagged() {
        #expect(LanguageIdentifier.identify("मुझे photo दिखाओ").isMixedScript)
        #expect(!LanguageIdentifier.identify("मुझे दिखाओ").isMixedScript)
        #expect(!LanguageIdentifier.identify("show me").isMixedScript)
    }

    @Test func emptyAndDigitOnlyTextHasNoConfidence() {
        #expect(LanguageIdentifier.identify("").confidence == 0)
        #expect(LanguageIdentifier.identify("   ").confidence == 0)
        #expect(LanguageIdentifier.identify("12345").confidence == 0)
        #expect(LanguageIdentifier.identify("१२३").confidence == 0)
    }

    @Test func ambiguousEnglishWordsDoNotMakeHinglish() {
        // "to", "do", "me", "so", "he" are Romanised Hindi words too; alone they must not flip English.
        #expect(LanguageIdentifier.identify("I want to do it so he can see me").language == .english)
        #expect(LanguageIdentifier.identify("hi there").language == .english)
    }

    @Test func devanagariDigitsAndNuktaDoNotBreakIdentification() {
        #expect(LanguageIdentifier.identify("५ मिनट का टाइमर").language == .hindi)
        #expect(LanguageIdentifier.identify("फ़ोटो दिखाओ").language == .hindi)
    }

    @Test func hintIsUsedOnlyWhenTextSaysLittle() {
        let weak = LanguageIdentifier.identify("ok")
        #expect(LocalIntentClassifier.resolve(weak, hint: "hi") == .hindi)
        let strong = LanguageIdentifier.identify("मेरा खर्च दिखाओ")
        #expect(LocalIntentClassifier.resolve(strong, hint: "en") == .hindi)
        #expect(LocalIntentClassifier.resolve(weak, hint: "nonsense") == .english)
    }

    @Test func lexiconEntriesAreInNormalisedForm() {
        let sets: [Set<String>] = [
            Lexicon.romanHindiStrong, Lexicon.romanHindiWeak, Lexicon.photoNouns, Lexicon.screenshotNouns, Lexicon.timerWords,
            Lexicon.alarmWords, Lexicon.calendarWords, Lexicon.musicNouns, Lexicon.musicFillers, Lexicon.openFillers,
            Lexicon.openVerbs, Lexicon.playWords, Lexicon.pauseWords, Lexicon.stopWords, Lexicon.nextTrack, Lexicon.previousTrack,
            Lexicon.morning, Lexicon.evening, Lexicon.night, Lexicon.afternoon, Lexicon.hourUnits, Lexicon.minuteUnits,
            Lexicon.weekUnits, Lexicon.monthUnits, Lexicon.kal, Lexicon.parso, Lexicon.nextWords, Lexicon.lastWords,
        ]
        for entry in sets.flatMap({ $0 }) { #expect(Script.normalize(entry) == entry, "\(entry)") }
        let keys = Array(Lexicon.numberWords.keys) + Array(Lexicon.weekdays.keys) + Array(Lexicon.months.keys)
            + Array(Lexicon.colors.keys) + Array(Lexicon.photoLabels.keys) + Array(Lexicon.fractionWords.keys)
        for entry in keys { #expect(Script.normalize(entry) == entry, "\(entry)") }
        for words in Lexicon.sectionWords.values { for w in words { #expect(Script.normalize(w) == w, "\(w)") } }
    }
}
