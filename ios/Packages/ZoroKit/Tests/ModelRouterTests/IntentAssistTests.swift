import Foundation
import Testing
import ZoroCore
@testable import ModelRouter

struct FakeAssist: OnDeviceIntentAssisting {
    var available = true
    var result: IntentGuess?
    var fails = false
    var calls: CallCounter = CallCounter()

    func isAvailable() async -> Bool { available }
    func guess(for text: String) async throws -> IntentGuess? {
        calls.increment()
        if fails { throw ZoroError.unavailable(capability: "model", reason: "test") }
        return result
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite struct IntentAssistTests {
    @Test func modelHelpsWithEnglishThatTheRulesMiss() async throws {
        // No rule matches "get me up half an hour before sunrise"; the fake model says it is an alarm.
        let assist = FakeAssist(result: IntentGuess(intent: "alarm", timePhrase: "at 5:30 am"))
        let intent = try #require(await Fixed.classifier(assist: assist).classify("please get me up bright and early at 5:30 in the morning", languageHint: nil))
        #expect(intent.name == "alarm.create")
        #expect(intent.string("time") == "05:30")
        #expect(intent.confidence <= 0.85)
        #expect(assist.calls.count == 1)
    }

    @Test func rulesWinWithoutCallingTheModel() async throws {
        let assist = FakeAssist(result: IntentGuess(intent: "timer", timePhrase: "1 minute"))
        let intent = try #require(await Fixed.classifier(assist: assist).classify("set an alarm for 6:30 am", languageHint: nil))
        #expect(intent.name == "alarm.create")
        #expect(assist.calls.count == 0)
    }

    @Test func hindiAndHinglishNeverReachTheModel() async {
        let assist = FakeAssist(result: IntentGuess(intent: "alarm", timePhrase: "6 am"))
        let classifier = Fixed.classifier(assist: assist)
        #expect(await classifier.classify("मौसम कैसा रहेगा", languageHint: nil) == nil)
        #expect(await classifier.classify("mujhe bahut subah jaldi uthna hai kal", languageHint: nil) == nil)
        #expect(assist.calls.count == 0)
    }

    @Test func unavailableModelIsSkipped() async {
        let assist = FakeAssist(available: false, result: IntentGuess(intent: "alarm", timePhrase: "6 am"))
        #expect(await Fixed.classifier(assist: assist).classify("get me out of bed at some point tomorrow morning", languageHint: nil) == nil)
        #expect(assist.calls.count == 0)
    }

    @Test func modelFailureFallsBackToTheRulesResult() async {
        let assist = FakeAssist(fails: true)
        #expect(await Fixed.classifier(assist: assist).classify("tell me something nice", languageHint: nil) == nil)
        let partial = await Fixed.classifier(assist: FakeAssist(fails: true)).classify("set an alarm", languageHint: nil)
        #expect(partial?.name == "alarm.create")
        #expect((partial?.confidence ?? 1) < LocalIntentClassifier.minimumActionableConfidence)
    }

    @Test func nonsenseFromTheModelIsRejected() async {
        for guess in [
            IntentGuess(intent: "none"), IntentGuess(intent: "alarm"), IntentGuess(intent: "alarm", timePhrase: "whenever"),
            IntentGuess(intent: "launch_missiles", title: "now"), IntentGuess(intent: "reminder", timePhrase: "5 pm"),
            IntentGuess(intent: "timer", timePhrase: String(repeating: "x", count: 500)),
        ] {
            let result = await Fixed.classifier(assist: FakeAssist(result: guess)).classify("blah blah gibberish thing", languageHint: nil)
            #expect(result == nil, "\(guess)")
        }
    }

    @Test func canonicalCommandsReadBackThroughTheRules() async throws {
        let guesses: [(IntentGuess, String)] = [
            (IntentGuess(intent: "timer", timePhrase: "10 minutes"), "timer.start"),
            (IntentGuess(intent: "reminder", title: "call the bank", timePhrase: "tomorrow at 11 am"), "reminder.create"),
            (IntentGuess(intent: "calendar", timePhrase: "tomorrow"), "calendar.upcoming"),
            (IntentGuess(intent: "music", musicAction: "pause"), "music.control"),
            (IntentGuess(intent: "music", query: "Kesariya"), "music.control"),
            (IntentGuess(intent: "photos", timePhrase: "yesterday", query: "blue cap"), "photos.search"),
            (IntentGuess(intent: "open_section", section: "settings"), "app.open_section"),
        ]
        for (guess, name) in guesses {
            let command = try #require(guess.canonicalCommand)
            let intent = try #require(Fixed.classifier().classifyByRules(command), "\(command)")
            #expect(intent.name == name, "\(command)")
            #expect(intent.confidence >= LocalIntentClassifier.minimumActionableConfidence, "\(command)")
        }
    }

    @Test func systemAssistIsAbsentWhereFoundationModelsDoesNotExist() {
        #if !canImport(FoundationModels)
        #expect(SystemIntentAssist.make() == nil)
        #endif
    }
}
