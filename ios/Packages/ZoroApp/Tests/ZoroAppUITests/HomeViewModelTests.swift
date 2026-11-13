import ConversationManager
import Foundation
import Testing
import ZoroCore
import ZoroDesign
@testable import ZoroAppUI

@Suite("Voice gestures and permissions")
struct VoiceControlTests {
    @Test func tapToggles() {
        #expect(VoiceCommand.forGesture(.tap, in: .idle) == .start)
        #expect(VoiceCommand.forGesture(.tap, in: .private) == .start)
        #expect(VoiceCommand.forGesture(.tap, in: .error) == .start)
        #expect(VoiceCommand.forGesture(.tap, in: .listening) == .stop)
        for state in [VoiceSessionState.processing, .delegating, .toolExecution, .speaking] {
            #expect(VoiceCommand.forGesture(.tap, in: state) == .interrupt)
        }
    }

    @Test func holdToTalk() {
        #expect(VoiceCommand.forGesture(.holdBegan, in: .idle) == .start)
        #expect(VoiceCommand.forGesture(.holdBegan, in: .listening) == VoiceCommand.none)
        #expect(VoiceCommand.forGesture(.holdBegan, in: .speaking) == .interruptAndStart)
        #expect(VoiceCommand.forGesture(.holdBegan, in: .processing) == .interruptAndStart)
        #expect(VoiceCommand.forGesture(.holdEnded, in: .listening) == .finishListening)
        for state in VoiceSessionState.allCases where state != .listening {
            #expect(VoiceCommand.forGesture(.holdEnded, in: state) == VoiceCommand.none)
        }
    }

    @Test func permissionGate() {
        #expect(VoicePermissionGate.evaluate(microphone: .granted, speech: .granted) == .ready)
        #expect(VoicePermissionGate.evaluate(microphone: .notDetermined, speech: .notDetermined) == .prime(.microphone))
        #expect(VoicePermissionGate.evaluate(microphone: .granted, speech: .notDetermined) == .prime(.speechRecognition))
        #expect(VoicePermissionGate.evaluate(microphone: .denied, speech: .granted) == .denied(.microphone))
        #expect(VoicePermissionGate.evaluate(microphone: .granted, speech: .unavailable) == .denied(.speechRecognition))
        for p in AppPermission.allCases {
            #expect(p.purpose.hasSuffix("."))
            #expect(!p.deniedMessage.isEmpty)
        }
    }
}

@Suite("Home view model")
@MainActor
struct HomeViewModelTests {
    @Test func refreshReadsPrivacyModeAndKillSwitch() async {
        let home = makeHome(api: FakeAPI(security: .success(FakeAPI.state(.cloudIntelligence))), context: SuggestionContext(basketItemCount: 2))
        await home.refresh()
        #expect(home.connection == .connected)
        #expect(home.presentation.privacyMode == .cloudIntelligence)
        #expect(home.presentation.orbState == .idle)
        #expect(home.presentation.suggestions.map(\.title) == ["Compare my basket"])

        let paused = makeHome(api: FakeAPI(security: .success(FakeAPI.state(.strictPrivate, killSwitch: true))))
        await paused.refresh()
        #expect(paused.connection == .paused)
        #expect(paused.presentation.orbState == .privateOffline)
    }

    @Test func unreachableServerShowsDisconnected() async {
        let home = makeHome(api: FakeAPI(security: .failure(.transport("offline"))), context: SuggestionContext(basketItemCount: 2))
        await home.refresh()
        #expect(home.connection == .unreachable)
        #expect(home.presentation.issue?.kind == .disconnected)
        #expect(home.presentation.suggestions.isEmpty)
        #expect(!home.presentation.canSend)
    }

