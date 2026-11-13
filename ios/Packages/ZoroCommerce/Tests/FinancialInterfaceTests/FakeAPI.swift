import Foundation
import ZoroCore

/// Thread-safe box for test bookkeeping.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
    var get: Value { withLock { $0 } }
}

/// A fake `ZoroAPI` that answers "METHOD /path" with JSON bytes (usually a fixture generated from the
/// backend's Pydantic models) and decodes them with the contract decoder, like the real client.
/// Anything without a handler fails with `.transport`, so a test never reaches a network.
final class FakeAPI: ZoroAPI, @unchecked Sendable {
    typealias Handler = @Sendable (APIRequest) async throws -> Data

    let requests = Locked<[APIRequest]>([])
    let handlers = Locked<[String: Handler]>([:])

    func on(_ key: String, _ handler: @escaping Handler) { handlers.withLock { $0[key] = handler } }
    func on(_ key: String, fixture name: String) { on(key) { _ in try Fixture.data(name) } }
    func on(_ key: String, error: ZoroError) { on(key) { _ in throw error } }

    func sent(_ method: HTTPMethod, _ path: String) -> [APIRequest] {
        requests.get.filter { $0.method == method && $0.path == path }
    }

    private func handle(_ request: APIRequest) async throws -> Data {
        requests.withLock { $0.append(request) }
        guard let handler = handlers.get["\(request.method.rawValue) \(request.path)"] else {
            throw ZoroError.transport("no handler for \(request.method.rawValue) \(request.path)")
        }
        return try await handler(request)
    }

    func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        let data = try await handle(request)
        do {
            return try ZoroJSON.decoder().decode(Response.self, from: data)
        } catch {
            throw ZoroError.decoding(String(describing: error))
        }
    }
    func send(_ request: APIRequest) async throws { _ = try await handle(request) }
    func sendRaw(_ request: APIRequest) async throws -> Data { try await handle(request) }

    private var missing: ZoroError { .transport("no handler") }
    func pair(_ request: PairRequest) async throws -> PairResponse { throw missing }
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { throw missing }
    func token(_ request: TokenRequest) async throws -> TokenResponse { throw missing }
    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ZoroError.transport("no handler")) }
    }
    func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ZoroError.transport("no handler")) }
    }
    func cancelTurn(id turnId: String) async throws {}
    func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> { throw missing }
    func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> { throw missing }
    func deleteConversation(id: String) async throws { throw missing }
    func pendingApprovals() async throws -> [ApprovalRequest] { throw missing }
    func securityState() async throws -> SecurityState { throw missing }
    func setPrivacyMode(_ update: PrivacyModeUpdate) async throws { throw missing }
    func setKillSwitch(_ update: KillSwitchUpdate) async throws { throw missing }
    func setPermission(key: String, _ update: PermissionUpdate) async throws { throw missing }
    func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws { throw missing }
    func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> { throw missing }
    func capabilities() async throws -> [Capability] { throw missing }
    func costSummary(groupBy: CostGroupBy) async throws -> CostSummary { throw missing }
    func modelRoutes() async throws -> [ModelRouteInfo] { throw missing }
}

/// Loads JSON fixtures written by `scripts/generate_fixtures.py` from the real backend models.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw ZoroError.storage("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try ZoroJSON.decoder().decode(T.self, from: data(name))
    }

    static func card(_ name: String) throws -> UICard { try decode(UICard.self, name) }

    /// Fixtures are generated at 2026-11-13T09:30:00Z.
    static let generatedAt = Date(timeIntervalSince1970: 1_794_562_200)
}
