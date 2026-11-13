import ConversationManager
import Foundation
import Testing
import ZoroCore
@testable import SystemFeatures

final class FakeLocalStore: LocalConversationStoring, @unchecked Sendable {
    var summaries: [ConversationSummary] = []
    var stored: [String: [Message]] = [:]
    let deleted = Locked<[String]>([])
    func conversations(limit: Int) async throws -> [ConversationSummary] { summaries }
    func messages(in conversationId: String) async throws -> [Message] { stored[conversationId] ?? [] }
    func deleteConversation(id: String) async throws { deleted.withLock { $0.append(id) } }
}

@MainActor
@Suite("History view model")
struct HistoryTests {
    func make(pages: [String?: Page<ConversationSummary>]? = nil, local: FakeLocalStore? = nil) -> (HistoryViewModel, FakeAPI) {
        let api = FakeAPI()
        let table = pages ?? [nil: Page(items: [conversation("a", "Groceries"), conversation("b", "Trip")], nextCursor: "c2"), "c2": Page(items: [conversation("c", "Taxes")], nextCursor: nil)]
        api.conversationsHandler = { cursor, _ in
            guard let page = table[cursor] else { throw ZoroError.http(status: 404, body: nil) }
            return page
        }
        api.deleteConversationHandler = { _ in }
        api.messagesHandler = { id, cursor, _ in
            cursor == nil ? Page(items: [message("m2", at: 10), message("m1", at: 0)], nextCursor: "mc2") : Page(items: [message("m3", at: 20)], nextCursor: nil)
        }
        return (HistoryViewModel(api: api, local: local), api)
    }

