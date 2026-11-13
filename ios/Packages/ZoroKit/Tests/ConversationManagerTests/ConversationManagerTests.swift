import Foundation
import SecurityManager
import Testing
import ZoroCore
@testable import ConversationManager

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ v: Value) { value = v }
    func update<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
    var get: Value { update { $0 } }
}

/// Plays one scripted event list per startTurn/resumeTurn call.
final class ScriptedAPI: ZoroAPI, @unchecked Sendable {
    enum Script { case events([TurnEvent]), failure(ZoroError), hang }
    let scripts: Box<[Script]>
    let turnRequests = Box<[TurnRequest]>([])
    let resumes = Box<[(String, ResumeRequest)]>([])
    let cancels = Box<[String]>([])
    /// Message pages by cursor ("" = first page); a missing page fails like a server error.
    let messagePages = Box<[String: Page<Message>]>([:])
    let messageCalls = Box<[(String, String?)]>([])

    init(_ scripts: [Script]) { self.scripts = Box(scripts) }

    private func next() -> AsyncThrowingStream<TurnEvent, Error> {
        let script = scripts.update { $0.isEmpty ? Script.failure(.transport("no script")) : $0.removeFirst() }
        return AsyncThrowingStream { c in
            switch script {
            case .events(let events):
                for e in events { c.yield(e) }
                c.finish()
            case .failure(let e): c.finish(throwing: e)
            case .hang: break  // never finishes until cancelled
            }
        }
    }

    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        turnRequests.update { $0.append(request) }
        return next()
    }
    func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        resumes.update { $0.append((turnId, request)) }
        return next()
    }
    func cancelTurn(id turnId: String) async throws { cancels.update { $0.append(turnId) } }

    func pair(_ request: PairRequest) async throws -> PairResponse { throw ZoroError.busy }
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { throw ZoroError.busy }
    func token(_ request: TokenRequest) async throws -> TokenResponse { throw ZoroError.busy }
    func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response { throw ZoroError.busy }
    func send(_ request: APIRequest) async throws { throw ZoroError.busy }
    func sendRaw(_ request: APIRequest) async throws -> Data { throw ZoroError.busy }
    func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> { throw ZoroError.busy }
    func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> {
        messageCalls.update { $0.append((conversationId, cursor)) }
        guard let page = messagePages.get[cursor ?? ""] else { throw ZoroError.http(status: 404, body: nil) }
        return page
    }
    func deleteConversation(id: String) async throws { throw ZoroError.busy }
    func pendingApprovals() async throws -> [ApprovalRequest] { throw ZoroError.busy }
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

struct ScriptedApprovals: ApprovalHandling {
    let outcome: Result<Bool, ZoroError>
    let seen = Box<[ApprovalRequest]>([])
    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        seen.update { $0.append(request) }
        let approved = try outcome.get()
        return ApprovalDecision(
            approvalId: request.approvalId, approved: approved, actionDigest: request.actionDigest, deviceId: "dev_1",
            signedAt: Date(timeIntervalSince1970: 1_794_475_815), signatureB64: "c2ln")
    }
}

struct RecordingExecutor: DeviceActionExecuting {
    let seen = Box<[String]>([])
    var supportedTools: [String] { ["ios.alarm.create"] }
    func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
        seen.update { $0.append(request.actionId) }
        return DeviceActionResult(actionId: request.actionId, ok: true, result: ["alarm_id": "A1"], executedAt: Date(timeIntervalSince1970: 1_794_475_816))
    }
}

private let expiry = Date(timeIntervalSince1970: 4_000_000_000)
private let started = TurnEvent.turnStarted(TurnStarted(turnId: "t1", conversationId: "c1", privacyMode: .strictPrivate))
private func completed(_ message: String = "msg_1") -> TurnEvent {
    .turnCompleted(TurnCompleted(turnId: "t1", messageId: message, language: "en", dataClasses: [.personal], cloudVoiceAllowed: false, usage: UsageSummary()))
}
private let approvalRequest = ApprovalRequest(
    approvalId: "ap_1", turnId: "t1", tool: "comms.send_email", risk: .high, level: .confirm, title: "Send email",
    summary: "Running late", actionDigest: "dd", expiresAt: expiry)
private let alarm = DeviceActionRequest(actionId: "act_1", turnId: "t1", tool: "ios.alarm.create", args: ["time": "07:00"], risk: .medium, expiresAt: expiry)

@MainActor
private func makeManager(_ api: ScriptedAPI, approvals: ScriptedApprovals = ScriptedApprovals(outcome: .success(true)),
                         executor: RecordingExecutor = RecordingExecutor(), store: ConversationStore? = nil) -> ConversationManager {
    ConversationManager(api: api, approvals: approvals, deviceActions: executor, store: store, clientContext: ClientContext(platform: .ios))
}

