import Foundation
import Testing
import ZoroCore

@testable import VoiceInterface

@Suite("Sentence chunker")
struct SentenceChunkerTests {
    func chunk(_ deltas: [String]) -> [String] {
        var c = SentenceChunker()
        var out: [String] = []
        for d in deltas { out += c.append(d) }
        if let tail = c.flush() { out.append(tail) }
        return out
    }

    func charByChar(_ text: String) -> [String] { chunk(text.map { String($0) }) }

    @Test func englishWithAbbreviationsDecimalsAndInitials() {
        let text = "Dr. Rao will see you at 4.30 pm. Bring Rs. 1,299.50 in cash! A. R. Rahman is playing at 9 p.m. tonight. Okay?"
        let expected = [
            "Dr. Rao will see you at 4.30 pm.", "Bring Rs. 1,299.50 in cash!", "A. R. Rahman is playing at 9 p.m. tonight.", "Okay?",
        ]
        #expect(chunk([text]) == expected)
        #expect(charByChar(text) == expected)
    }

    @Test func hindiDandaEndsSentencesImmediately() {
        var c = SentenceChunker()
        // The danda needs no lookahead: the first sentence is ready before the next delta arrives.
        #expect(c.append("आज मुंबई में बारिश होगी।") == ["आज मुंबई में बारिश होगी।"])
        #expect(c.append(" छाता ले जाना॥ डॉ. शर्मा से") == ["छाता ले जाना॥"])
        #expect(c.append(" मिलना है? ठीक") == ["डॉ. शर्मा से मिलना है?"])
        #expect(c.flush() == "ठीक")
    }

    @Test func hinglishMixedPunctuation() {
        let text = "Kal Mumbai mein baarish hogi. Chhata le jana, okay? Main reminder set kar dun! Done।"
        let expected = ["Kal Mumbai mein baarish hogi.", "Chhata le jana, okay?", "Main reminder set kar dun!", "Done।"]
        #expect(chunk([text]) == expected)
        #expect(charByChar(text) == expected)
        #expect(chunk(["Kal Mumbai mein ", "baarish hogi.", " Chhata", " le jana."]) == ["Kal Mumbai mein baarish hogi.", "Chhata le jana."])
    }

    @Test func fullStopWaitsForTheNextCharacter() {
        var c = SentenceChunker()
        #expect(c.append("Meet Dr.").isEmpty)
        #expect(c.append(" Rao at zoro.app today.").isEmpty)
        #expect(c.append(" See you").count == 1)
        #expect(c.pendingText == " See you")
    }

    @Test func lowercaseContinuationIsNotABoundary() {
        #expect(chunk(["It costs approx. five hundred. Fine."]) == ["It costs approx. five hundred.", "Fine."])
        #expect(chunk(["Wait... what now? Yes."]) == ["Wait... what now?", "Yes."])
    }

    @Test func closingQuotesStayWithTheSentence() {
        #expect(chunk(["He said \"chalo!\" Then left."]) == ["He said \"chalo!\"", "Then left."])
    }

    @Test func longRunsSplitAtCommas() {
        var c = SentenceChunker(maxLength: 40)
        let out = c.append("Your list has milk, bread, eggs, rice, dal, atta, ghee and some more items to order")
        #expect(!out.isEmpty)
        #expect(out.allSatisfy { $0.count <= 40 })
        #expect(out.first?.hasSuffix(",") == true)
    }

    @Test func punctuationOnlyFragmentsAreDropped() {
        #expect(chunk(["... !", " ? "]).isEmpty)
        #expect(chunk(["\n\nHello.\n"]) == ["Hello."])
    }
}

