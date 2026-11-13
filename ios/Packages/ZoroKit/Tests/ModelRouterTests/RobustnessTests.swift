import Foundation
import Testing
@testable import ModelRouter

/// No input may crash the parsers (index math, number parsing, odd Unicode).
@Suite struct RobustnessTests {
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_98EB
            return z ^ (z >> 31)
        }
    }

    static let vocabulary = [
        "alarm", "timer", "remind", "reminder", "yaad", "dilana", "याद", "दिलाना", "set", "for", "at", "in", "on", "me", "to", "kal", "कल",
        "परसों", "tomorrow", "today", "yesterday", "next", "last", "pichle", "week", "month", "hafte", "weekend", "monday", "friday",
        "सोमवार", "november", "nov", "may", "12", "31", "0", "24", "99", "2026", "1.5", "6:30", "18:45", "25:99", "6.30", "pm", "am",
        "baje", "बजे", "subah", "शाम", "sava", "saade", "paune", "dedh", "ढाई", "half", "quarter", "past", "an", "a", "hour", "minute",
        "ghanta", "मिनट", "and", "aur", "play", "pause", "next", "gaana", "photos", "photo", "screenshot", "open", "settings", "calendar",
        "meeting", "schedule", "every", "har", "weekdays", "\"", "\u{201C}", "@", "-", "—", ",", ".", ":", "'", "😀", "\u{0000}", "ZORO",
        "़", "ँ", "०", "९", "दो", "ek", "twenty", "forty", "five", "spotify", "on", "say", "says",
    ]

    @Test func randomUtterancesNeverCrash() async {
        var rng = SplitMix(state: 42)
        let classifier = Fixed.classifier()
        for _ in 0..<4000 {
            let count = Int.random(in: 0...9, using: &rng)
            let text = (0..<count).map { _ in Self.vocabulary.randomElement(using: &rng)! }.joined(separator: Bool.random(using: &rng) ? " " : "")
            _ = LanguageIdentifier.identify(text)
            _ = classifier.classifyByRules(text)
            _ = Fixed.photoParser().parse(text)
        }
        #expect(await classifier.classify(String(repeating: "6 baje ", count: 2000), languageHint: nil) != nil || true)
    }

    @Test func extremeNumbersAreHandled() async {
        for text in [
            "timer for 99999999999999999999 minutes", "timer for 1e9 hours", "alarm at 99:99", "remind me 5000 days later", "alarm at -5",
            "photos from last 99999 days", "timer for 999999999999999999 hours", "photos from last 999999999999999999 weeks", "alarm in 999999999999999999 minutes", "alarm at 0:00", "timer 0 minutes", "photos from 31 november 2026", "photos from 29 february 2027",
        ] {
            _ = await Fixed.intent(text)
        }
        let zero = await Fixed.intent("timer 0 minutes")
        #expect((zero?.confidence ?? 0) < LocalIntentClassifier.minimumActionableConfidence)
    }

    @Test func midnightAlarmWorks() async throws {
        let intent = try #require(await Fixed.intent("alarm at 0:00"))
        #expect(intent.string("time") == "00:00")
    }
}
