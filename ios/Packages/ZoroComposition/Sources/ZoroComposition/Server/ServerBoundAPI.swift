import AgentClient
import Foundation
import SecurityManager
import ZoroCore

/// The address of the owner's ZORO server. Unknown until first run pairs the device; set again when the
/// owner re-pairs. Thread-safe: read from any actor.
public final class ServerEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    public init(_ url: URL? = nil) { self.url = url }

    public var current: URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }

    public func set(_ newValue: URL?) {
        lock.lock()
        url = newValue
        lock.unlock()
    }
}

/// `ZoroAPI` bound to whatever server the device is paired with. Every call goes to a `ZoroAPIClient`
/// (bearer tokens from a `SessionManager`, one re-authentication on 401) built for the current address;
/// before pairing every call fails with `ZoroError.notPaired`, which the screens show as "connect to
/// your server". Feature packages and view models hold this one object, so re-pairing needs no rebuild.
public final class ServerBoundAPI: ZoroAPI, @unchecked Sendable {
    private struct Bound {
        let url: URL
        let client: ZoroAPIClient
        let session: SessionManager
    }

    public let endpoint: ServerEndpoint
    private let identity: any DeviceIdentityProviding
    private let transport: any HTTPTransport
    private let lock = NSLock()
    private var bound: Bound?

    public init(endpoint: ServerEndpoint, identity: any DeviceIdentityProviding, transport: any HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.identity = identity
        self.transport = transport
    }

    /// The client for the current address, rebuilt when the address changes.
    public func client() throws -> ZoroAPIClient {
        try current().client
    }

    /// Bearer tokens for the current address (the device channel uses the same session).
    public func tokens() throws -> any AccessTokenProviding {
        try current().session
    }

    /// An unauthenticated client for pairing with `url` (first run).
    public func authClient(for url: URL) -> any ZoroAuthAPI {
        ZoroAPIClient(baseURL: url, transport: transport)
    }

    /// Forgets the session (after unpairing or when the device was removed).
    public func signOut() async {
        let session: SessionManager? = {
            lock.lock()
            defer { lock.unlock() }
            return bound?.session
        }()
        await session?.signOut()
    }

    private func current() throws -> Bound {
        guard let url = endpoint.current else { throw ZoroError.notPaired }
        lock.lock()
        defer { lock.unlock() }
        if let bound, bound.url == url { return bound }
        let session = SessionManager(auth: ZoroAPIClient(baseURL: url, transport: transport), identity: identity)
        let client = ZoroAPIClient(baseURL: url, transport: transport, tokens: session)
        let fresh = Bound(url: url, client: client, session: session)
        bound = fresh
        return fresh
    }

    private func failing(_ error: Error) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }

    // MARK: - ZoroAuthAPI

    public func pair(_ request: PairRequest) async throws -> PairResponse { try await client().pair(request) }
    public func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { try await client().challenge(request) }
    public func token(_ request: TokenRequest) async throws -> TokenResponse { try await client().token(request) }

    // MARK: - ZoroAPI

    public func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        try await client().send(request, as: type)
    }
    public func send(_ request: APIRequest) async throws { try await client().send(request) }
    public func sendRaw(_ request: APIRequest) async throws -> Data { try await client().sendRaw(request) }

    public func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        do { return try client().startTurn(request) } catch { return failing(error) }
    }
    public func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        do { return try client().resumeTurn(id: turnId, request) } catch { return failing(error) }
    }
    public func cancelTurn(id turnId: String) async throws { try await client().cancelTurn(id: turnId) }

    public func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> {
        try await client().conversations(cursor: cursor, limit: limit)
    }
    public func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> {
        try await client().messages(conversationId: conversationId, cursor: cursor, limit: limit)
    }
    public func deleteConversation(id: String) async throws { try await client().deleteConversation(id: id) }
    public func pendingApprovals() async throws -> [ApprovalRequest] { try await client().pendingApprovals() }

    public func securityState() async throws -> SecurityState { try await client().securityState() }
    public func setPrivacyMode(_ update: PrivacyModeUpdate) async throws { try await client().setPrivacyMode(update) }
    public func setKillSwitch(_ update: KillSwitchUpdate) async throws { try await client().setKillSwitch(update) }
    public func setPermission(key: String, _ update: PermissionUpdate) async throws { try await client().setPermission(key: key, update) }
    public func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws { try await client().revokeDevice(id: id, revoke) }
    public func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> {
        try await client().auditLog(cursor: cursor, limit: limit)
    }
    public func capabilities() async throws -> [Capability] { try await client().capabilities() }
    public func costSummary(groupBy: CostGroupBy) async throws -> CostSummary { try await client().costSummary(groupBy: groupBy) }
    public func modelRoutes() async throws -> [ModelRouteInfo] { try await client().modelRoutes() }
    public func modelRoutes(privacyMode: PrivacyMode?) async throws -> [ModelRouteInfo] {
        try await client().modelRoutes(privacyMode: privacyMode)
    }
    public func voiceConfig() async throws -> VoiceConfig { try await client().voiceConfig() }
    public func updateVoiceSettings(_ settings: VoiceSettings) async throws -> VoiceSettings {
        try await client().updateVoiceSettings(settings)
    }
    public func liveSession() async throws -> LiveSessionGrant { try await client().liveSession() }
}