    @Test func loadListsConversations() async {
        let (vm, _) = make()
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.conversations.map(\.id) == ["a", "b"])
        #expect(vm.source == .server)
        #expect(vm.hasMore)
    }

    @Test func paginationAppendsAndStops() async {
        let (vm, api) = make()
        await vm.load()
        await vm.loadMore()
        #expect(vm.conversations.map(\.id) == ["a", "b", "c"])
        #expect(!vm.hasMore)
        await vm.loadMore()
        #expect(api.calls.get == ["conversations:-", "conversations:c2"])
    }

    @Test func emptyStateExplainsHowToFillIt() async {
        let (vm, _) = make(pages: [nil: Page(items: [], nextCursor: nil)])
        await vm.load()
        #expect(vm.phase == .empty)
        #expect(vm.emptyMessage.contains("Talk to ZORO"))
    }

    @Test func searchFiltersByTitleOrPreview() async {
        let (vm, _) = make()
        await vm.load()
        vm.searchText = "trip"
        #expect(vm.visibleConversations.map(\.id) == ["b"])
        vm.searchText = "milk"
        #expect(vm.visibleConversations.count == 2, "the preview text matches")
        vm.searchText = "zzz"
        #expect(vm.visibleConversations.isEmpty)
        #expect(vm.emptyMessage.contains("No conversation matches"))
    }

    @Test func errorStates() async {
        let (vm, api) = make()
        api.conversationsHandler = { _, _ in throw ZoroError.http(status: 500, body: nil) }
        await vm.load()
        #expect(vm.phase.failure != nil && !vm.phase.isDisconnected)
        api.conversationsHandler = { _, _ in throw ZoroError.transport("x") }
        await vm.load()
        #expect(vm.phase.isDisconnected)
    }

    @Test func deleteRemovesOnServerAndOnThisDevice() async {
        let local = FakeLocalStore()
        let (vm, api) = make(local: local)
        await vm.load()
        await vm.delete(vm.conversations[0])
        #expect(vm.conversations.map(\.id) == ["b"])
        #expect(api.calls.get.contains("deleteConversation:a"))
        #expect(local.deleted.get == ["a"])
        #expect(vm.notice == .success("Deleted."))
    }

    @Test func deleteFailureBringsTheRowBack() async {
        let (vm, api) = make()
        api.deleteConversationHandler = { _ in throw ZoroError.timeout }
        await vm.load()
        await vm.delete(vm.conversations[0])
        #expect(vm.conversations.map(\.id) == ["a", "b"])
        #expect(vm.notice?.kind == .failure)
        #expect(!vm.isDeleting("a"))
    }

    @Test func deletingTheLastOneShowsEmptyAndFailureRestoresLoaded() async {
        let (vm, api) = make(pages: [nil: Page(items: [conversation("a")], nextCursor: nil)])
        await vm.load()
        api.deleteConversationHandler = { _ in throw ZoroError.timeout }
        await vm.delete(vm.conversations[0])
        #expect(vm.phase == .loaded)
        api.deleteConversationHandler = { _ in }
        await vm.delete(vm.conversations[0])
        #expect(vm.phase == .empty)
    }

    @Test func offlineShowsTheLocalCopyReadOnly() async {
        let local = FakeLocalStore()
        local.summaries = [conversation("L1", "On device")]
        local.stored["L1"] = [message("lm2", at: 5), message("lm1", at: 0)]
        let (vm, api) = make(local: local)
        api.conversationsHandler = { _, _ in throw ZoroError.transport("x") }
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.source == .thisDevice)
        #expect(vm.notice?.text.hasPrefix("Showing conversations saved on this device.") == true)
        #expect(!vm.canDelete)
        await vm.delete(vm.conversations[0])
        #expect(vm.conversations.count == 1)
        #expect(vm.notice?.text.contains("Reconnect") == true)
        await vm.open(vm.conversations[0])
        #expect(vm.messages.map(\.id) == ["lm1", "lm2"])
    }

    @Test func offlineWithNothingStoredIsDisconnected() async {
        let (vm, api) = make(local: FakeLocalStore())
        api.conversationsHandler = { _, _ in throw ZoroError.transport("x") }
        await vm.load()
        #expect(vm.phase.isDisconnected)
    }

    @Test func openLoadsMessagesOldestFirstWithPagination() async {
        let (vm, _) = make()
        await vm.load()
        await vm.open(vm.conversations[0])
        #expect(vm.messagesPhase == .loaded)
        #expect(vm.messages.map(\.id) == ["m1", "m2"])
        #expect(vm.hasMoreMessages)
        await vm.loadMoreMessages()
        #expect(vm.messages.map(\.id) == ["m1", "m2", "m3"])
        #expect(!vm.hasMoreMessages)
    }

    @Test func openErrorAndEmptyMessagesAndContinue() async {
        let (vm, api) = make()
        await vm.load()
        api.messagesHandler = { _, _, _ in Page(items: [], nextCursor: nil) }
        await vm.open(vm.conversations[0])
        #expect(vm.messagesPhase == .empty)
        api.messagesHandler = { _, _, _ in throw ZoroError.transport("x") }
        await vm.open(vm.conversations[0])
        #expect(vm.messagesPhase.isDisconnected)
        var continued: String?
        vm.onContinue = { continued = $0 }
        vm.continueOpened()
        #expect(continued == "a")
        vm.closeConversation()
        #expect(vm.opened == nil)
    }

    @Test func deletingTheOpenConversationClosesIt() async {
        let (vm, _) = make()
        await vm.load()
        await vm.open(vm.conversations[0])
        await vm.delete(vm.conversations[0])
        #expect(vm.opened == nil)
    }
}

// MARK: - Agent activity (driven through a real ConversationManager with a scripted API)

