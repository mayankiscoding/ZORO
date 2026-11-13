import Foundation
import Testing
@testable import ModelRouter

@Suite struct TemporalParserTests {
    let parser = TemporalParser(now: Fixed.now, timeZone: Fixed.timeZone)

    private func parse(_ text: String, _ direction: TimeDirection = .future) -> (TemporalParse, Utterance) {
        var u = Utterance(text)
        let p = parser.parse(&u, direction: direction)
        return (p, u)
    }

    @Test func tokenizerSplitsScriptsAndNumbers() {
        #expect(Tokenizer.tokenize("6pm").map(\.norm) == ["6", "pm"])
        #expect(Tokenizer.tokenize("6:30pm").map(\.norm) == ["6:30", "pm"])
        #expect(Tokenizer.tokenize("10मिनट").map(\.norm) == ["10", "मिनट"])
        #expect(Tokenizer.tokenize("What's up?").map(\.norm) == ["whats", "up"])
        #expect(Tokenizer.tokenize("५ मिनट").map(\.norm) == ["5", "मिनट"])
        #expect(Tokenizer.tokenize("फ़ोटो").map(\.norm) == ["फोटो"])
        #expect(Tokenizer.tokenize("पाँच").map(\.norm) == ["पांच"])
        #expect(Tokenizer.tokenize("a - b, c").map(\.norm) == ["a", "b", "c"])
    }

    @Test func daysAreRelativeToTheFixedClock() {
        #expect(parser.dayString(parse("today").0.dayStart!) == "2026-11-13")
        #expect(parser.dayString(parse("tomorrow").0.dayStart!) == "2026-11-14")
        #expect(parser.dayString(parse("day after tomorrow").0.dayStart!) == "2026-11-15")
        #expect(parser.dayString(parse("yesterday").0.dayStart!) == "2026-11-12")
        #expect(parser.dayString(parse("kal").0.dayStart!) == "2026-11-14")
        #expect(parser.dayString(parse("kal", .past).0.dayStart!) == "2026-11-12")
        #expect(parser.dayString(parse("कल", .past).0.dayStart!) == "2026-11-12")
        #expect(parser.dayString(parse("परसों").0.dayStart!) == "2026-11-15")
    }

    @Test func weekdaysResolveForwardOrBackward() {
        #expect(parser.dayString(parse("monday").0.dayStart!) == "2026-11-16")
        #expect(parser.dayString(parse("friday").0.dayStart!) == "2026-11-20")  // today is Friday: the next one
        #expect(parser.dayString(parse("this friday").0.dayStart!) == "2026-11-13")
        #expect(parser.dayString(parse("friday", .past).0.dayStart!) == "2026-11-06")
        #expect(parser.dayString(parse("last monday").0.dayStart!) == "2026-11-09")
        #expect(parser.dayString(parse("next sunday").0.dayStart!) == "2026-11-15")
        #expect(parser.dayString(parse("somvar").0.dayStart!) == "2026-11-16")
        #expect(parser.dayString(parse("रविवार").0.dayStart!) == "2026-11-15")
    }

    @Test func explicitDatesPickTheRightYear() {
        #expect(parser.dayString(parse("12 november").0.dayStart!) == "2027-11-12")  // future: the next one
        #expect(parser.dayString(parse("12 november", .past).0.dayStart!) == "2026-11-12")
        #expect(parser.dayString(parse("25 december").0.dayStart!) == "2026-12-25")
        #expect(parser.dayString(parse("1 jan 2027").0.dayStart!) == "2027-01-01")
        #expect(parser.dayString(parse("15 नवंबर").0.dayStart!) == "2026-11-15")
        #expect(parser.dayString(parse("10 नवंबर").0.dayStart!) == "2027-11-10")
        #expect(parse("may").0.dayStart == nil)  // a modal verb, not a month
    }

    @Test func invalidDatesAreIgnored() {
        #expect(parse("31 february").0.dayStart == nil)
    }

