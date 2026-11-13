import Foundation
import ZoroCore

/// `ZoroAPI` over HTTP. Bearer tokens come from an `AccessTokenProviding` (SessionManager); a 401
/// triggers exactly one re-authentication and retry. Turn streams are parsed incrementally from SSE.
public final class ZoroAPIClient: ZoroAPI {
    public let baseURL: URL
    private let transport: any HTTPTransport
    private let tokens: (any AccessTokenProviding)?
    private let log = ZoroLog("api")

    /// `tokens` is nil only for a client used for pairing and session endpoints.
    public init(baseURL: URL, transport: any HTTPTransport = URLSessionTransport(), tokens: (any AccessTokenProviding)? = nil) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokens = tokens
    }

    // MARK: - Request building

    func urlRequest(_ request: APIRequest, token: String?, stream: Bool) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ZoroError.invalidResponse("bad base URL")
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.percentEncodedPath = basePath + request.path
        if !request.query.isEmpty { components.queryItems = request.query }
        guard let url = components.url else { throw ZoroError.invalidResponse("bad request path") }
        var r = URLRequest(url: url)
        r.httpMethod = request.method.rawValue
        r.httpBody = request.body
        r.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if request.body != nil { r.setValue(request.contentType ?? "application/json", forHTTPHeaderField: "Content-Type") }
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if stream { r.timeoutInterval = 300 }
        return r
    }

    /// Runs `attempt` with a bearer token; on 401 invalidates it, fetches a fresh one and retries once.
    private func withAuth<R: Sendable>(
        _ request: APIRequest, status: (R) -> Int, _ attempt: (String?) async throws -> R
    ) async throws -> R {
        guard request.requiresAuth else { return try await attempt(nil) }
        guard let tokens else { throw ZoroError.notPaired }
        let first = try await tokens.validAccessToken()
        let response = try await attempt(first)
        guard status(response) == 401 else { return response }
        log.info("401 on \(request.path); re-authenticating once")
        await tokens.invalidate(token: first)
        let second = try await tokens.validAccessToken()
        let retried = try await attempt(second)
        if status(retried) == 401 {
            await tokens.invalidate(token: second)
            throw ZoroError.unauthorized
        }
        return retried
    }

    private func perform(_ request: APIRequest) async throws -> Data {
        do {
            let response = try await withAuth(request, status: \.status) { token in
                try await transport.data(for: urlRequest(request, token: token, stream: false))
            }
            return try Self.check(status: response.status, body: response.body)
        } catch {
            throw ZoroError.wrap(error)
        }
    }

    static func check(status: Int, body: Data) throws -> Data {
        if (200..<300).contains(status) { return body }
        if status == 401 { throw ZoroError.unauthorized }
        let errorBody = try? ZoroJSON.decoder().decode(ErrorBody.self, from: body)
        throw ZoroError.http(status: status, body: errorBody)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try ZoroJSON.decoder().decode(T.self, from: data)
        } catch {
            throw ZoroError.decoding(String(describing: T.self))
        }
    }

    // MARK: - Generic

    public func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        try decode(Response.self, try await perform(request))
    }

    public func send(_ request: APIRequest) async throws {
        _ = try await perform(request)
    }

    public func sendRaw(_ request: APIRequest) async throws -> Data {
        try await perform(request)
    }

    // MARK: - Auth

    public func pair(_ request: PairRequest) async throws -> PairResponse {
        try await send(.json(.post, "/v1/auth/pair", body: request, requiresAuth: false), as: PairResponse.self)
    }

    public func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse {
        try await send(.json(.post, "/v1/auth/challenge", body: request, requiresAuth: false), as: ChallengeResponse.self)
    }

    public func token(_ request: TokenRequest) async throws -> TokenResponse {
        try await send(.json(.post, "/v1/auth/token", body: request, requiresAuth: false), as: TokenResponse.self)
    }

    // MARK: - Turns

    public func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        eventStream { try .json(.post, "/v1/turns", body: request) }
    }

    public func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        eventStream { try .json(.post, "/v1/turns/\(APIRequest.segment(turnId))/resume", body: request) }
    }

    public func cancelTurn(id turnId: String) async throws {
        try await send(APIRequest(method: .post, path: "/v1/turns/\(APIRequest.segment(turnId))/cancel"))
    }

    private func eventStream(_ build: @escaping @Sendable () throws -> APIRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try build()
                    let response = try await withAuth(request, status: \.status) { token in
                        try await transport.stream(for: urlRequest(request, token: token, stream: true))
                    }
                    if !(200..<300).contains(response.status) {
                        _ = try Self.check(status: response.status, body: try await response.collect())
                    }
                    var parser = SSEParser()
                    for try await chunk in response.body {
                        for frame in parser.feed(chunk) {
                            continuation.yield(try TurnEvent.decode(eventName: frame.event, data: Data(frame.data.utf8)))
                        }
                    }
                    for frame in parser.finish() {
                        continuation.yield(try TurnEvent.decode(eventName: frame.event, data: Data(frame.data.utf8)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ZoroError.wrap(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Conversations and approvals

    public func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> {
        try await send(.get("/v1/conversations", query: Self.pageQuery(cursor, limit)), as: Page<ConversationSummary>.self)
    }

    public func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> {
        try await send(
            .get("/v1/conversations/\(APIRequest.segment(conversationId))/messages", query: Self.pageQuery(cursor, limit)),
            as: Page<Message>.self)
    }

    public func deleteConversation(id: String) async throws {
        try await send(.delete("/v1/conversations/\(APIRequest.segment(id))"))
    }

    public func pendingApprovals() async throws -> [ApprovalRequest] {
        try await send(.get("/v1/approvals/pending"), as: ListOrPage<ApprovalRequest>.self).items
    }

    // MARK: - Security, capabilities, costs

    public func securityState() async throws -> SecurityState {
        try await send(.get("/v1/security/state"), as: SecurityState.self)
    }

    public func setPrivacyMode(_ update: PrivacyModeUpdate) async throws {
        try await send(.json(.put, "/v1/security/privacy-mode", body: update))
    }

    public func setKillSwitch(_ update: KillSwitchUpdate) async throws {
        try await send(.json(.post, "/v1/security/kill-switch", body: update))
    }

    public func setPermission(key: String, _ update: PermissionUpdate) async throws {
        try await send(.json(.put, "/v1/security/permissions/\(APIRequest.segment(key))", body: update))
    }

    public func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws {
        try await send(.json(.post, "/v1/security/devices/\(APIRequest.segment(id))/revoke", body: revoke))
    }

    public func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> {
        try await send(.get("/v1/security/audit", query: Self.pageQuery(cursor, limit)), as: Page<AuditRecord>.self)
    }

    public func capabilities() async throws -> [Capability] {
        try await send(.get("/v1/capabilities"), as: ListOrPage<Capability>.self).items
    }

    public func costSummary(groupBy: CostGroupBy) async throws -> CostSummary {
        try await send(.get("/v1/costs/summary", query: [URLQueryItem(name: "group_by", value: groupBy.rawValue)]), as: CostSummary.self)
    }

    public func modelRoutes() async throws -> [ModelRouteInfo] {
        try await send(.get("/v1/models/routes"), as: ListOrPage<ModelRouteInfo>.self).items
    }

    static func pageQuery(_ cursor: String?, _ limit: Int?) -> [URLQueryItem] {
        var q: [URLQueryItem] = []
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { q.append(URLQueryItem(name: "limit", value: String(limit))) }
        return q
    }
}
