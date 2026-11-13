import ConversationManager
import Foundation
import Testing
import ZoroCore
import ZoroDesign
@testable import ZoroAppUI

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func entry(_ role: MessageRole, _ text: String, streaming: Bool = false, cards: [UICard] = []) -> TranscriptEntry {
    TranscriptEntry(id: UUID().uuidString, role: role, text: text, createdAt: t0, cards: cards, isStreaming: streaming)
}

private func agent(_ id: AgentId, running: Bool = true, ok: Bool = true) -> AgentWork {
    AgentWork(agent: id, task: "task", state: running ? .running : (ok ? .done : .failed))
}

@Suite("Home state mapping")
struct HomePresentationTests {
    typealias Input = HomePresentation.Input

    @Test(arguments: [
        (VoiceSessionState.listening, OrbState.listening), (.processing, .processing), (.delegating, .delegating),
        (.toolExecution, .toolExecution), (.speaking, .speaking), (.error, .error), (.private, .privateOffline),
    ])
    func voiceStateWins(voice: VoiceSessionState, orb: OrbState) {
        #expect(HomePresentation.orbState(Input(voice: voice, phase: .streaming, privacyMode: .cloudIntelligence)) == orb)
    }

    @Test func idleVoiceRestsByPrivacyMode() {
        #expect(HomePresentation.orbState(Input(privacyMode: .cloudIntelligence)) == .idle)
        #expect(HomePresentation.orbState(Input(privacyMode: .strictPrivate)) == .privateOffline)
        #expect(HomePresentation.orbState(Input(privacyMode: nil)) == .idle)
        #expect(HomePresentation.orbState(Input(privacyMode: .cloudIntelligence, connection: .paused)) == .privateOffline)
    }

    @Test func turnPhasesMapToOrb() {
        let approval = approvalRequest(now: t0)
        let action = DeviceActionRequest(actionId: "a", tool: "ios.alarm", risk: .low, expiresAt: t0)
        let cases: [(ConversationPhase, OrbState)] = [
            (.idle, .idle), (.sending, .processing), (.streaming, .processing), (.resuming, .processing),
            (.awaitingApproval(approval), .toolExecution), (.runningDeviceAction(action), .toolExecution),
            (.completed, .idle), (.cancelled, .idle), (.failed(.timeout), .error),
        ]
        for (phase, orb) in cases {
            #expect(HomePresentation.orbState(Input(phase: phase, privacyMode: .cloudIntelligence)) == orb, "\(phase)")
        }
    }

    @Test func streamingShowsWhoIsWorking() {
        let delegating = Input(phase: .streaming, agents: [agent(.shopping), agent(.finance)], privacyMode: .cloudIntelligence)
        let p = HomePresentation.make(delegating)
        #expect(p.orbState == .delegating)
        #expect(p.satellites.map(\.name) == ["Shopping", "Finance"])
        #expect(p.stateLabel == "Working with Shopping and Finance")

        let working = Input(phase: .streaming, agents: [agent(.shopping)], isToolRunning: true)
        #expect(HomePresentation.orbState(working) == .toolExecution)

        let done = Input(phase: .streaming, agents: [agent(.shopping, running: false)], isToolRunning: false)
        #expect(HomePresentation.orbState(done) == .processing)

        let supervisorOnly = Input(phase: .streaming, agents: [agent(.supervisor)])
        #expect(HomePresentation.orbState(supervisorOnly) == .processing)
        #expect(HomePresentation.make(supervisorOnly).satellites.isEmpty)
    }

    @Test func satellitesAreCapped() {
        let many = [AgentId.shopping, .finance, .music, .fitness, .memory, .vision, .document, .automation].map { agent($0) }
        let p = HomePresentation.make(Input(phase: .streaming, agents: many))
        #expect(p.satellites.count == HomePresentation.maxSatellites)
    }

    @Test func errorShowsOnceThenSettles() {
        #expect(HomePresentation.orbState(Input(phase: .failed(.timeout), privacyMode: .strictPrivate)) == .error)
        #expect(HomePresentation.orbState(Input(phase: .failed(.timeout), privacyMode: .strictPrivate, errorSettled: true)) == .privateOffline)
        #expect(HomePresentation.orbState(Input(voice: .error, privacyMode: .cloudIntelligence, errorSettled: true)) == .idle)
    }