    @Test func clockTimesInManyForms() {
        func hm(_ text: String) -> String? {
            let (p, _) = parse(text)
            guard let h = p.hour else { return nil }
            return String(format: "%02d:%02d", h, p.minute)
        }
        #expect(hm("at 6:30 pm") == "18:30")
        #expect(hm("at 6 pm") == "18:00")
        #expect(hm("6am") == "06:00")
        #expect(hm("12 am") == "00:00")
        #expect(hm("12 pm") == "12:00")
        #expect(hm("18:45") == "18:45")
        #expect(hm("noon") == "12:00")
        #expect(hm("midnight") == "00:00")
        #expect(hm("quarter past 4") == "04:15")
        #expect(hm("quarter to 5") == "04:45")
        #expect(hm("half past 7") == "07:30")
        #expect(hm("six o'clock") == "06:00")
        #expect(hm("डेढ़ बजे") == "01:30")
        #expect(hm("dhai baje") == "02:30")
        #expect(hm("paune aath baje") == "07:45")
        #expect(hm("sava do baje") == "02:15")
        #expect(hm("शाम 5:30 बजे") == "17:30")
        #expect(hm("subah 8 baje") == "08:00")
        #expect(hm("दोपहर 2 बजे") == "14:00")
        #expect(hm("raat 2 baje") == "02:00")
        #expect(hm("in the morning") == nil)
    }

    @Test func durationsCombineAndSkipConnectingWords() {
        func seconds(_ text: String) -> Int? { parse(text).0.durationSeconds }
        #expect(seconds("in 10 minutes") == 600)
        #expect(seconds("1 hour and 15 minutes") == 4500)
        #expect(seconds("1.5 hours") == 5400)
        #expect(seconds("sava ghanta") == 4500)
        #expect(seconds("paune do ghante") == 6300)
        #expect(seconds("saade teen ghante") == 12600)
        #expect(seconds("ek ghanta tees minute") == 5400)
        #expect(seconds("पंद्रह मिनट बाद") == 900)
        #expect(seconds("twenty five minutes") == 1500)
        #expect(seconds("no numbers here") == nil)
        let (_, u) = parse("remind me in 10 minutes")
        #expect(u.remainder().map(\.norm) == ["remind", "me"])
    }

    @Test func ambiguousHoursPickTheNextOccurrence() {
        // 10:00 now: "6" is 18:00 today (6 am has passed); "11" is 11:00 today.
        func hour(_ text: String, style: AmbiguousHourStyle = .morning) -> Int? {
            let (p, _) = parse(text)
            return p.hour == nil ? nil : parser.resolveInstant(p, style: style, defaultHour: 9).map { Calendar(identifier: .gregorian).dateComponents(in: Fixed.timeZone, from: $0).hour! }
        }
        #expect(hour("at 6") == 18)
        #expect(hour("at 11") == 11)
        #expect(hour("tomorrow at 5", style: .morning) == 5)
        #expect(hour("tomorrow at 5", style: .daytime) == 17)
        #expect(hour("tomorrow at 9", style: .daytime) == 9)
    }

    @Test func repeatRulesAreExtracted() {
        #expect(parse("every day").0.repeatDays.count == 7)
        #expect(parse("har somvar aur shukravar").0.repeatDays == ["mon", "fri"])
        #expect(parse("weekdays").0.repeatDays == ["mon", "tue", "wed", "thu", "fri"])
        #expect(parse("every weekend").0.repeatDays == ["sat", "sun"])
        #expect(parse("रोज").0.repeating)
        #expect(!parse("monday").0.repeating)
    }

    @Test func formattingUsesTheOwnersOffset() {
        #expect(parser.isoString(Fixed.now) == "2026-11-13T10:00:00+05:30")
        #expect(parser.clockString(Fixed.now) == "10:00")
        var other = TemporalParser(now: Fixed.now, timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(other.isoString(Fixed.now) == "2026-11-12T23:30:00-05:00")
        other = TemporalParser(now: Fixed.now, timeZone: TimeZone(identifier: "UTC")!)
        #expect(other.clockString(Fixed.now) == "04:30")
    }

    @Test func differentTimeZoneChangesTheDay() async throws {
        // 23:30 on 12 Nov in New York is already the 13th in India: "today" must follow the owner's zone.
        let ny = TimeZone(identifier: "America/New_York")!
        let c = LocalIntentClassifier(clock: { Fixed.now }, timeZone: ny)
        let intent = try #require(await c.classify("what is my schedule today", languageHint: nil))
        #expect(intent.string("from") == "2026-11-12T00:00:00-05:00")
    }
}
