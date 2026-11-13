import AudioEngine
import Foundation
import Testing
import ZoroCore

@testable import VoiceInterface

@Suite("Voice session: cloud engine")
struct CloudSessionTests {
    let options = VoiceSessionOptions(engine: .cloud, privacyMode: .cloudIntelligence)

    func cloudHarness(holdSpeech: Bool = false) -> Harness {
        let h = Harness(settings: VoiceSettings(engine: .cloud), holdSpeech: holdSpeech)
        h.backend.grant.with { $0 = .success(Harness.grant()) }
        return h
    }

    @Test func askZoroRunsABackendTurnAndTheModelSpeaksIt() async throws {
        let h = cloudHarness()
        h.backend.queue(.events(Turns.reply("Kal baarish hogi.", cloudVoice: true)))
        try await h.session.start(options)
        #expect(await h.phase() == .listening)
        #expect(await h.transport.connects == [nil])
        #expect(await h.recognizer.startCount == 0)
        #expect(h.recorder.events.get().contains(.engine(.cloud, fallback: nil)))

        h.capture.send(pcmChunk(speech: true))
        #expect(await eventually { await h.transport.audioSent == 1 })

        await h.transport.server(.inputTranscript("kal ka "), .inputTranscript("mausam?"))
        await h.transport.server(.toolCall([LiveFunctionCall(id: "fc1", name: "ask_zoro", args: ["request": "kal ka mausam?"])]))
        #expect(await eventually { await h.transport.toolResponses.count == 1 })
        let response = try #require(await h.transport.toolResponses.first)
        #expect(response.id == "fc1")
        #expect(response.response["result"]?.stringValue == "Kal baarish hogi.")
        #expect(h.backend.requests.get().first?.input.text == "kal ka mausam?")

        await h.transport.server(.audio(Data(count: 960)), .audio(Data(count: 960)))
        #expect(await h.waitFor(.speaking))
        #expect(await eventually { h.player.enqueued.get().count == 2 })
        await h.transport.server(.turnComplete)
        #expect(await eventually { await h.session.recordedLatencies.count == 1 })
        #expect(await h.phase() == .listening)
        #expect(h.player.finishes.get() == 1)
        #expect(await h.synth.texts.isEmpty)
        #expect(h.recorder.events.get().contains(.partialTranscript("kal ka mausam?")))
        #expect(h.recorder.phases == [.listening, .processing, .delegating, .speaking, .listening])
    }

    @Test func replyNotAllowedForCloudVoiceIsSpokenOnDevice() async throws {
        let h = cloudHarness()
        h.backend.queue(.events(Turns.reply("Aapka balance ₹4,210.50 hai. Kuch aur?", cloudVoice: false)))
        try await h.session.start(options)
        await h.transport.server(.toolCall([LiveFunctionCall(id: "fc2", name: "ask_zoro", args: ["request": "mera balance"])]))
        #expect(await eventually { await h.transport.toolResponses.count == 1 })
        let response = try #require(await h.transport.toolResponses.first)
        // The private reply never reaches the cloud model.
        #expect(response.response["result"]?.stringValue == "")
        #expect(response.response["delivered_on_device"]?.boolValue == true)
        #expect(await eventually { await h.synth.texts == ["Aapka balance ₹4,210.50 hai.", "Kuch aur?"] })
        #expect(await h.waitFor(.listening))
        // Model audio that arrives anyway is muted until its turn completes.
        await h.transport.server(.audio(Data(count: 100)))
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(h.player.enqueued.get().isEmpty)
    }

    @Test func serverInterruptionFlushesPlayback() async throws {
        let h = cloudHarness()
        try await h.session.start(options)
        await h.transport.server(.audio(Data(count: 480)))
        #expect(await h.waitFor(.speaking))
        await h.transport.server(.interrupted)
        #expect(await h.waitFor(.listening))
        #expect(h.player.flushes.get() >= 1)
        // New speech after the interruption plays.
        await h.transport.server(.inputTranscript("ruko"), .audio(Data(count: 480)))
        #expect(await h.waitFor(.speaking))
    }

    @Test func localBargeInFlushesAndCancelsRunningAskTurn() async throws {
        let h = cloudHarness()
        h.backend.queue(.open([.turnStarted(TurnStarted(turnId: "t5", conversationId: "c", privacyMode: .cloudIntelligence))]))
        try await h.session.start(options)
        await h.transport.server(.audio(Data(count: 480)))
        #expect(await h.waitFor(.speaking))
        await h.transport.server(.toolCall([LiveFunctionCall(id: "fc3", name: "ask_zoro", args: ["request": "order milk"])]))
        #expect(await eventually { await h.session.currentTurnIdForTests == "t5" })
        h.capture.send(pcmChunk(speech: true, seconds: 0.4))
        #expect(await h.waitFor(.listening))
        #expect(await eventually { h.backend.cancelled.get() == ["t5"] })
        #expect(await h.transport.toolResponses.first?.response["error"] != nil)
    }

    @Test func unknownToolIsRefused() async throws {
        let h = cloudHarness()
        try await h.session.start(options)
        await h.transport.server(.toolCall([LiveFunctionCall(id: "x", name: "transfer_money", args: [:])]))
        #expect(await eventually { await h.transport.toolResponses.count == 1 })
        #expect(await h.transport.toolResponses.first?.response["error"] != nil)
        #expect(h.backend.requests.get().isEmpty)
    }

