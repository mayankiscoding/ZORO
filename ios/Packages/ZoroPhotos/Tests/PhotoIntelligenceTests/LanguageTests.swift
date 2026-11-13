import Foundation
import Testing
import ZoroCore
@testable import PhotoIntelligence

@Suite("Synonyms, colour words and query parsing in English, Hindi and Hinglish")
struct LanguageTests {
    let lexicon = SynonymLexicon.standard
    let colours = ColourLexicon.standard
    let interpreter = QueryInterpreter(timeZone: ist)

    @Test func normaliserFoldsNuktaDiacriticsAndPunctuation() {
        #expect(TextNormalizer.normalize("सफ़ेद") == TextNormalizer.normalize("सफेद"))
        #expect(TextNormalizer.normalize("Café_Menu!") == "cafe menu")
        #expect(TextNormalizer.normalize("sunset_sunrise") == "sunset sunrise")
        #expect(TextNormalizer.tokens("नीली टोपी, वाली।") == ["नीली", "टोपी", "वाली"])
        #expect(TextNormalizer.normalize("चाँद") == TextNormalizer.normalize("चांद"))
    }

    @Test("one concept in three languages", arguments: ["cap", "hat", "topi", "टोपी", "TOPI"])
    func headwearExpansion(_ word: String) {
        let terms = lexicon.expand(word)
        #expect(terms.contains("cap"))
        #expect(terms.contains("hat"))
        #expect(terms.contains("baseball cap"))
    }

    @Test(arguments: [("kutta", "dog"), ("कुत्ता", "dog"), ("billi", "cat"), ("बिल्ली", "cat"), ("samundar", "beach"),
                      ("समुद्र", "beach"), ("shaadi", "wedding"), ("शादी", "wedding"), ("raseed", "receipt"), ("रसीद", "bill")])
    func hindiAndHinglishMapToEnglishLabels(_ word: String, _ english: String) {
        #expect(lexicon.expand(word).contains(english))
    }

    @Test func unknownWordExpandsToItself() {
        #expect(lexicon.expand("Zebra") == ["zebra"])
        #expect(lexicon.expand("  ").isEmpty)
    }

    @Test func multiWordPhrasesWinOverSingleWords() {
        let scan = lexicon.scan(TextNormalizer.tokens("hawai jahaz ki photo"))
        #expect(scan.matches.first?.phrase == "hawai jahaz")
        #expect(scan.matches.first?.concepts.first?.key == "airplane")
        #expect(scan.consumed == [0, 1])
    }

    @Test(arguments: [("blue", NamedColour.blue), ("neela", .blue), ("neeli", .blue), ("नीली", .blue), ("नीले", .blue),
                      ("laal", .red), ("लाल", .red), ("safed", .white), ("सफ़ेद", .white), ("सफेद", .white),
                      ("kaali", .black), ("काला", .black), ("gulabi", .pink), ("गुलाबी", .pink), ("peela", .yellow),
                      ("हरी", .green), ("navy", .blue), ("bhura", .brown), ("जामुनी", .purple)])
    func colourWords(_ word: String, _ colour: NamedColour) {
        #expect(colours.colour(for: word) == colour)
    }

    @Test func englishSentence() {
        let plan = interpreter.plan(for: PhotoQuery(text: "photo from yesterday with my blue cap"), now: fixedNow)
        #expect(plan.colours == [.blue])
        #expect(plan.labelGroups.count == 1)
        #expect(plan.labelGroups[0].terms.contains("hat"))
        #expect(plan.freeTerms.isEmpty)
        #expect(plan.dateInterval?.start == date("2026-11-11T00:00:00+05:30"))
        #expect(plan.dateInterval!.contains(date("2026-11-11T23:59:59+05:30")))
        #expect(!plan.dateInterval!.contains(date("2026-11-12T00:00:00+05:30")))
    }

    @Test(arguments: ["kal ki neeli topi wali photo", "कल की नीली टोपी वाली फोटो"])
    func hinglishAndHindiSentences(_ text: String) {
        let plan = interpreter.plan(for: PhotoQuery(text: text), now: fixedNow)
        #expect(plan.colours == [.blue])
        #expect(plan.labelGroups.count == 1)
        #expect(plan.labelGroups[0].terms.contains("cap"))
        #expect(plan.freeTerms.isEmpty)
        #expect(plan.dateInterval?.start == date("2026-11-11T00:00:00+05:30"))
    }

    @Test func relativeRanges() {
        let parser = RelativeDateParser(timeZone: ist)
        let lastWeek = parser.parse(TextNormalizer.tokens("pichhle hafte ki photos"), now: fixedNow)
        // 2026-11-12 is a Thursday; last week is Monday 2026-11-02 to Sunday 2026-11-08.
        #expect(lastWeek?.interval.start == date("2026-11-02T00:00:00+05:30"))
        #expect(lastWeek?.interval.contains(date("2026-11-08T23:00:00+05:30")) == true)
        #expect(lastWeek?.consumed == [0, 1])
        let dby = parser.parse(TextNormalizer.tokens("day before yesterday"), now: fixedNow)
        #expect(dby?.interval.start == date("2026-11-10T00:00:00+05:30"))
        #expect(parser.parse(["beach"], now: fixedNow) == nil)
    }

    @Test func structuredQueryUsesBackendExtraction() {
        let request = PhotoQuery(text: "photo from yesterday with my blue cap", colors: ["blue"], labels: ["cap", "hat"])
        let plan = interpreter.plan(for: request, now: fixedNow)
        #expect(plan.labelGroups.count == 1, "cap and hat are one thing to look for")
        #expect(plan.colours == [.blue])
        #expect(plan.dateInterval == nil, "dates come from date_from/date_to when the backend parsed the query")
        #expect(plan.embeddingText == "photo from yesterday with my blue cap")
    }

    @Test func screenshotWordSetsMediaAndLeftoversBecomeTextTerms() {
        let plan = interpreter.plan(for: PhotoQuery(text: "screenshot of the airtel invoice"), now: fixedNow)
        #expect(plan.media == .screenshot)
        #expect(plan.freeTerms == ["airtel"])
        #expect(plan.labelGroups.first?.terms.contains("invoice") == true)
    }

    @Test func containsTextBecomesRequiredWords() {
        let plan = interpreter.plan(for: PhotoQuery(containsText: "Order #4521"), now: fixedNow)
        #expect(plan.requiredText == ["order", "4521"])
        #expect(plan.hasContentCriteria)
    }

    @Test("OCR languages: Hindi only when the OS offers it")
    func ocrLanguageSelection() {
        let withHindi = TextRecognitionLanguages.select(supported: ["en-US", "fr-FR", "hi-IN", "zh-Hans"])
        #expect(withHindi == ["en-US", "hi-IN"])
        let withoutHindi = TextRecognitionLanguages.select(supported: ["en-US", "en-GB", "de-DE"])
        #expect(withoutHindi == ["en-US", "en-GB"])
        #expect(TextRecognitionLanguages.select(supported: []).isEmpty)
    }
}
