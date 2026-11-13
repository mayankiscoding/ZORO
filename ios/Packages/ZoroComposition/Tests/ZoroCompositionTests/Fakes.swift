import AgentClient
import Foundation
import ZoroCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw ZoroError.storage("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
    }
}

/// A scripted `ZoroAPI`: `send`/`sendRaw` answer by path from `responses`; every request is recorded.
/// Unscripted calls fail with `notPaired`, the same as an unpaired device.
final class FakeAPI: ZoroAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [APIRequest] = []
    var responses: [String: Data] = [:]
    var errors: [String: ZoroError] = [:]
    var pending: [ApprovalRequest] = []
    var pendingError: ZoroError?

    var requests: [APIRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    private func answer(_ request: APIRequest) throws -> Data {
        lock.lock()
        _requests.append(request)
        let error = errors[request.path]
        let data = responses[request.path]
        lock.unlock()
        if let error { throw error }
        guard let data else { throw ZoroError.notPaired }
        return data
    }

    func pair(_ request: PairRequest) async throws -> PairResponse { throw ZoroError.notPaired }
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { throw ZoroError.notPaired }
    func token(_ request: TokenRequest) async throws -> TokenResponse { throw ZoroError.notPaired }
    func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        try ZoroJSON.decoder().decode(Response.self, from: try answer(request))
    }
    func send(_ request: APIRequest) async throws { _ = try answer(request) }
    func sendRaw(_ request: APIRequest) async throws -> Data { try answer(request) }
    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ZoroError.notPaired) }
    }
    func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ZoroError.notPaired) }
    }
    func cancelTurn(id turnId: String) async throws {}
    func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> { throw ZoroError.notPaired }
    func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> { throw ZoroError.notPaired }
    func deleteConversation(id: String) async throws {}
    func pendingApprovals() async throws -> [ApprovalRequest] {
        if let pendingError { throw pendingError }
        return pending
    }
    func securityState() async throws -> SecurityState { throw ZoroError.notPaired }
    func setPrivacyMode(_ update: PrivacyModeUpdate) async throws {}
    func setKillSwitch(_ update: KillSwitchUpdate) async throws {}
    func setPermission(key: String, _ update: PermissionUpdate) async throws {}
    func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws {}
    func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> { throw ZoroError.notPaired }
    func capabilities() async throws -> [Capability] { [] }
    func costSummary(groupBy: CostGroupBy) async throws -> CostSummary { throw ZoroError.notPaired }
    func modelRoutes() async throws -> [ModelRouteInfo] { [] }
}

/// Signs nothing: returns a decision shaped like the device's, or throws what it was told to.
final class FakeApprovals: ApprovalHandling, @unchecked Sendable {
    var approve = true
    var error: ZoroError?
    private(set) var asked: [String] = []

    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        asked.append(request.approvalId)
        if let error { throw error }
        return ApprovalDecision(
            approvalId: request.approvalId, approved: approve, actionDigest: request.actionDigest, deviceId: "dev_test",
            signedAt: Date(timeIntervalSince1970: 1_900_000_000), signatureB64: "c2lnbmF0dXJl")
    }
}

/// Records URL requests and answers from a script (status per call, in order).
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int]
    private(set) var seen: [URLRequest] = []
    let body: Data

    init(statuses: [Int], body: Data = Data("{}".utf8)) {
        self.statuses = statuses
        self.body = body
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        lock.lock()
        seen.append(request)
        let status = statuses.isEmpty ? 200 : statuses.removeFirst()
        lock.unlock()
        return HTTPResponse(status: status, body: body)
    }

    func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        HTTPStreamResponse(status: 500, body: AsyncThrowingStream { $0.finish() })
    }
}

/// Hands out "token-1", then "token-2" after an invalidation.
actor CountingTokens: AccessTokenProviding {
    private(set) var issued = 0
    private var current: String?

    func validAccessToken() async throws -> String {
        if let current { return current }
        issued += 1
        let token = "token-\(issued)"
        current = token
        return token
    }

    func invalidate(token: String) async {
        if token == current { current = nil }
    }
}

func approvalRequest(_ id: String, expiresIn seconds: TimeInterval = 120, tainted: Bool = false, now: Date = Date()) -> ApprovalRequest {
    ApprovalRequest(
        approvalId: id, tool: "automation.run_routine", risk: .high, level: .confirm, title: "Run the evening routine",
        summary: "Turn off the lights.", details: [LabelValue(label: "Routine", value: "Evening")], actionDigest: "digest-\(id)",
        expiresAt: now.addingTimeInterval(seconds), tainted: tainted)
}
