import Foundation
import ZoroCore
@testable import ZoroAppUI

/// A server fake for the intent tests: scripted turn events, a stream that can hang, recorded cancels.
struct ScriptedTurnAPI: ZoroAPI {
    var events: [TurnEvent] = []
    var error: Error?
    /// Keeps the stream open after the events (timeouts, cancellation).
    var hangs = false
    var conversationList: Result<[ConversationSummary], ZoroError> = .success([])
    var security: Result<SecurityState, ZoroError> = .success(FakeAPI.state(.cloudIntelligence))
    var setPrivacyError: ZoroError?
    let turns = Recorder<TurnRequest>()
    let cancels = Recorder<String>()
    let privacyUpdates = Recorder<PrivacyModeUpdate>()

    private var u: UnavailableService { UnavailableService() }

    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        turns.append(request)
        let (events, error, hangs) = (self.events, self.error, self.hangs)
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            if !hangs { c.finish(throwing: error) }
        }
    }
    func cancelTurn(id turnId: String) async throws { cancels.append(turnId) }
    func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> {
        Page(items: Array(try conversationList.get().prefix(limit ?? 50)))
    }
    func securityState() async throws -> SecurityState { try security.get() }
    func setPrivacyMode(_ update: PrivacyModeUpdate) async throws {
        if let setPrivacyError { throw setPrivacyError }
        privacyUpdates.append(update)
    }

    func pair(_ request: PairRequest) async throws -> PairResponse { try await u.pair(request) }
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { try await u.challenge(request) }
    func token(_ request: TokenRequest) async throws -> TokenResponse { try await u.token(request) }
    func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response { try await u.send(request, as: type) }
    func send(_ request: APIRequest) async throws { try await u.send(request) }
    func sendRaw(_ request: APIRequest) async throws -> Data { try await u.sendRaw(request) }
    func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> { u.resumeTurn(id: turnId, request) }
    func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> { try await u.messages(conversationId: conversationId, cursor: cursor, limit: limit) }
    func deleteConversation(id: String) async throws {}
    func pendingApprovals() async throws -> [ApprovalRequest] { [] }
    func setKillSwitch(_ update: KillSwitchUpdate) async throws {}
    func setPermission(key: String, _ update: PermissionUpdate) async throws {}
    func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws {}
    func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> { try await u.auditLog(cursor: cursor, limit: limit) }
    func capabilities() async throws -> [Capability] { [] }
    func costSummary(groupBy: CostGroupBy) async throws -> CostSummary { try await u.costSummary(groupBy: groupBy) }
    func modelRoutes() async throws -> [ModelRouteInfo] { [] }
}

/// A device identity that signs with a fixed id, or fails like a cancelled Face ID prompt.
struct ProofSigningIdentity: DeviceIdentityProviding {
    var id: String? = "dev_1"
    var signingError: ZoroError?
    var signedBy: String = "dev_1"
    let signed = Recorder<String>()

    private var u: UnavailableService { UnavailableService() }

    func deviceId() async -> String? { id }
    func signProof(action: String, subject: String, key: ProofKey, at date: Date) async throws -> SignedProof {
        if let signingError { throw signingError }
        signed.append("\(action)|\(subject)")
        return SignedProof(deviceId: signedBy, signedAt: date, signatureB64: "c2ln", key: key)
    }
    func pairRequest(pairingCode: String, deviceName: String, platform: DevicePlatform, capabilities: [String], appVersion: String?) async throws -> PairRequest {
        try await u.pairRequest(pairingCode: pairingCode, deviceName: deviceName, platform: platform, capabilities: capabilities, appVersion: appVersion)
    }
    func completePairing(_ response: PairResponse) async throws {}
    func signChallenge(nonce: String) async throws -> TokenRequest { try await u.signChallenge(nonce: nonce) }
    func signApproval(_ request: ApprovalRequest, approved: Bool, at date: Date) async throws -> ApprovalDecision {
        try await u.signApproval(request, approved: approved, at: date)
    }
    func unpair() async throws {}
}

/// A runner that returns a fixed outcome and records requests.
struct FixedRunner: IntentTurnRunning {
    var outcome: IntentTurnOutcome
    let requests = Recorder<IntentTurnRequest>()
    func run(_ request: IntentTurnRequest) async -> IntentTurnOutcome {
        requests.append(request)
        return outcome
    }
}

enum TurnScript {
    static let started = TurnEvent.turnStarted(TurnStarted(turnId: "turn_1", conversationId: "conv_1", privacyMode: .strictPrivate))

    static func completed(language: String = "en", classes: [DataClass] = [.personal]) -> TurnEvent {
        .turnCompleted(TurnCompleted(
            turnId: "turn_1", messageId: "msg_1", language: language, dataClasses: classes,
            cloudVoiceAllowed: false, usage: UsageSummary()))
    }

    static func answer(_ text: String, cards: [UICard] = [], language: String = "en", classes: [DataClass] = [.personal]) -> [TurnEvent] {
        [started] + [.textDelta(TextDelta(text: text))] + cards.map { .card(CardEvent(card: $0)) } + [completed(language: language, classes: classes)]
    }

    static func suspended(_ reason: SuspendReason) -> [TurnEvent] {
        [started, .textDelta(TextDelta(text: "One moment.")), .turnSuspended(TurnSuspended(turnId: "turn_1", reason: reason))]
    }
}

func conversationSummaries() -> [ConversationSummary] {
    let at = Date(timeIntervalSince1970: 1_794_475_815)
    return [
        ConversationSummary(id: "c1", title: "Grocery basket for Sunday", updatedAt: at),
        ConversationSummary(id: "c2", title: "Café bills in October", updatedAt: at.addingTimeInterval(-60)),
        ConversationSummary(id: "c3", title: "  ", updatedAt: at.addingTimeInterval(-120)),
    ]
}
