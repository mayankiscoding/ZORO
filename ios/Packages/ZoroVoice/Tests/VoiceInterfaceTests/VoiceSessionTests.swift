import AudioEngine
import Foundation
import Testing
import ZoroCore

@testable import VoiceInterface

@Suite("Voice session: on-device engine")
struct OnDeviceSessionTests {
    let cloudMode = VoiceSessionOptions(engine: .onDevice, privacyMode: .cloudIntelligence)

    @Test func fullTurnSpeaksSentenceBySentenceAndSettles() async throws {
        let h = Harness()
        h.backend.queue(
            .events([
                .turnStarted(TurnStarted(turnId: "t1", conversationId: "c1", privacyMode: .cloudIntelligence)),
                .route(RouteDecided(agents: [.personalAssistant], reason: "weather", dataClasses: [.public], engine: .deterministic)),
                .toolStarted(ToolStarted(callId: "x", tool: "research.weather", agent: .personalAssistant, risk: .low)),
                .toolFinished(ToolFinished(callId: "x", ok: true, durationMs: 40)),
                .textDelta(TextDelta(text: "Kal Mumbai mein baarish hogi. Chhata")),
                .textDelta(TextDelta(text: " le jana!")),
                .turnCompleted(TurnCompleted(turnId: "t1", messageId: "m1", language: "hinglish", dataClasses: [.public], cloudVoiceAllowed: false, usage: UsageSummary())),
            ]))
        try await h.session.start(cloudMode)
        #expect(await h.phase() == .listening)
        #expect(await h.recognizer.lastLocale == "en-IN")
        #expect(await h.recognizer.lastOnDeviceOnly == false)
        #expect(h.audio.activations.get() == 1)

        h.capture.send(pcmChunk(speech: true, events: [.speechStarted]))
        #expect(await eventually { await h.recognizer.appendCalls == 1 })
        await h.recognizer.partial("kal ka")
        await h.recognizer.final("kal ka weather batao")

        #expect(await h.waitFor(.idle))
        #expect(await h.synth.texts == ["Kal Mumbai mein baarish hogi.", "Chhata le jana!"])
        #expect(await h.synth.spoken.allSatisfy { $0.language == "en-IN" && $0.voiceId == "en-in-f" && $0.rate == 0.5 })
        let request = try #require(h.backend.requests.get().first)
        #expect(request.input.text == "kal ka weather batao")
        #expect(request.input.modality == .voice)
        #expect(request.input.languageHint == "hinglish")
        #expect(request.privacyMode == nil)
        #expect(h.recorder.phases == [.listening, .processing, .delegating, .toolExecution, .delegating, .speaking, .idle])
        #expect(!h.capture.isRunning)
        #expect(h.recorder.events.get().contains(.partialTranscript("kal ka")))
        #expect(h.recorder.events.get().contains(.finalTranscript("kal ka weather batao", language: .hinglish)))
    }

    @Test func strictPrivateRequiresOnDeviceAndRestsInPrivate() async throws {
        let recognizer = FakeRecognizer(availability: ["en-IN": .serverOnly, "hi-IN": .onDevice, "en-US": .serverOnly])
        let h = Harness(recognizer: recognizer)
        h.backend.queue(.events(Turns.reply("ठीक है।", language: "hi")))
        try await h.session.start(VoiceSessionOptions(engine: .cloud, privacyMode: .strictPrivate))
        #expect(await recognizer.lastLocale == "hi-IN")
        #expect(await recognizer.lastOnDeviceOnly == true)
        #expect(await h.transport.connects.isEmpty)
        #expect(h.backend.grantRequests.get() == 0)
        await recognizer.final("कल का मौसम")
        #expect(await h.waitFor(.privateOffline))
        #expect(await h.session.currentState() == .private)
        #expect(await h.synth.spoken.first?.language == "hi-IN")
        #expect(h.backend.requests.get().first?.privacyMode == .strictPrivate)
        #expect(h.recorder.events.get().contains(.engine(.onDevice, fallback: .privateMode)))
    }