    @Test func tapStartsListeningWhenAllowed() async {
        let voice = FakeVoice()
        let home = makeHome(voice: voice)
        home.voiceOptions = { VoiceSessionOptions(languageHint: "hi", privacyMode: .strictPrivate) }
        await home.handle(.tap)
        #expect(voice.calls.all == [.start(VoiceSessionOptions(languageHint: "hi", privacyMode: .strictPrivate))])
        home.voiceDidChange(.listening)
        await home.handle(.tap)
        #expect(voice.calls.all.last == .stop)
    }

    @Test func primingComesBeforeTheSystemPrompt() async {
        let voice = FakeVoice()
        let permissions = FakePermissions([.microphone: .notDetermined, .speechRecognition: .granted], answers: [.microphone: .granted])
        let home = makeHome(voice: voice, permissions: permissions)
        await home.handle(.tap)
        #expect(home.priming == .microphone)
        #expect(permissions.requests.all.isEmpty)
        #expect(voice.calls.all.isEmpty)
        await home.continuePriming()
        #expect(permissions.requests.all == [.microphone])
        #expect(home.priming == nil)
        #expect(voice.calls.all.count == 1)
    }

    @Test func declinedPrimingShowsWhatToDo() async {
        let voice = FakeVoice()
        let permissions = FakePermissions([.microphone: .notDetermined, .speechRecognition: .granted], answers: [.microphone: .denied])
        let home = makeHome(voice: voice, permissions: permissions)
        await home.handle(.tap)
        await home.continuePriming()
        #expect(voice.calls.all.isEmpty)
        #expect(home.presentation.issue?.message == AppPermission.microphone.deniedMessage)
        #expect(home.presentation.issue?.action == .openSystemSettings)
    }

    @Test func deniedPermissionNeverPrompts() async {
        let voice = FakeVoice()
        let permissions = FakePermissions([.microphone: .denied, .speechRecognition: .granted])
        let home = makeHome(voice: voice, permissions: permissions)
        await home.handle(.tap)
        #expect(home.priming == nil)
        #expect(permissions.requests.all.isEmpty)
        #expect(home.presentation.issue?.message == "ZORO needs the microphone to hear you. Turn it on in Settings.")
    }

    @Test func voiceStartFailureOffersTyping() async {
        let voice = FakeVoice()
        voice.startError = .unavailable(capability: "Speech", reason: "not installed")
        let home = makeHome(voice: voice)
        await home.handle(.tap)
        #expect(home.presentation.issue?.message == "Speech recognition isn't available right now. You can type instead.")
        #expect(home.presentation.issue?.action == .typeInstead)
        home.dismissVoiceIssue()
        #expect(home.presentation.issue == nil)
    }

    @Test func bargeInInterruptsThenListens() async {
        let voice = FakeVoice()
        let home = makeHome(voice: voice)
        home.voiceDidChange(.speaking)
        await home.handle(.holdBegan)
        #expect(voice.calls.all.first == .interrupt)
        #expect(voice.calls.all.count == 2)
    }

    @Test func levelsGoToTheSideThatIsTalking() {
        let home = makeHome()
        home.receiveLevel(0.5)
        #expect(home.userLevels.isEmpty && home.assistantLevels.isEmpty)
        home.voiceDidChange(.listening)
        home.receiveLevel(0.4)
        home.receiveLevel(7)
        home.receiveLevel(.nan)
        #expect(home.userLevels.values == [0.4, 1, 0])
        home.voiceDidChange(.speaking)
        home.receiveLevel(0.3)
        #expect(home.assistantLevels.values == [0.3])
        #expect(home.level == 0.3)
        home.voiceDidChange(.idle)
        #expect(home.level == 0)
    }