final class ScriptedTurnAPI: ZoroAPI, @unchecked Sendable {
    let events: [TurnEvent]
    let resumeEvents: [TurnEvent]
    let startError: ZoroError?
    init(events: [TurnEvent], resumeEvents: [TurnEvent] = [], startError: ZoroError? = nil) {
        self.events = events
        self.resumeEvents = resumeEvents
        self.startError = startError
    }
    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        if let startError { return AsyncThrowingStream { $0.finish(throwing: startError) } }
        return stream(events)
    }
    func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> { stream(resumeEvents) }
    private func stream(_ list: [TurnEvent]) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { c in
            for e in list { c.yield(e) }
            c.finish()
        }
    }
    func pair(_ request: PairRequest) async throws -> PairResponse { throw ZoroError.busy }
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { throw ZoroError.busy }
    func token(_ request: TokenRequest) async throws -> TokenResponse { throw ZoroError.busy }
    func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response { throw ZoroError.busy }
    func send(_ request: APIRequest) async throws { throw ZoroError.busy }
    func sendRaw(_ request: APIRequest) async throws -> Data { throw ZoroError.busy }
    func cancelTurn(id turnId: String) async throws {}
    func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> { throw ZoroError.busy }
    func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> { throw ZoroError.busy }
    func deleteConversation(id: String) async throws { throw ZoroError.busy }
    func pendingApprovals() async throws -> [ApprovalRequest] { [approval("pending-1")] }
    func securityState() async throws -> SecurityState { throw ZoroError.busy }
    func setPrivacyMode(_ update: PrivacyModeUpdate) async throws { throw ZoroError.busy }
    func setKillSwitch(_ update: KillSwitchUpdate) async throws { throw ZoroError.busy }
    func setPermission(key: String, _ update: PermissionUpdate) async throws { throw ZoroError.busy }
    func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws { throw ZoroError.busy }
    func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> { throw ZoroError.busy }
    func capabilities() async throws -> [Capability] { throw ZoroError.busy }
    func costSummary(groupBy: CostGroupBy) async throws -> CostSummary { throw ZoroError.busy }
    func modelRoutes() async throws -> [ModelRouteInfo] { throw ZoroError.busy }
}

func approval(_ id: String, agent: AgentId = .finance) -> ApprovalRequest {
    ApprovalRequest(
        approvalId: id, turnId: "t1", tool: "finance.export_report", agent: agent, risk: .high, level: .confirm,
        title: "Export your report", summary: "Save a PDF of this month's spending.", actionDigest: "abc", expiresAt: t0.addingTimeInterval(300))
}