    @Test func bargeInStopsSpeechAndCancelsTheTurn() async throws {
        let h = Harness(holdSpeech: true)
        h.backend.queue(.open(Array(Turns.reply("Here is a long answer. It keeps going.").prefix(3))))
        try await h.session.start(cloudMode)
        await h.recognizer.final("tell me a story")
        #expect(await h.waitFor(.speaking))

        // Echo-length blip: ignored.
        h.capture.send(pcmChunk(speech: true, seconds: 0.1))
        h.capture.send(pcmChunk(speech: false, seconds: 0.1))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await h.phase() == .speaking)

        // The owner talks over the reply.
        h.capture.send(pcmChunk(speech: true, seconds: 0.2))
        h.capture.send(pcmChunk(speech: true, seconds: 0.2))
        #expect(await h.waitFor(.listening))
        #expect(await eventually { h.backend.cancelled.get() == ["t1"] })
        #expect(await h.synth.stops >= 1)
        #expect(h.player.flushes.get() >= 1)
        #expect(await h.recognizer.startCount == 2)
        // Pre-roll: the interrupting speech reaches the new recognition.
        #expect(await h.recognizer.appendCalls >= 2)
        #expect(await h.synth.texts == ["Here is a long answer."])
    }

    @Test func interruptDuringProcessingCancelsTurn() async throws {
        let h = Harness()
        h.backend.queue(.open([.turnStarted(TurnStarted(turnId: "t9", conversationId: "c", privacyMode: .cloudIntelligence))]))
        try await h.session.start(cloudMode)
        await h.recognizer.final("order milk")
        #expect(await h.waitFor(.processing))
        #expect(await eventually { await h.session.currentTurnIdForTests == "t9" })
        await h.session.interrupt()
        #expect(await h.phase() == .listening)
        #expect(await eventually { h.backend.cancelled.get() == ["t9"] })
        // interrupt() when nothing is running is a no-op.
        await h.session.interrupt()
        #expect(await h.phase() == .listening)
    }

    @Test func networkFailureRetriesOnceThenShowsErrorAndSettles() async throws {
        let h = Harness()
        h.backend.queue(.fail(URLError(.notConnectedToInternet)), .fail(URLError(.notConnectedToInternet)))
        try await h.session.start(cloudMode)
        await h.recognizer.final("kal ka plan")
        #expect(await h.waitFor(.idle))
        #expect(h.backend.requests.get().count == 2)
        #expect(h.recorder.phases.contains(.error))
        guard case .network = h.recorder.errors.first else {
            Issue.record("expected a network error, got \(h.recorder.errors)")
            return
        }
        #expect(h.recorder.errors.first?.isRetryable == true)
        #expect(!h.capture.isRunning)
    }

    @Test func retrySucceedsAfterOneDrop() async throws {
        let h = Harness()
        h.backend.queue(.fail(URLError(.networkConnectionLost)), .events(Turns.reply("Done.")))
        try await h.session.start(cloudMode)
        await h.recognizer.final("set alarm")
        #expect(await h.waitFor(.idle))
        #expect(await h.synth.texts == ["Done."])
        #expect(h.recorder.errors.isEmpty)
    }

    @Test func serverTurnErrorIsTyped() async throws {
        let h = Harness()
        h.backend.queue(.events([.error(TurnError(code: "kill_switch", message: "ZORO is paused.", retryable: false))]))
        try await h.session.start(cloudMode)
        await h.recognizer.final("hello")
        #expect(await h.waitFor(.idle))
        #expect(h.recorder.errors == [.turnFailed(TurnError(code: "kill_switch", message: "ZORO is paused."))])
    }

    @Test func microphoneDeniedFailsStartWithoutCapture() async {
        let h = Harness(mic: .notDetermined)
        await #expect(throws: VoiceError.microphoneDenied) { try await h.session.start(cloudMode) }
        #expect(h.capture.starts == 0)
        #expect(await h.waitFor(.idle))
        #expect(h.recorder.phases == [.error, .idle])
    }

    @Test func noUsableLocaleInPrivateModeIsReported() async {
        let recognizer = FakeRecognizer(availability: ["en-IN": .serverOnly, "hi-IN": .serverOnly, "en-US": .unavailable("no")])
        let h = Harness(recognizer: recognizer)
        await #expect(throws: VoiceError.recognitionUnavailable(locales: ["en-IN", "hi-IN", "en-US"], onDeviceRequired: true)) {
            try await h.session.start(VoiceSessionOptions(privacyMode: .strictPrivate))
        }
        #expect(await h.waitFor(.privateOffline))
    }

    @Test func speechPermissionDenied() async {
        let h = Harness(recognizer: FakeRecognizer(auth: .denied))
        await #expect(throws: VoiceError.speechRecognitionDenied) { try await h.session.start(cloudMode) }
    }

    @Test(arguments: [
        (VoiceSettings.Language.hi, nil as String?, "hi-IN"),
        (.en, nil, "en-IN"),
        (.hinglish, nil, "en-IN"),
        (.auto, "hi", "hi-IN"),
        (.auto, nil, "en-IN"),
    ])
    func recognitionLocaleFollowsLanguage(setting: VoiceSettings.Language, hint: String?, expected: String) async throws {
        let h = Harness(settings: VoiceSettings(language: setting))
        try await h.session.start(VoiceSessionOptions(languageHint: hint, privacyMode: .cloudIntelligence))
        #expect(await h.recognizer.lastLocale == expected)
        await h.session.stop()
    }

    @Test func hindiFallsBackToEnglishIndiaWhenUnavailable() async throws {
        let recognizer = FakeRecognizer(availability: ["hi-IN": .unavailable("not installed"), "en-IN": .onDevice])
        let h = Harness(settings: VoiceSettings(language: .hi), recognizer: recognizer)
        try await h.session.start(cloudMode)
        #expect(await recognizer.lastLocale == "en-IN")
    }

    @Test func wakePhraseGatesFollowUpsInsideTheSession() async throws {
        let h = Harness(settings: VoiceSettings(activation: .wakeWordInSession))
        h.backend.queue(.events(Turns.reply("Done.")), .events(Turns.reply("Aaj teen meetings hain.", id: "t2")))
        try await h.session.start(cloudMode)
        await h.recognizer.final("set an alarm for 6")
        // Continuing session: back to listening for a follow-up.
        #expect(await eventually { await h.recognizer.startCount == 2 })
        #expect(await h.phase() == .listening)
        await h.recognizer.final("this was not for zoro")
        #expect(await eventually { await h.recognizer.startCount == 3 })
        #expect(h.backend.requests.get().count == 1)
        await h.recognizer.final("Zoro, aaj ka plan batao")
        #expect(await eventually { h.backend.requests.get().count == 2 })
        #expect(h.backend.requests.get().last?.input.text == "aaj ka plan batao")
        #expect(h.backend.requests.get().last?.conversationId == "c1")
    }

    @Test func listenTimeoutClosesTheOrb() async throws {
        let h = Harness { $0.listenTimeout = 0.2 }
        try await h.session.start(cloudMode)
        #expect(await h.waitFor(.idle))
        #expect(!h.capture.isRunning)
        #expect(h.audio.deactivations.get() >= 1)
    }

    @Test func latencyIsRecordedPerTurn() async throws {
        let h = Harness()
        h.backend.queue(.events(Turns.reply("Done.")))
        try await h.session.start(cloudMode)
        h.capture.send(pcmChunk(speech: true, events: [.speechStarted]))
        #expect(await eventually { await h.recognizer.appendCalls == 1 })
        await h.recognizer.partial("set")
        await h.recognizer.final("set alarm")
        #expect(await h.waitFor(.idle))
        let samples = await h.session.recordedLatencies
        #expect(samples.count == 1)
        let s = try #require(samples.first)
        #expect(s.engine == .onDevice)
        #expect((s.firstPartial ?? -1) > 0)
        #expect((s.firstFeedback ?? -1) > 0)
        #expect((s.firstAudio ?? -1) >= s.firstFeedback!)
        #expect((s.roundTrip ?? -1) >= s.firstAudio!)
        #expect(await h.session.latencySummary.turns == 1)
        #expect(h.recorder.events.get().contains(.latency(s)))
    }

    @Test func vadEndpointEndsTheUtterance() async throws {
        let h = Harness()
        try await h.session.start(cloudMode)
        h.capture.send(pcmChunk(speech: true, events: [.speechStarted]))
        h.capture.send(pcmChunk(speech: false, events: [.speechEnded]))
        #expect(await eventually { await h.recognizer.ends == 1 })
    }

    @Test func phoneCallInterruptionEndsTheSession() async throws {
        let h = Harness()
        try await h.session.start(cloudMode)
        h.audio.broadcaster.yield(.interruptionBegan)
        #expect(await h.waitFor(.idle))
        #expect(!h.capture.isRunning)
    }

    @Test func stopFromAnyBusyPhaseCancelsEverything() async throws {
        let h = Harness(holdSpeech: true)
        h.backend.queue(.open(Array(Turns.reply("One. Two.").prefix(3))))
        try await h.session.start(cloudMode)
        await h.recognizer.final("count")
        #expect(await h.waitFor(.speaking))
        await h.session.stop()
        #expect(await h.phase() == .idle)
        #expect(await eventually { h.backend.cancelled.get() == ["t1"] })
        #expect(!h.capture.isRunning)
        // A fresh start works after stop.
        try await h.session.start(cloudMode)
        #expect(await h.phase() == .listening)
    }
}