    @Test func grantFailureFallsBackToOnDevice() async throws {
        let h = Harness(settings: VoiceSettings(engine: .cloud))
        try await h.session.start(options)
        #expect(h.backend.grantRequests.get() == 1)
        #expect(await h.session.activeEngine == .onDevice)
        #expect(h.recorder.events.get().contains(.engine(.onDevice, fallback: .cloudUnavailable)))
        #expect(await h.recognizer.startCount == 1)
    }

    @Test func socketFailureWithoutResumptionFallsBackToOnDevice() async throws {
        let h = cloudHarness()
        try await h.session.start(options)
        await h.transport.drop()
        #expect(await eventually { await h.session.activeEngine == .onDevice })
        #expect(h.recorder.events.get().contains(.engine(.onDevice, fallback: .socketFailed)))
        #expect(await eventually { await h.recognizer.startCount == 1 })
        #expect(await h.phase() == .listening)
    }

    @Test func socketFailureResumesWithTheLatestHandle() async throws {
        let h = cloudHarness()
        try await h.session.start(options)
        await h.transport.server(.resumptionUpdate(handle: "h1", resumable: true), .resumptionUpdate(handle: "h2", resumable: true))
        await h.transport.server(.resumptionUpdate(handle: "nope", resumable: false))
        try await Task.sleep(nanoseconds: 20_000_000)
        await h.transport.drop()
        #expect(await eventually { await h.transport.connects == [nil, "h2"] })
        #expect(await h.session.activeEngine == .cloud)
        #expect(h.backend.grantRequests.get() == 2)
    }

    @Test func resumeFailureFallsBack() async throws {
        let h = cloudHarness()
        try await h.session.start(options)
        await h.transport.server(.resumptionUpdate(handle: "h1", resumable: true))
        try await Task.sleep(nanoseconds: 20_000_000)
        await h.transport.setFailConnect(true)
        await h.transport.drop()
        #expect(await eventually { await h.session.activeEngine == .onDevice })
        #expect(await h.transport.connects == [nil, "h1"])
    }

    @Test func goAwayReconnectsProactively() async throws {
        let h = cloudHarness()
        try await h.session.start(options)
        await h.transport.server(.resumptionUpdate(handle: "h9", resumable: true), .goAway(timeLeft: 5))
        #expect(await eventually { await h.transport.connects == [nil, "h9"] })
        #expect(await h.session.activeEngine == .cloud)
        #expect(await h.phase() == .listening)
    }

    @Test func stopClosesTheSocket() async throws {
        let h = cloudHarness()
        try await h.session.start(options)
        await h.session.stop()
        #expect(await h.transport.closes >= 1)
        #expect(await h.phase() == .idle)
    }
}

@Suite("Voice session view model")
@MainActor
struct ViewModelTests {
    @Test func foldsEventsIntoDisplayState() {
        let vm = VoiceSessionViewModel(session: Harness().session)
        vm.apply(.engine(.onDevice, fallback: .cloudUnavailable))
        vm.apply(.phase(.listening))
        vm.apply(.partialTranscript("kal ka"))
        #expect(vm.partialTranscript == "kal ka")
        vm.apply(.finalTranscript("kal ka mausam", language: .hinglish))
        vm.apply(.replyText("Kal "))
        vm.apply(.replyText("baarish."))
        vm.apply(.turn(.card(CardEvent(card: UICard(kind: "weather", title: "Mumbai")))))
        vm.apply(.phase(.speaking))
        #expect(vm.partialTranscript.isEmpty)
        #expect(vm.lastUtterance == "kal ka mausam")
        #expect(vm.utteranceLanguage == .hinglish)
        #expect(vm.replyText == "Kal baarish.")
        #expect(vm.cards.map(\.kind) == ["weather"])
        #expect(vm.fallbackReason == .cloudUnavailable)
        #expect(vm.isActive)
        vm.apply(.error(.network("offline")))
        vm.apply(.phase(.idle))
        #expect(vm.error == .network("offline"))
        #expect(!vm.isActive)
        #expect(vm.level == 0)
    }

    @Test func orbTapStartsAndReportsErrors() async {
        let h = Harness(mic: .denied)
        let vm = VoiceSessionViewModel(session: h.session)
        await vm.orbTapped(VoiceSessionOptions(privacyMode: .cloudIntelligence))
        #expect(vm.error == .microphoneDenied)
    }
}

@Suite("Recogniser chain and backend adapter")
struct AdapterTests {
    @Test func chainPrefersPrimaryOnlyWhenItRunsOnDevice() async throws {
        let primary = FakeRecognizer(availability: ["en-IN": .onDevice, "hi-IN": .unavailable("not installed")])
        let fallback = FakeRecognizer(availability: ["en-IN": .onDevice, "hi-IN": .serverOnly])
        let chain = RecognizerChain(primary: primary, fallback: fallback)
        #expect(await chain.availability(locale: "hi-IN") == .serverOnly)
        _ = try await chain.startUtterance(locale: "en-IN", onDeviceOnly: true)
        #expect(await chain.usingPrimary)
        await chain.append(Data(count: 4))
        #expect(await primary.appendCalls == 1)
        _ = try await chain.startUtterance(locale: "hi-IN", onDeviceOnly: false)
        #expect(await !chain.usingPrimary)
        #expect(await primary.cancels == 1)
        await chain.endUtterance()
        #expect(await fallback.ends == 1)
    }

    @Test func backendAdapterSurfacesTypedErrors() async {
        let backend = ZoroAPIVoiceBackend(api: UnavailableService())
        await #expect(throws: ZoroError.notPaired) { _ = try await backend.liveSessionGrant() }
        await #expect(throws: ZoroError.notPaired) { try await backend.cancelTurn(id: "t") }
        #expect(ZoroAPIVoiceBackend.liveSessionPath == "/v1/voice/live-session")
    }
}