/// Holds the approval open until the test releases it.
actor GatedApprovals: ApprovalHandling {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        if !released { await withCheckedContinuation { continuation = $0 } }
        return ApprovalDecision(approvalId: request.approvalId, approved: true, actionDigest: request.actionDigest, deviceId: "dev_me", signedAt: t0, signatureB64: "c2ln")
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Suite("Agent activity view model")
struct AgentActivityTests {
    let started = TurnEvent.turnStarted(TurnStarted(turnId: "t1", conversationId: "c1", privacyMode: .strictPrivate))
    let completed = TurnEvent.turnCompleted(TurnCompleted(turnId: "t1", messageId: "msg1", language: "en", dataClasses: [], cloudVoiceAllowed: false, usage: UsageSummary()))

    func manager(_ api: ScriptedTurnAPI, approvals: any ApprovalHandling = UnavailableService()) -> ConversationManager {
        ConversationManager(api: api, approvals: approvals, deviceActions: UnavailableService(), clientContext: ClientContext(platform: .macos), now: { t0 })
    }

    @Test func idleManagerIsEmptyWithAnExplanation() {
        let vm = AgentActivityViewModel(manager: manager(ScriptedTurnAPI(events: [])))
        #expect(vm.phase == .empty)
        #expect(vm.emptyMessage == "Nothing running. Agents show up here while they work.")
        #expect(vm.headline == "Nothing running.")
        #expect(!vm.isBusy)
    }

    @Test func finishedTurnShowsAgentsAndToolsWithRiskBadges() async {
        let events: [TurnEvent] = [
            started,
            .agentStarted(AgentStarted(agent: .finance, task: "Summing this month")),
            .toolStarted(ToolStarted(callId: "k1", tool: "finance.spending_summary", agent: .finance, risk: .low)),
            .toolFinished(ToolFinished(callId: "k1", ok: true, durationMs: 420, summary: "3 categories")),
            .toolStarted(ToolStarted(callId: "k2", tool: "finance.export_report", agent: .finance, risk: .high)),
            .toolFinished(ToolFinished(callId: "k2", ok: false, durationMs: 1500)),
            .agentFinished(AgentFinished(agent: .finance, ok: true, durationMs: 2300)),
            .textDelta(TextDelta(text: "Done")),
            completed,
        ]
        let m = manager(ScriptedTurnAPI(events: events))
        let vm = AgentActivityViewModel(manager: m)
        await m.send("how much did I spend")
        #expect(vm.phase == .loaded)
        #expect(vm.headline == "Done.")
        #expect(vm.agents == [AgentRow(agent: .finance, name: "Finance", symbol: "indianrupeesign.circle", status: .done, detail: "Summing this month, 2.3 s")])
        #expect(vm.tools.map(\.title) == ["Spending summary", "Export report"])
        #expect(vm.tools.map(\.riskLabel) == ["Low risk", "High risk"])
        #expect(vm.tools.map(\.status) == [.done, .failed])
        #expect(vm.tools[0].detail == "3 categories, 420 ms")
        #expect(vm.tools[1].detail == "1.5 s")
    }

    @Test func anApprovalMarksTheWaitingAgentAsNeedingYou() async throws {
        let req = approval("ap1")
        let events: [TurnEvent] = [
            started,
            .agentStarted(AgentStarted(agent: .finance, task: "Preparing the export")),
            .agentStarted(AgentStarted(agent: .memory, task: "Recalling preferences")),
            .approvalRequired(ApprovalRequired(approval: req)),
            .turnSuspended(TurnSuspended(turnId: "t1", reason: .approval)),
        ]
        let gate = GatedApprovals()
        let m = manager(ScriptedTurnAPI(events: events, resumeEvents: [completed]), approvals: gate)
        let vm = AgentActivityViewModel(manager: m)
        let sending = Task { await m.send("export my report") }
        var waited = 0
        while vm.currentApproval == nil && waited < 500 {
            try await Task.sleep(nanoseconds: 5_000_000)
            waited += 1
        }
        let waiting = try #require(vm.currentApproval)
        #expect(waiting.title == "Export your report")
        #expect(waiting.risk == .high)
        #expect(vm.headline == "Waiting for your approval.")
        #expect(vm.agents.first { $0.agent == .finance }?.status == .needsYou)
        #expect(vm.agents.first { $0.agent == .memory }?.status == .working)
        await gate.release()
        await sending.value
        #expect(vm.currentApproval == nil)
    }

    @Test func aFailedTurnWithNoActivityIsAnError() async {
        let events: [TurnEvent] = [started, .error(TurnError(code: "boom", message: "The finance tool broke", retryable: false))]
        let m = manager(ScriptedTurnAPI(events: events))
        let vm = AgentActivityViewModel(manager: m)
        await m.send("hi")
        #expect(vm.phase.failure != nil)
        #expect(vm.headline.contains("finance tool broke"))
    }

    @Test func aTransportFailureShowsDisconnected() async {
        let m = manager(ScriptedTurnAPI(events: [], startError: .transport("down")))
        let vm = AgentActivityViewModel(manager: m)
        await m.send("hi")
        #expect(vm.phase.isDisconnected)
        #expect(vm.headline == SystemCopy.unreachable)
    }

    @Test func approvalsWaitingElsewhereAreListed() async {
        let vm = AgentActivityViewModel(manager: manager(ScriptedTurnAPI(events: [])), api: ScriptedTurnAPI(events: []))
        await vm.loadWaiting()
        #expect(vm.waitingPhase == .loaded)
        #expect(vm.waitingElsewhere.map(\.id) == ["pending-1"])
    }

    @Test func durationText() {
        #expect(AgentActivityViewModel.durationText(250) == "250 ms")
        #expect(AgentActivityViewModel.durationText(2300) == "2.3 s")
        #expect(AgentActivityViewModel.durationText(-1) == nil)
    }
}
