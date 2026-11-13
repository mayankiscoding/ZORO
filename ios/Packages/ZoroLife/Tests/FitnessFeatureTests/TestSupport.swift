import Foundation
import ZoroCore

/// Thread-safe box for test bookkeeping.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
    var get: Value { withLock { $0 } }
}

/// Fixtures are generated from the real Pydantic models (scripts/generate_fixtures.py).
enum Fixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw ZoroError.storage("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try ZoroJSON.decoder().decode(T.self, from: data(name))
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name), options: [.fragmentsAllowed])
    }

    static func card(_ name: String) throws -> UICard { try decode(UICard.self, name) }
}

/// A `ZoroAPI` that answers from a table of routes ("GET /v1/fitness/summary") and records every request.
/// Everything it does not script fails like an unpaired device.
final class FakeAPI: ZoroAPI, @unchecked Sendable {
    private let base = UnavailableService()
    private let routes = Locked<[String: Result<Data, Error>]>([:])
    let calls = Locked<[APIRequest]>([])
    let turnEvents = Locked<[TurnEvent]>([])
    let turnError = Locked<Error?>(nil)
    let turns = Locked<[TurnRequest]>([])

    func reply(_ method: HTTPMethod, _ path: String, fixture: String) throws {
        let data = try Fixtures.data(fixture)
        routes.withLock { $0["\(method.rawValue) \(path)"] = .success(data) }
    }

    func reply(_ method: HTTPMethod, _ path: String, json: String) {
        routes.withLock { $0["\(method.rawValue) \(path)"] = .success(Data(json.utf8)) }
    }

    func fail(_ method: HTTPMethod, _ path: String, with error: Error) {
        routes.withLock { $0["\(method.rawValue) \(path)"] = .failure(error) }
    }

    func requests(_ path: String) -> [APIRequest] { calls.get.filter { $0.path == path } }

    private func answer(_ request: APIRequest) throws -> Data {
        calls.withLock { $0.append(request) }
        guard let result = routes.get["\(request.method.rawValue) \(request.path)"] else {
            throw ZoroError.transport("no route for \(request.method.rawValue) \(request.path)")
        }
        return try result.get()
    }

    func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        let data = try answer(request)
        do {
            return try ZoroJSON.decoder().decode(Response.self, from: data)
        } catch {
            throw ZoroError.decoding(String(describing: error))
        }
    }

    func send(_ request: APIRequest) async throws { _ = try answer(request) }
    func sendRaw(_ request: APIRequest) async throws -> Data { try answer(request) }

    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        turns.withLock { $0.append(request) }
        let events = turnEvents.get
        let error = turnError.get
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish(throwing: error)
        }
    }

    func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> { base.resumeTurn(id: turnId, request) }
    func cancelTurn(id turnId: String) async throws { try await base.cancelTurn(id: turnId) }
    func pair(_ request: PairRequest) async throws -> PairResponse { try await base.pair(request) }
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { try await base.challenge(request) }
    func token(_ request: TokenRequest) async throws -> TokenResponse { try await base.token(request) }
    func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> { try await base.conversations(cursor: cursor, limit: limit) }
    func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> { try await base.messages(conversationId: conversationId, cursor: cursor, limit: limit) }
    func deleteConversation(id: String) async throws { try await base.deleteConversation(id: id) }
    func pendingApprovals() async throws -> [ApprovalRequest] { try await base.pendingApprovals() }
    func securityState() async throws -> SecurityState { try await base.securityState() }
    func setPrivacyMode(_ update: PrivacyModeUpdate) async throws { try await base.setPrivacyMode(update) }
    func setKillSwitch(_ update: KillSwitchUpdate) async throws { try await base.setKillSwitch(update) }
    func setPermission(key: String, _ update: PermissionUpdate) async throws { try await base.setPermission(key: key, update) }
    func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws { try await base.revokeDevice(id: id, revoke) }
    func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> { try await base.auditLog(cursor: cursor, limit: limit) }
    func capabilities() async throws -> [Capability] { try await base.capabilities() }
    func costSummary(groupBy: CostGroupBy) async throws -> CostSummary { try await base.costSummary(groupBy: groupBy) }
    func modelRoutes() async throws -> [ModelRouteInfo] { try await base.modelRoutes() }
}

/// The request body as a JSON object.
func bodyObject(_ request: APIRequest?) throws -> [String: Any] {
    guard let data = request?.body, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ZoroError.storage("request has no JSON object body")
    }
    return object
}