@Suite("Conversation manager", .timeLimit(.minutes(1)))
@MainActor
struct ConversationManagerTests {
    @Test func streamsTextActivityAndCards() async throws {
        let api = ScriptedAPI([.events([
            started,
            .route(RouteDecided(agents: [.finance], reason: "spending", dataClasses: [.financial], engine: .deterministic)),
            .agentStarted(AgentStarted(agent: .finance, task: "October spending")),
            .toolStarted(ToolStarted(callId: "call_1", tool: "finance.spending_summary", agent: .finance, risk: .low)),
            .toolFinished(ToolFinished(callId: "call_1", ok: true, durationMs: 12, summary: "3 categories")),
            .textDelta(TextDelta(text: "You spent ")),
            .card(CardEvent(card: UICard(kind: "finance_summary", payload: ["total": "1234.50"]))),
            .textDelta(TextDelta(text: "₹1,234.50.")),
            .unknown(type: "future", payload: [:]),
            .agentFinished(AgentFinished(agent: .finance, ok: true, durationMs: 40)),
            completed(),
        ])])
        let manager = makeManager(api)
        await manager.send("  October spending?  ")
        #expect(manager.phase == .completed)
        #expect(manager.turnId == "t1" && manager.conversationId == "c1" && manager.privacyMode == .strictPrivate)
        #expect(manager.transcript.map(\.role) == [.user, .assistant])
        #expect(manager.transcript[0].text == "October spending?")
        let reply = manager.transcript[1]
        #expect(reply.text == "You spent ₹1,234.50." && reply.id == "msg_1" && !reply.isStreaming && reply.agents == [.finance])
        #expect(reply.cards.count == 1 && manager.cards.count == 1)
        #expect(manager.agents == [AgentActivity(agent: .finance, task: "October spending", state: .finished(ok: true, durationMs: 40))])
        #expect(manager.tools.first?.state == .finished(ok: true, durationMs: 12, summary: "3 categories"))
        #expect(api.turnRequests.get.first?.conversationId == nil)

        // The follow-up continues the same conversation.
        api.scripts.update { $0 = [.events([started, .textDelta(TextDelta(text: "ok")), completed("msg_2")])] }
        await manager.send("add the second one")
        #expect(api.turnRequests.get.last?.conversationId == "c1")
        #expect(manager.transcript.count == 4)
    }

    @Test func approvalSuspendsAndResumesWithSignedDecision() async throws {
        let api = ScriptedAPI([
            .events([started, .approvalRequired(ApprovalRequired(approval: approvalRequest)),
                     .turnSuspended(TurnSuspended(turnId: "t1", reason: .approval))]),
            .events([.toolStarted(ToolStarted(callId: "c2", tool: "comms.send_email", agent: .communication, risk: .high)),
                     .textDelta(TextDelta(text: "Sent.")), completed()]),
        ])
        let approvals = ScriptedApprovals(outcome: .success(true))
        let manager = makeManager(api, approvals: approvals)
        await manager.send("email HR I'm running late")
        #expect(approvals.seen.get.map(\.approvalId) == ["ap_1"])
        let resume = try #require(api.resumes.get.first)
        #expect(resume.0 == "t1")
        #expect(resume.1.approval?.approved == true && resume.1.approval?.actionDigest == "dd")
        #expect(resume.1.deviceResult == nil)
        #expect(manager.phase == .completed)
        #expect(manager.transcript.last?.text == "Sent.")
    }

    @Test func deviceActionRunsLocallyThenResumes() async throws {
        let api = ScriptedAPI([
            .events([started, .deviceAction(DeviceActionEvent(action: alarm)), .turnSuspended(TurnSuspended(turnId: "t1", reason: .deviceAction))]),
            .events([.textDelta(TextDelta(text: "Alarm set for 7.")), completed()]),
        ])
        let executor = RecordingExecutor()
        let manager = makeManager(api, executor: executor)
        await manager.send("wake me at 7")
        #expect(executor.seen.get == ["act_1"])
        let resume = try #require(api.resumes.get.first)
        #expect(resume.1.deviceResult?.ok == true && resume.1.deviceResult?.result?["alarm_id"] == "A1")
        #expect(manager.phase == .completed)
    }

    @Test func dismissedApprovalCancelsTheTurn() async {
        let api = ScriptedAPI([.events([started, .approvalRequired(ApprovalRequired(approval: approvalRequest)),
                                        .turnSuspended(TurnSuspended(turnId: "t1", reason: .approval))])])
        let manager = makeManager(api, approvals: ScriptedApprovals(outcome: .failure(.userCancelled)))
        await manager.send("send it")
        #expect(manager.phase == .cancelled)
        #expect(api.cancels.get == ["t1"])
        #expect(api.resumes.get.isEmpty)
    }

    @Test func expiredApprovalFailsTheTurn() async {
        let api = ScriptedAPI([.events([started, .approvalRequired(ApprovalRequired(approval: approvalRequest)),
                                        .turnSuspended(TurnSuspended(turnId: "t1", reason: .approval))])])
        let manager = makeManager(api, approvals: ScriptedApprovals(outcome: .failure(.approvalExpired)))
        await manager.send("send it")
        #expect(manager.phase == .failed(.approvalExpired))
    }