@Suite("Language")
struct LanguageTests {
    @Test(arguments: [
        ("What's the weather tomorrow?", SpokenLanguage.en),
        ("Remind me to call mom at 6", .en),
        ("कल का मौसम कैसा रहेगा?", .hi),
        ("मुझे Instamart से दूध order करना है", .hi),
        ("kal ka weather batao", .hinglish),
        ("mujhe paise bhejne hain", .hinglish),
        ("haan", .hinglish),
        ("Order milk from Instamart", .en),
        ("ok", .en),
    ])
    func identifiesLanguage(text: String, expected: SpokenLanguage) {
        #expect(LanguageIdentifier.identify(text) == expected)
    }

    @Test func recognitionLocalesFollowSettingThenHintThenHistory() {
        #expect(LocaleSelector.recognitionLocales(setting: .hi, hint: "en", last: .en) == ["hi-IN", "en-IN"])
        #expect(LocaleSelector.recognitionLocales(setting: .en, hint: nil, last: nil) == ["en-IN", "en-US"])
        #expect(LocaleSelector.recognitionLocales(setting: .hinglish, hint: nil, last: nil) == ["en-IN", "hi-IN"])
        #expect(LocaleSelector.recognitionLocales(setting: .auto, hint: "hi", last: .en) == ["hi-IN", "en-IN"])
        #expect(LocaleSelector.recognitionLocales(setting: .auto, hint: nil, last: .hi) == ["hi-IN", "en-IN"])
        #expect(LocaleSelector.recognitionLocales(setting: .auto, hint: nil, last: nil) == ["en-IN", "hi-IN", "en-US"])
    }

    @Test func synthesisLanguageFollowsScript() {
        #expect(LocaleSelector.synthesisLanguage(for: "आज बारिश होगी।") == "hi-IN")
        #expect(LocaleSelector.synthesisLanguage(for: "Kal baarish hogi.") == "en-IN")
        #expect(LocaleSelector.synthesisLanguage(for: "Your order is placed.") == "en-IN")
    }

    @Test func languageCodes() {
        #expect(SpokenLanguage(code: "hi-IN") == .hi)
        #expect(SpokenLanguage(code: "en_IN") == .en)
        #expect(SpokenLanguage(code: "hinglish") == .hinglish)
        #expect(SpokenLanguage(code: "fr") == nil)
    }

    @Test func wakePhraseOnlyAtTheStart() {
        let w = WakePhrase()
        #expect(w.strip("Zoro, aaj ka plan batao") == "aaj ka plan batao")
        #expect(w.strip("Hey Zoro what's next") == "what's next")
        #expect(w.strip("ज़ोरो, कल का मौसम") == "कल का मौसम")
        #expect(w.strip("zoro") == "")
        #expect(w.strip("zorocoin price") == nil)
        #expect(w.strip("tell zoro hi") == nil)
    }
}

@Suite("Voice and engine selection")
struct SelectionTests {
    let voices = [
        SpeechVoiceDescriptor(id: "a", name: "A", language: "en-US", gender: .female, quality: 2),
        SpeechVoiceDescriptor(id: "b", name: "B", language: "en-IN", gender: .male, quality: 0),
        SpeechVoiceDescriptor(id: "c", name: "C", language: "en_IN", gender: .female, quality: 1),
        SpeechVoiceDescriptor(id: "d", name: "D", language: "hi-IN", gender: .female, quality: 0),
    ]

    @Test func picksExactLocaleThenGenderThenQuality() {
        #expect(VoiceSelector.select(from: voices, language: "en-IN", gender: .female, preferredId: nil)?.id == "c")
        #expect(VoiceSelector.select(from: voices, language: "en-IN", gender: .male, preferredId: nil)?.id == "b")
        #expect(VoiceSelector.select(from: voices, language: "hi-IN", gender: .male, preferredId: nil)?.id == "d")
        #expect(VoiceSelector.select(from: voices, language: "en-GB", gender: .female, preferredId: nil)?.id == "a")
        #expect(VoiceSelector.select(from: voices, language: "ta-IN", gender: .female, preferredId: nil) == nil)
    }