    @Test func stateLabels() {
        #expect(HomePresentation.make(Input(privacyMode: .cloudIntelligence)).stateLabel == "Ready. Tap to talk.")
        #expect(HomePresentation.make(Input(privacyMode: .strictPrivate)).stateLabel == "Private mode. Tap to talk.")
        #expect(HomePresentation.make(Input(connection: .paused)).stateLabel == "Paused")
        #expect(HomePresentation.make(Input(privacyMode: .strictPrivate, connection: .unreachable)).stateLabel == "Not connected")
        #expect(HomePresentation.make(Input(voice: .listening, connection: .unreachable)).stateLabel == "Listening")
        #expect(HomePresentation.make(Input(voice: .listening)).stateLabel == "Listening")
        #expect(HomePresentation.make(Input(voice: .speaking)).stateLabel == "Speaking")
        #expect(HomePresentation.make(Input(phase: .sending)).stateLabel == "Thinking")
        #expect(HomePresentation.make(Input(phase: .failed(.timeout))).stateLabel == "Something went wrong")
        let approval = approvalRequest(now: t0)
        #expect(HomePresentation.make(Input(phase: .awaitingApproval(approval))).stateLabel == "Waiting for your approval")
    }

    @Test func agentChipsMarkTheOneWaitingForApproval() {
        let approval = approvalRequest(now: t0)
        let p = HomePresentation.make(Input(
            phase: .awaitingApproval(approval),
            agents: [agent(.communication), agent(.shopping), agent(.finance, running: false, ok: false), agent(.memory, running: false)]))
        #expect(p.agents.map(\.status) == [.needsYou, .working, .failed, .done])
        #expect(p.agents.first?.agentName == "Communications")
    }

    @Test func transcriptShowsTheCurrentExchange() {
        let transcript = [
            entry(.user, "first"), entry(.assistant, "first reply"),
            entry(.user, "दूध कहाँ सस्ता है?"), entry(.assistant, "Store A", streaming: true),
        ]
        let p = HomePresentation.make(Input(phase: .streaming, transcript: transcript))
        #expect(p.ownerText == "दूध कहाँ सस्ता है?")
        #expect(p.zoroText == "Store A")
        #expect(p.zoroIsStreaming)

        let waiting = HomePresentation.make(Input(phase: .sending, transcript: [entry(.user, "a"), entry(.assistant, "b"), entry(.user, "c")]))
        #expect(waiting.ownerText == "c")
        #expect(waiting.zoroText == nil)

        let empty = HomePresentation.make(Input())
        #expect(empty.ownerText == nil && empty.zoroText == nil && empty.cards.isEmpty)
    }

    @Test func cardsComeFromTheTurnOrTheLastReply() {
        let card = UICard(kind: "note", title: "Saved")
        let fromReply = HomePresentation.make(Input(transcript: [entry(.user, "q"), entry(.assistant, "a", cards: [card])]))
        #expect(fromReply.cards == [card])
        let live = UICard(kind: "live")
        let fromTurn = HomePresentation.make(Input(transcript: [entry(.user, "q"), entry(.assistant, "a", cards: [card])], cards: [live]))
        #expect(fromTurn.cards == [live])
    }

    @Test func privacyBanner() {
        #expect(HomePresentation.make(Input(privacyMode: .strictPrivate)).privacyMode == .strictPrivate)
        #expect(HomePresentation.make(Input(privacyMode: .cloudIntelligence)).privacyMode == .cloudIntelligence)
        #expect(HomePresentation.make(Input(privacyMode: nil)).privacyMode == nil)
    }