    @Test func suspensionWithoutItsRequestIsAnError() async {
        let api = ScriptedAPI([.events([started, .turnSuspended(TurnSuspended(turnId: "t1", reason: .deviceAction))])])
        let manager = makeManager(api)
        await manager.send("x")
        guard case .failed(.invalidResponse) = manager.phase else {
            Issue.record("expected invalidResponse, got \(manager.phase)")
            return
        }
    }

    @Test func serverErrorEventAndTransportFailure() async {
        let turnError = TurnError(code: "kill_switch", message: "ZORO is paused", retryable: false)
        let api = ScriptedAPI([.events([started, .textDelta(TextDelta(text: "partial")), .error(turnError)]), .failure(.timeout)])
        let manager = makeManager(api)
        await manager.send("x")
        #expect(manager.phase == .failed(.turnFailed(turnError)))
        #expect(manager.transcript.last?.isStreaming == false)
        await manager.send("y")
        #expect(manager.phase == .failed(.timeout))
    }

    @Test func streamEndingEarlyIsAnError() async {
        let manager = makeManager(ScriptedAPI([.events([started, .textDelta(TextDelta(text: "half"))])]))
        await manager.send("x")
        #expect(manager.phase == .failed(.invalidResponse("the turn stream ended before the turn finished")))
    }

    @Test func cancelStopsARunningTurn() async throws {
        let api = ScriptedAPI([.hang])
        let manager = makeManager(api)
        let sending = Task { await manager.send("long question") }
        while api.turnRequests.get.isEmpty { await Task.yield() }
        #expect(manager.isBusy)
        await manager.send("ignored while busy")
        #expect(api.turnRequests.get.count == 1)
        await manager.cancel()
        await sending.value
        #expect(manager.phase == .cancelled)
    }

    @Test func completedTurnsAreSavedEncrypted() async throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keys = InMemoryKeyStore()
        let store = try await ConversationStore.open(at: url, keys: keys)
        let api = ScriptedAPI([.events([started, .textDelta(TextDelta(text: "Namaste")), completed()])])
        let manager = makeManager(api, store: store)
        await manager.send("hello zoro")
        let saved = try await store.messages(in: "c1")
        #expect(saved.map(\.text) == ["hello zoro", "Namaste"])
        #expect(saved.last?.id == "msg_1")

        let fresh = makeManager(ScriptedAPI([]), store: store)
        try await fresh.loadConversation(id: "c1")
        #expect(fresh.transcript.map(\.text) == ["hello zoro", "Namaste"])
        #expect(fresh.conversationId == "c1")
        fresh.startNewConversation()
        #expect(fresh.transcript.isEmpty && fresh.conversationId == nil)
    }

    @Test func remoteConversationIsFetchedPageByPageAndAdopted() async throws {
        let at = Date(timeIntervalSince1970: 1_794_475_815)
        let api = ScriptedAPI([.events([started, .textDelta(TextDelta(text: "Theek hai")), completed("msg_9")])])
        api.messagePages.update {
            $0[""] = Page(items: [Message(id: "m1", role: .user, text: "remind me", createdAt: at)], nextCursor: "p2")
            $0["p2"] = Page(items: [Message(id: "m2", role: .assistant, text: "At what time?", language: "hinglish", createdAt: at, agents: [.personalAssistant])])
        }
        let manager = makeManager(api)
        try await manager.loadRemoteConversation(id: "c_phone")
        #expect(api.messageCalls.get.map { $0.0 } == ["c_phone", "c_phone"])
        #expect(api.messageCalls.get.map { $0.1 } == [nil, "p2"])
        #expect(manager.conversationId == "c_phone" && manager.phase == .idle)
        #expect(manager.transcript.map(\.id) == ["m1", "m2"])
        #expect(manager.transcript[1].language == "hinglish" && manager.transcript[1].agents == [.personalAssistant])
        // The next turn continues the adopted conversation.
        await manager.send("8 baje")
        #expect(api.turnRequests.get.first?.conversationId == "c_phone")
    }

    @Test func failedRemoteLoadLeavesTheConversationUnchanged() async throws {
        let api = ScriptedAPI([.events([started, .textDelta(TextDelta(text: "Hi")), completed()])])
        let manager = makeManager(api)
        await manager.send("hello")
        await #expect(throws: ZoroError.http(status: 404, body: nil)) { try await manager.loadRemoteConversation(id: "missing") }
        #expect(manager.conversationId == "c1" && manager.transcript.count == 2)
    }

    @Test func activityValuesHavePublicInitialisers() {
        let agent = AgentActivity(agent: .finance, task: "Spending")
        #expect(agent.state == .running && agent.id == .finance)
        let tool = ToolActivity(callId: "c", tool: "finance.spending_summary", agent: .finance, risk: .low, state: .finished(ok: true, durationMs: 3, summary: nil))
        #expect(tool.id == "c")
    }
}