    @Test func preferredVoiceOnlyForItsLanguage() {
        #expect(VoiceSelector.select(from: voices, language: "en-IN", gender: .female, preferredId: "a")?.id == "a")
        #expect(VoiceSelector.select(from: voices, language: "hi-IN", gender: .female, preferredId: "a")?.id == "d")
    }

    @Test func rateAndPitch() {
        #expect(SpeechStyle.rate(speakingRate: 1) == 0.5)
        #expect(SpeechStyle.rate(speakingRate: 2) == 1)
        #expect(SpeechStyle.rate(speakingRate: 0.1) == 0.25)
        #expect(SpeechStyle.rate(speakingRate: 9) == 1)
        #expect(SpeechStyle.pitch(.crisp) > SpeechStyle.pitch(.calm))
    }

    @Test(arguments: [
        // (settings engine, requested engine, privacy, cloudReady, onDeviceAvailable) → decision
        (VoiceSettings.Engine.cloud, VoiceEngineKind.cloud, PrivacyMode.cloudIntelligence, true, true, EngineDecision.cloud),
        (.cloud, .onDevice, .cloudIntelligence, true, true, .cloud),
        (.local, .cloud, .cloudIntelligence, true, true, .cloud),
        (.local, .onDevice, .cloudIntelligence, true, true, .onDevice(.onDeviceChosen)),
        (.cloud, .cloud, .strictPrivate, true, true, .onDevice(.privateMode)),
        (.cloud, .cloud, .cloudIntelligence, false, true, .onDevice(.cloudUnavailable)),
        (.cloud, .cloud, .strictPrivate, false, false, .unavailable("On-device speech recognition is not available for your language on this device.")),
        (.cloud, .cloud, .cloudIntelligence, false, false, .unavailable("Cloud voice is not reachable and on-device speech recognition is not available.")),
        (.local, .onDevice, .strictPrivate, false, true, .onDevice(.privateMode)),
    ])
    func engineMatrix(
        settingsEngine: VoiceSettings.Engine, requested: VoiceEngineKind, privacy: PrivacyMode, cloudReady: Bool, onDevice: Bool, expected: EngineDecision
    ) {
        let plan = EngineSelector.plan(settings: VoiceSettings(engine: settingsEngine), options: VoiceSessionOptions(engine: requested, privacyMode: privacy))
        #expect(EngineSelector.resolve(plan: plan, cloudReady: cloudReady, onDeviceAvailable: onDevice) == expected)
    }

    @Test func clientMayOnlyTightenPrivacy() {
        let options = VoiceSessionOptions(engine: .cloud, privacyMode: .cloudIntelligence)
        #expect(EngineSelector.plan(settings: VoiceSettings(engine: .cloud), options: options, currentPrivacy: .strictPrivate) == .onDevice(.privateMode))
        #expect(EngineSelector.stricter(.strictPrivate, .cloudIntelligence) == .strictPrivate)
    }
}

@Suite("State machine")
struct StateMachineTests {
    typealias P = VoicePhase