    @Test func typedTurnFlowsIntoTheStage() async {
        let api = FakeAPI(turnEvents: [
            .turnStarted(TurnStarted(turnId: "t1", conversationId: "c1", privacyMode: .strictPrivate)),
            .agentStarted(AgentStarted(agent: .shopping, task: "Looking at your basket")),
            .textDelta(TextDelta(text: "Your basket has ")),
            .textDelta(TextDelta(text: "three items.")),
            .agentFinished(AgentFinished(agent: .shopping, ok: true, durationMs: 40)),
            .turnCompleted(TurnCompleted(turnId: "t1", messageId: "m1", language: "en", dataClasses: [], cloudVoiceAllowed: true, usage: UsageSummary())),
        ])
        let home = makeHome(api: api)
        home.draft = "  what is in my basket  "
        await home.sendDraft()
        #expect(home.draft.isEmpty)
        #expect(api.turns.all.first?.input.text == "what is in my basket")
        #expect(api.turns.all.first?.input.modality == .text)
        let p = home.presentation
        #expect(p.ownerText == "what is in my basket")
        #expect(p.zoroText == "Your basket has three items.")
        #expect(p.orbState == .privateOffline)
        #expect(p.agents.map(\.status) == [.done])
        #expect(home.lastReply == "Your basket has three items.")
        #expect(home.conversation.conversationId == "c1")
    }

    @Test func failedTurnShowsErrorThenSettlesAndRetries() async {
        let api = FakeAPI(turnError: .transport("offline"))
        let home = makeHome(api: api)
        await home.send("compare stores")
        #expect(home.presentation.orbState == .error)
        #expect(home.presentation.issue?.action == .retry)
        #expect(home.presentation.suggestions.first?.action == .retry("compare stores"))
        home.settleError()
        #expect(home.presentation.orbState == .idle)
        #expect(home.presentation.issue != nil)
        await home.retryLast()
        #expect(api.turns.all.count == 2)
    }

    @Test func emptyDraftSendsNothing() async {
        let api = FakeAPI()
        let home = makeHome(api: api)
        home.draft = "   "
        await home.sendDraft()
        #expect(api.turns.all.isEmpty)
    }

    @Test func suggestionsAct() async {
        let api = FakeAPI()
        let home = makeHome(api: api)
        let nav = AppNavigation()
        await home.perform(Suggestion(title: "Review", action: .open(.activity)), navigation: nav)
        #expect(nav.selectedTab == .activity)
        await home.perform(Suggestion(title: "Compare my basket", action: .send("Compare my basket")), navigation: nav)
        #expect(api.turns.all.first?.input.text == "Compare my basket")
    }
}

@Suite("Live words and hold-to-talk")
@MainActor
struct LiveWordsTests {
    @Test func holdToTalkStartsInHoldModeAndReleaseSendsTheTurn() async {
        let voice = FakeVoice()
        let home = makeHome(voice: voice)
        await home.handle(.holdBegan)
        #expect(voice.calls.all == [.start(VoiceSessionOptions(activation: .holdToTalk))])
        home.voiceDidChange(.listening)
        await home.handle(.holdEnded)
        #expect(voice.calls.all.last == .finishListening)  // not .stop: what was heard is sent
        await home.handle(.tap)
        #expect(voice.calls.all.last == .stop)  // a tap while listening still abandons
    }

    @Test func ownersWordsHangBelowTheLineWhileTheySpeak() async throws {
        let voice = FakeVoice()
        let home = makeHome(voice: voice)
        await home.start()
        defer { home.stop() }
        home.voiceDidChange(.listening)
        voice.say(VoiceTranscript(text: "kal subah", isFinal: false, speaker: .owner))
        try await waitFor { home.liveOwnerWords == "kal subah" }
        #expect(home.presentation.ownerText == "kal subah")
        #expect(home.presentation.zoroText == nil)
        voice.say(VoiceTranscript(text: "Theek hai", isFinal: false, speaker: .assistant))
        voice.say(VoiceTranscript(text: "kal subah 7 baje", isFinal: true, speaker: .owner, language: "hinglish"))
        try await waitFor { home.liveOwnerWords == "kal subah 7 baje" }
        home.voiceDidChange(.processing)
        #expect(home.presentation.ownerText == "kal subah 7 baje")
        home.voiceDidChange(.speaking)
        #expect(home.liveOwnerWords == nil)
        #expect(home.presentation.ownerText == nil)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met in time")
    }
}
