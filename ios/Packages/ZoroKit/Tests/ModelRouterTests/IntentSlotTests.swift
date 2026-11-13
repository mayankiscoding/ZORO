import Foundation
import Testing
import ZoroCore
@testable import ModelRouter

/// Intent and slot tables. Clock: Friday 13 Nov 2026, 10:00 Asia/Kolkata.
@Suite struct IntentSlotTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var text: String
        var intent: String
        var slots: [String: JSONValue]
        var language: String? = nil
        var testDescription: String { text }
    }

    // MARK: Alarm

    static let alarms: [Case] = [
        Case(text: "set an alarm for 6:30 am", intent: "alarm.create", slots: ["time": "06:30"], language: "en"),
        Case(text: "wake me up at 7 am", intent: "alarm.create", slots: ["time": "07:00"], language: "en"),
        Case(text: "alarm for 6 am tomorrow", intent: "alarm.create", slots: ["time": "06:00"]),
        Case(text: "set alarm at 18:45", intent: "alarm.create", slots: ["time": "18:45"]),
        Case(text: "wake me at 6", intent: "alarm.create", slots: ["time": "18:00"]),
        Case(text: "alarm for half past 5 in the evening", intent: "alarm.create", slots: ["time": "17:30"]),
        Case(text: "set an alarm in 2 hours", intent: "alarm.create", slots: ["time": "12:00"]),
        Case(text: "alarm at 7 am every day", intent: "alarm.create", slots: ["time": "07:00", "repeat_days": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]]),
        Case(text: "alarm at 6:30 am on weekdays", intent: "alarm.create", slots: ["time": "06:30"]),
        Case(text: "kal subah 6 baje alarm laga do", intent: "alarm.create", slots: ["time": "06:00"], language: "hinglish"),
        Case(text: "saade paanch baje alarm lagao", intent: "alarm.create", slots: ["time": "17:30"], language: "hinglish"),
        Case(text: "raat 11 baje alarm laga do", intent: "alarm.create", slots: ["time": "23:00"]),
        Case(text: "har somvar subah 7 baje alarm lagao", intent: "alarm.create", slots: ["time": "07:00", "repeat_days": ["mon"]]),
        Case(text: "सुबह 6 बजे का अलार्म लगाओ", intent: "alarm.create", slots: ["time": "06:00"], language: "hi"),
        Case(text: "शाम 7 बजे का अलार्म", intent: "alarm.create", slots: ["time": "19:00"], language: "hi"),
        Case(text: "सवा छह बजे अलार्म लगाओ", intent: "alarm.create", slots: ["time": "18:15"]),
        Case(text: "मुझे सुबह पांच बजे उठा देना", intent: "alarm.create", slots: ["time": "05:00"]),
        Case(text: "पौने सात बजे का अलार्म", intent: "alarm.create", slots: ["time": "18:45"]),
    ]

    @Test(arguments: IntentSlotTests.alarms) func alarm(_ c: Case) async throws {
        try await check(c, tool: "ios.alarm.create")
    }

    @Test func alarmWithoutATimeIsIncomplete() async throws {
        let intent = try #require(await Fixed.intent("set an alarm"))
        #expect(intent.name == "alarm.create")
        #expect(intent.confidence < LocalIntentClassifier.minimumActionableConfidence)
        #expect(intent.slots["time"] == nil)
    }

    @Test func weekdaysRepeatMondayToFriday() async throws {
        let intent = try #require(await Fixed.intent("alarm at 6:30 am on weekdays"))
        #expect(intent.slots["repeat_days"]?.arrayValue?.compactMap(\.stringValue) == ["mon", "tue", "wed", "thu", "fri"])
    }

    // MARK: Timer

    static let timers: [Case] = [
        Case(text: "set a timer for 10 minutes", intent: "timer.start", slots: ["seconds": 600], language: "en"),
        Case(text: "timer 5 min", intent: "timer.start", slots: ["seconds": 300]),
        Case(text: "set a timer for 1 hour 30 minutes", intent: "timer.start", slots: ["seconds": 5400]),
        Case(text: "start a 45 second timer", intent: "timer.start", slots: ["seconds": 45]),
        Case(text: "half an hour timer", intent: "timer.start", slots: ["seconds": 1800]),
        Case(text: "set a timer for an hour", intent: "timer.start", slots: ["seconds": 3600]),
        Case(text: "10 minute ka timer lagao", intent: "timer.start", slots: ["seconds": 600], language: "hinglish"),
        Case(text: "ek ghante ka timer", intent: "timer.start", slots: ["seconds": 3600]),
        Case(text: "aadha ghanta timer lagao", intent: "timer.start", slots: ["seconds": 1800]),
        Case(text: "dedh ghante ka timer", intent: "timer.start", slots: ["seconds": 5400]),
        Case(text: "paanch minute ka timer", intent: "timer.start", slots: ["seconds": 300]),
        Case(text: "दस मिनट का टाइमर लगाओ", intent: "timer.start", slots: ["seconds": 600], language: "hi"),
        Case(text: "डेढ़ घंटे का टाइमर", intent: "timer.start", slots: ["seconds": 5400]),
        Case(text: "५ मिनट का टाइमर", intent: "timer.start", slots: ["seconds": 300]),
        Case(text: "ढाई घंटे का टाइमर लगाओ", intent: "timer.start", slots: ["seconds": 9000]),
    ]

    @Test(arguments: IntentSlotTests.timers) func timer(_ c: Case) async throws {
        try await check(c, tool: "ios.timer.start")
    }

    @Test func timerWithoutDurationIsIncomplete() async throws {
        let intent = try #require(await Fixed.intent("set a timer"))
        #expect(intent.name == "timer.start")
        #expect(intent.confidence < LocalIntentClassifier.minimumActionableConfidence)
    }

    // MARK: Reminder

    static let reminders: [Case] = [
        Case(text: "remind me to call mom tomorrow at 5 pm", intent: "reminder.create",
             slots: ["title": "call mom", "due_at": "2026-11-14T17:00:00+05:30"], language: "en"),
        Case(text: "remind me to drink water in 10 minutes", intent: "reminder.create",
             slots: ["title": "drink water", "due_at": "2026-11-13T10:10:00+05:30"]),
        Case(text: "set a reminder to pay rent on Monday at 9 am", intent: "reminder.create",
             slots: ["title": "pay rent", "due_at": "2026-11-16T09:00:00+05:30"]),
        Case(text: "remind me tomorrow to buy milk", intent: "reminder.create",
             slots: ["title": "buy milk", "due_at": "2026-11-14T09:00:00+05:30"]),
        Case(text: "remind me to submit the report", intent: "reminder.create", slots: ["title": "submit the report"]),
        Case(text: "remind me at 8 pm to charge the laptop", intent: "reminder.create",
             slots: ["title": "charge the laptop", "due_at": "2026-11-13T20:00:00+05:30"]),
        Case(text: "mujhe kal 5 baje doodh lane ki yaad dilana", intent: "reminder.create",
             slots: ["title": "doodh lane", "due_at": "2026-11-14T17:00:00+05:30"], language: "hinglish"),
        Case(text: "kal shaam 5 baje mummy ko call karne ka reminder lagao", intent: "reminder.create",
             slots: ["title": "mummy ko call karne", "due_at": "2026-11-14T17:00:00+05:30"]),
        Case(text: "परसों सुबह 8 बजे बिजली का बिल भरने का रिमाइंडर लगाओ", intent: "reminder.create",
             slots: ["title": "बिजली का बिल भरने", "due_at": "2026-11-15T08:00:00+05:30"], language: "hi"),
        Case(text: "कल शाम 5 बजे मम्मी को फोन करने का रिमाइंडर लगाओ", intent: "reminder.create",
             slots: ["title": "मम्मी को फोन करने", "due_at": "2026-11-14T17:00:00+05:30"]),
    ]

    @Test(arguments: IntentSlotTests.reminders) func reminder(_ c: Case) async throws {
        try await check(c, tool: "device.reminder.create")
    }

    @Test func reminderWithoutATimeHasNoDueDate() async throws {
        let intent = try #require(await Fixed.intent("remind me to submit the report"))
        #expect(intent.slots["due_at"] == nil)
    }

    @Test func reminderWithoutATitleIsIncomplete() async throws {
        let intent = try #require(await Fixed.intent("set a reminder for tomorrow 5 pm"))
        #expect(intent.name == "reminder.create")
        #expect(intent.confidence < LocalIntentClassifier.minimumActionableConfidence)
    }

    // MARK: Calendar lookup

    static let calendars: [Case] = [
        Case(text: "what's on my calendar tomorrow", intent: "calendar.upcoming",
             slots: ["from": "2026-11-14T00:00:00+05:30", "to": "2026-11-15T00:00:00+05:30"], language: "en"),
        Case(text: "what is my schedule today", intent: "calendar.upcoming",
             slots: ["from": "2026-11-13T00:00:00+05:30", "to": "2026-11-14T00:00:00+05:30"]),
        Case(text: "when is my next meeting", intent: "calendar.upcoming",
             slots: ["from": "2026-11-13T10:00:00+05:30", "limit": 1]),
        Case(text: "show my calendar for next week", intent: "calendar.upcoming",
             slots: ["from": "2026-11-16T00:00:00+05:30", "to": "2026-11-23T00:00:00+05:30"]),
        Case(text: "meetings on friday", intent: "calendar.upcoming",
             slots: ["from": "2026-11-20T00:00:00+05:30", "to": "2026-11-21T00:00:00+05:30"]),
        Case(text: "meeting kab hai kal", intent: "calendar.upcoming",
             slots: ["from": "2026-11-14T00:00:00+05:30", "to": "2026-11-15T00:00:00+05:30"], language: "hinglish"),
        Case(text: "kal ka schedule batao", intent: "calendar.upcoming",
             slots: ["from": "2026-11-14T00:00:00+05:30", "to": "2026-11-15T00:00:00+05:30"]),
        Case(text: "मेरी अगली मीटिंग कब है", intent: "calendar.upcoming",
             slots: ["from": "2026-11-13T10:00:00+05:30", "limit": 1], language: "hi"),
        Case(text: "आज का शेड्यूल बताओ", intent: "calendar.upcoming",
             slots: ["from": "2026-11-13T00:00:00+05:30", "to": "2026-11-14T00:00:00+05:30"]),
    ]

    @Test(arguments: IntentSlotTests.calendars) func calendar(_ c: Case) async throws {
        try await check(c, tool: "device.calendar.upcoming")
    }

    // MARK: Music

    static let music: [Case] = [
        Case(text: "play music", intent: "music.control", slots: ["provider": "apple_music", "action": "play"], language: "en"),
        Case(text: "pause", intent: "music.control", slots: ["provider": "apple_music", "action": "pause"]),
        Case(text: "pause the music", intent: "music.control", slots: ["provider": "apple_music", "action": "pause"]),
        Case(text: "stop the music", intent: "music.control", slots: ["provider": "apple_music", "action": "pause"]),
        Case(text: "next song", intent: "music.control", slots: ["provider": "apple_music", "action": "next"]),
        Case(text: "skip", intent: "music.control", slots: ["provider": "apple_music", "action": "next"]),
        Case(text: "previous song", intent: "music.control", slots: ["provider": "apple_music", "action": "previous"]),
        Case(text: "play Kesariya", intent: "music.control", slots: ["provider": "apple_music", "action": "search_play", "query": "Kesariya"]),
        Case(text: "play Kesariya on Spotify", intent: "music.control", slots: ["provider": "spotify_app", "action": "search_play", "query": "Kesariya"]),
        Case(text: "play some relaxing music", intent: "music.control", slots: ["provider": "apple_music", "action": "search_play", "query": "relaxing"]),
        Case(text: "Arijit Singh ke gaane chalao", intent: "music.control", slots: ["provider": "apple_music", "action": "search_play", "query": "Arijit Singh"], language: "hinglish"),
        Case(text: "gaana band karo", intent: "music.control", slots: ["provider": "apple_music", "action": "pause"]),
        Case(text: "agla gaana", intent: "music.control", slots: ["provider": "apple_music", "action": "next"]),
        Case(text: "pichla gaana lagao", intent: "music.control", slots: ["provider": "apple_music", "action": "previous"]),
        Case(text: "गाना चलाओ", intent: "music.control", slots: ["provider": "apple_music", "action": "play"], language: "hi"),
        Case(text: "अरिजीत सिंह के गाने चलाओ", intent: "music.control", slots: ["provider": "apple_music", "action": "search_play", "query": "अरिजीत सिंह"]),
        Case(text: "म्यूजिक रोको", intent: "music.control", slots: ["provider": "apple_music", "action": "pause"]),
    ]

    @Test(arguments: IntentSlotTests.music) func musicControl(_ c: Case) async throws {
        try await check(c, tool: "device.music.control")
    }

    // MARK: App sections

    static let sections: [(String, String)] = [
        ("open settings", "settings"), ("go to fitness", "fitness"), ("kholo shopping", "shopping"), ("सेटिंग्स खोलो", "settings"),
        ("open device control", "device_control"), ("show my spending", "finance"), ("photos", "photos"), ("open photos", "photos"),
        ("take me to security", "security"), ("open the integrations", "integrations"), ("investments dikhao", "investments"),
        ("open memory", "memory"), ("show history", "history"), ("open agent activity", "activity"), ("open music", "music"),
        ("फिटनेस खोलो", "fitness"), ("मेमोरी दिखाओ", "memory"),
    ]

    @Test(arguments: IntentSlotTests.sections) func openSection(_ sample: (String, String)) async throws {
        let intent = try #require(await Fixed.intent(sample.0), "\(sample.0)")
        #expect(intent.name == "app.open_section")
        #expect(intent.tool == nil)
        #expect(intent.string("section") == sample.1)
        #expect(intent.confidence >= LocalIntentClassifier.minimumActionableConfidence)
        #expect(AppSectionID(rawValue: sample.1) != nil)
    }

    // MARK: Not local

    static let notLocal = [
        "what's the weather today", "tell me a joke", "how much did I spend on food last month", "आज का मौसम कैसा है",
        "buy a phone under 20000", "show my spending last month", "add a meeting to my calendar tomorrow",
        "schedule a meeting with Rahul", "take a photo", "kal ka mausam kaisa hai", "compare prices of iPhone 17", "hello",
        "mera balance kitna hai",
    ]

    @Test(arguments: IntentSlotTests.notLocal) func notALocalCommand(_ text: String) async {
        #expect(await Fixed.intent(text) == nil, "\(text)")
    }

    @Test func emptyTextIsNotACommand() async {
        #expect(await Fixed.intent("") == nil)
        #expect(await Fixed.intent("   ") == nil)
    }

    // MARK: Cross-intent priority

    @Test func reminderBeatsPhotosAndCalendar() async throws {
        #expect(try #require(await Fixed.intent("remind me to print the photos tomorrow")).name == "reminder.create")
        #expect(try #require(await Fixed.intent("remind me about the meeting at 4 pm")).name == "reminder.create")
    }

    @Test func nextMeetingIsCalendarNotMusic() async throws {
        #expect(try #require(await Fixed.intent("next meeting")).name == "calendar.upcoming")
    }

    @Test func openPhotosIsASectionButPhotosFromYesterdayIsASearch() async throws {
        #expect(try #require(await Fixed.intent("open photos")).name == "app.open_section")
        #expect(try #require(await Fixed.intent("show me photos from yesterday")).name == "photos.search")
    }

    @Test func languageHintDoesNotOverrideClearText() async throws {
        let intent = try #require(await Fixed.classifier().classify("kal subah 6 baje alarm laga do", languageHint: "en"))
        #expect(intent.language == "hinglish")
    }

    // MARK: Helper

    private func check(_ c: Case, tool: String) async throws {
        let intent = try #require(await Fixed.intent(c.text), "no intent for: \(c.text)")
        #expect(intent.name == c.intent, "\(c.text)")
        #expect(intent.tool == tool, "\(c.text)")
        #expect(intent.confidence >= LocalIntentClassifier.minimumActionableConfidence, "\(c.text)")
        for (key, value) in c.slots {
            #expect(intent.slots[key] == value, "\(c.text): slot \(key) = \(String(describing: intent.slots[key])), expected \(value)")
        }
        if let language = c.language { #expect(intent.language == language, "\(c.text)") }
    }
}