extension VoiceSession {
    var currentTurnIdForTests: String? { currentTurnId }
}

@Suite("Voice session: transcripts and end of utterance")
struct TranscriptAndFinishTests {
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [VoiceTranscript] = []
        func append(_ t: VoiceTranscript) { lock.lock(); items.append(t); lock.unlock() }
        var all: [VoiceTranscript] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @Test func transcriptUpdatesCarryTheOwnersWordsThenTheReply() async throws {
        let h = Harness()
        h.backend.queue(.events(Turns.reply("Kal baarish hogi.", language: "hinglish")))
        let collected = Collected()
        let stream = h.session.transcriptUpdates()
        let reader = Task { for await t in stream { collected.append(t) } }
        defer { reader.cancel() }
        try await h.session.start(VoiceSessionOptions(engine: .onDevice, privacyMode: .cloudIntelligence))
        await h.recognizer.partial("kal ka")
        await h.recognizer.final("kal ka mausam")
        #expect(await eventually { collected.all.contains { $0.speaker == .assistant && $0.isFinal } })
        let owner = collected.all.filter { $0.speaker == .owner }
        #expect(owner.first == VoiceTranscript(text: "kal ka", isFinal: false, speaker: .owner))
        #expect(owner.last?.text == "kal ka mausam" && owner.last?.isFinal == true && owner.last?.language != nil)
        let reply = try #require(collected.all.last)
        #expect(reply == VoiceTranscript(text: "Kal baarish hogi.", isFinal: true, speaker: .assistant, language: "hinglish"))
    }

    @Test func holdToTalkWaitsForFinishListeningNotTheEndOfSpeech() async throws {
        let h = Harness()
        try await h.session.start(VoiceSessionOptions(engine: .onDevice, privacyMode: .cloudIntelligence, activation: .holdToTalk))
        h.capture.send(pcmChunk(speech: true, events: [.speechStarted]))
        h.capture.send(pcmChunk(speech: false, events: [.speechEnded]))
        #expect(await eventually { await h.recognizer.appendCalls == 2 })
        #expect(await h.recognizer.ends == 0)  // a pause does not end a held utterance
        await h.session.finishListening()
        #expect(await h.recognizer.ends == 1)
        #expect(await h.phase() == .listening)  // the recogniser's final result then sends the turn
    }

    @Test func stopAbandonsWithoutSendingATurn() async throws {
        let h = Harness()
        try await h.session.start(VoiceSessionOptions(engine: .onDevice, privacyMode: .cloudIntelligence))
        await h.recognizer.partial("cancel this")
        await h.session.stop()
        #expect(h.backend.requests.get().isEmpty)
        #expect(await h.recognizer.cancels >= 1)
    }
}