    @Test func disconnectedAndErrorStates() {
        let unreachable = HomePresentation.make(Input(connection: .unreachable))
        #expect(unreachable.issue?.kind == .disconnected)
        #expect(unreachable.issue?.message == "Can't reach your ZORO server. Check that your Mac is awake and on Tailscale.")
        #expect(unreachable.issue?.action == .reconnect)
        #expect(!unreachable.canSend)

        #expect(HomePresentation.make(Input(connection: .notPaired)).issue?.action == .pair)
        #expect(HomePresentation.make(Input(connection: .revoked)).issue?.actionTitle == "Pair again")
        #expect(HomePresentation.make(Input(connection: .paused)).issue?.action == .openSection(.security))
        #expect(HomePresentation.make(Input(connection: .checking)).issue == nil)
        #expect(HomePresentation.make(Input(connection: .checking)).canSend)

        let failed = HomePresentation.make(Input(phase: .failed(.timeout)))
        #expect(failed.issue?.kind == .error)
        #expect(failed.issue?.action == .retry)
        let notRetryable = HomePresentation.make(Input(phase: .failed(.turnFailed(TurnError(code: "x", message: "Finance took too long to answer. Nothing was changed.")))))
        #expect(notRetryable.issue?.message == "Finance took too long to answer. Nothing was changed.")
        #expect(notRetryable.issue?.action == nil)

        let voiceIssue = HomeIssue(kind: .error, message: "m")
        #expect(HomePresentation.make(Input(voiceIssue: voiceIssue)).issue == voiceIssue)
        // A connection problem outranks a voice problem.
        #expect(HomePresentation.make(Input(connection: .unreachable, voiceIssue: voiceIssue)).issue?.kind == .disconnected)
    }

    @Test func connectionStateFromErrors() {
        #expect(ConnectionState.from(ZoroError.notPaired) == .notPaired)
        #expect(ConnectionState.from(ZoroError.unauthorized) == .revoked)
        #expect(ConnectionState.from(ZoroError.transport("offline")) == .unreachable)
        #expect(ConnectionState.from(ZoroError.timeout) == .unreachable)
        #expect(ConnectionState.from(URLError(.cannotConnectToHost)) == .unreachable)
        #expect(ConnectionState.from(ZoroError.http(status: 403, body: ErrorBody(code: "device_revoked", message: "m"))) == .revoked)
        #expect(ConnectionState.from(ZoroError.http(status: 503, body: ErrorBody(code: "kill_switch_active", message: "m"))) == .paused)
        #expect(ConnectionState.from(ZoroError.http(status: 504, body: nil)) == .unreachable)
        if case .failed(let message) = ConnectionState.from(ZoroError.http(status: 500, body: ErrorBody(code: "internal_error", message: "Boom"))) {
            #expect(message.contains("Boom"))
        } else {
            Issue.record("expected failed")
        }
    }

    @Test func noSuggestionsWithoutContext() {
        #expect(HomePresentation.make(Input()).suggestions.isEmpty)
        #expect(HomePresentation.make(Input(context: SuggestionContext(basketItemCount: 0))).suggestions.isEmpty)
    }

    @Test func suggestionsFromRealContext() {
        let basket = HomePresentation.make(Input(context: SuggestionContext(basketItemCount: 3)))
        #expect(basket.suggestions.map(\.title) == ["Compare my basket"])
        #expect(basket.suggestions.first?.action == .send("Compare my basket"))

        let approvals = HomePresentation.make(Input(context: SuggestionContext(pendingApprovalCount: 2)))
        #expect(approvals.suggestions.map(\.title) == ["Review 2 waiting approvals"])
        #expect(HomePresentation.make(Input(context: SuggestionContext(pendingApprovalCount: 1))).suggestions.first?.title == "Review 1 waiting approval")

        let retry = HomePresentation.make(Input(phase: .failed(.timeout), transcript: [entry(.user, "compare stores")]))
        #expect(retry.suggestions.first?.action == .retry("compare stores"))

        let busy = HomePresentation.make(Input(phase: .streaming, context: SuggestionContext(basketItemCount: 3)))
        #expect(busy.suggestions.isEmpty)
        #expect(busy.isBusy && !busy.canSend)
    }

    @Test func haptics() {
        #expect(OrbHaptics.haptic(from: .idle, to: .listening) == .listenStart)
        #expect(OrbHaptics.haptic(from: .processing, to: .error) == .failure)
        #expect(OrbHaptics.haptic(from: .processing, to: .speaking) == .selection)
        #expect(OrbHaptics.haptic(from: .listening, to: .listening) == nil)
        #expect(OrbHaptics.haptic(from: .listening, to: .processing) == nil)
    }
}