    @Test func fullTransitionTable() {
        let busy: [P] = [.processing, .delegating, .toolExecution, .speaking]
        let resting: [P] = [.idle, .privateOffline, .error]
        func n(_ p: P, _ t: VoiceTrigger, rest: P = .idle) -> P? { VoiceStateMachine.next(p, t, rest: rest) }

        for p in resting { #expect(n(p, .start) == .listening) }
        for p in [P.listening] + busy { #expect(n(p, .start) == nil) }
        for p in P.allCases where p != .idle { #expect(n(p, .stop) == .idle) }
        #expect(n(.idle, .stop) == nil)
        for p in P.allCases where p != .error { #expect(n(p, .failed) == .error) }
        #expect(n(.error, .failed) == nil)

        #expect(n(.listening, .utteranceSubmitted) == .processing)
        for p in P.allCases where p != .listening { #expect(n(p, .utteranceSubmitted) == nil) }

        #expect(n(.processing, .agentsWorking) == .delegating)
        #expect(n(.toolExecution, .agentsWorking) == .delegating)
        #expect(n(.delegating, .agentsWorking) == nil)
        #expect(n(.speaking, .agentsWorking) == nil)

        #expect(n(.processing, .toolStarted) == .toolExecution)
        #expect(n(.delegating, .toolStarted) == .toolExecution)
        #expect(n(.listening, .toolStarted) == nil)
        #expect(n(.toolExecution, .toolFinished(agentsStillWorking: true)) == .delegating)
        #expect(n(.toolExecution, .toolFinished(agentsStillWorking: false)) == .processing)
        #expect(n(.speaking, .toolFinished(agentsStillWorking: false)) == nil)

        for p in [P.listening, .processing, .delegating, .toolExecution] { #expect(n(p, .replyAudioStarted) == .speaking) }
        for p in resting + [.speaking] { #expect(n(p, .replyAudioStarted) == nil) }

        for p in busy {
            #expect(n(p, .replyFinished, rest: .idle) == .idle)
            #expect(n(p, .replyFinished, rest: .listening) == .listening)
            #expect(n(p, .replyFinished, rest: .privateOffline) == .privateOffline)
            #expect(n(p, .bargeIn) == .listening)
        }
        for p in resting + [.listening] {
            #expect(n(p, .replyFinished) == nil)
            #expect(n(p, .bargeIn) == nil)
        }

        #expect(n(.error, .recovered, rest: .privateOffline) == .privateOffline)
        #expect(n(.error, .recovered, rest: .listening) == .listening)
        #expect(n(.idle, .recovered) == nil)
    }

    @Test func privateOfflineIsShownAsPrivate() {
        #expect(VoicePhase.privateOffline.sessionState == .private)
        #expect(VoicePhase.toolExecution.sessionState == .toolExecution)
        #expect(Set(VoicePhase.allCases.map(\.sessionState)) == Set(VoiceSessionState.allCases))
    }
}

@Suite("Latency metrics")
struct LatencyTests {
    @Test func computesIntervalsFromMarks() {
        var t = LatencyTracker()
        t.markListening(0)
        t.markSpeechStart(1.0)
        t.markPartial(1.3)
        t.markPartial(1.9)
        t.markUtteranceEnd(3.0)
        t.markFeedback(3.25)
        t.markFirstAudio(3.9)
        let sample = t.complete(at: 6.0, engine: .onDevice)
        #expect(abs(sample.firstPartial! - 0.3) < 1e-9)
        #expect(abs(sample.firstFeedback! - 0.25) < 1e-9)
        #expect(abs(sample.firstAudio! - 0.9) < 1e-9)
        #expect(abs(sample.roundTrip! - 3.0) < 1e-9)
    }

    @Test func feedbackBeforeUtteranceIsIgnoredAndAudioImpliesFeedback() {
        var t = LatencyTracker()
        t.markFeedback(0.5)
        #expect(t.firstFeedback == nil)
        t.markUtteranceEnd(1)
        t.markFirstAudio(1.4)
        let s = t.complete(at: 2, engine: .cloud)
        #expect(abs(s.firstFeedback! - 0.4) < 1e-9)
        #expect(s.firstPartial == nil)
    }

    @Test func summaryUsesMedians() {
        let samples = [0.2, 0.4, 3.0].map { TurnLatency(engine: .onDevice, firstFeedback: $0, roundTrip: $0 * 2) }
        let s = LatencySummary(samples)
        #expect(s.turns == 3)
        #expect(s.medianFirstFeedback == 0.4)
        #expect(s.medianRoundTrip == 0.8)
        #expect(LatencySummary([]).medianFirstAudio == nil)
        #expect(LatencySummary(Array(samples.prefix(2))).medianFirstFeedback.map { abs($0 - 0.3) < 1e-9 } == true)
    }
}
