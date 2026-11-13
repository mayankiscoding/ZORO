import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
}

/// A typed request against the ZORO backend. `path` starts with `/v1/...`.
public struct APIRequest: Sendable, Equatable {
    public var method: HTTPMethod
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    /// False only for `/v1/auth/*` and `/healthz`.
    public var requiresAuth: Bool
    /// The body's media type; nil means JSON. Set for raw bodies such as `multipart/form-data` uploads.
    public var contentType: String?

    public init(
        method: HTTPMethod, path: String, query: [URLQueryItem] = [], body: Data? = nil, requiresAuth: Bool = true,
        contentType: String? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.requiresAuth = requiresAuth
        self.contentType = contentType
    }

    /// A raw body with its own media type (for example a multipart upload). Authenticated like any other request.
    public static func raw(_ method: HTTPMethod, _ path: String, body: Data, contentType: String) -> APIRequest {
        APIRequest(method: method, path: path, body: body, contentType: contentType)
    }

    public static func get(_ path: String, query: [URLQueryItem] = [], requiresAuth: Bool = true) -> APIRequest {
        APIRequest(method: .get, path: path, query: query.filter { $0.value != nil }, requiresAuth: requiresAuth)
    }

    public static func delete(_ path: String) -> APIRequest {
        APIRequest(method: .delete, path: path)
    }

    public static func json<Body: Encodable>(_ method: HTTPMethod, _ path: String, body: Body, requiresAuth: Bool = true) throws -> APIRequest {
        APIRequest(method: method, path: path, body: try ZoroJSON.encoder().encode(body), requiresAuth: requiresAuth)
    }

    /// Percent-encodes one path segment (ids, permission keys).
    public static func segment(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}

/// Pairing and session endpoints (no bearer token).
public protocol ZoroAuthAPI: Sendable {
    func pair(_ request: PairRequest) async throws -> PairResponse
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse
    func token(_ request: TokenRequest) async throws -> TokenResponse
}

/// Supplies bearer tokens; implemented by `SecurityManager.SessionManager`.
public protocol AccessTokenProviding: Sendable {
    /// A token valid for at least a few seconds, re-authenticating when needed.
    func validAccessToken() async throws -> String
    /// Called after the server answered 401 to `token`; the next call must fetch a fresh one.
    func invalidate(token: String) async
}

/// The backend API used by feature packages. Implemented by `AgentClient.ZoroAPIClient`.
public protocol ZoroAPI: ZoroAuthAPI {
    /// Sends any request and decodes a JSON response.
    func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response
    /// Sends a request whose response body is ignored.
    func send(_ request: APIRequest) async throws
    /// Sends a request and returns the raw body (exports, files).
    func sendRaw(_ request: APIRequest) async throws -> Data

    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error>
    func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error>
    func cancelTurn(id turnId: String) async throws

    func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary>
    func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message>
    func deleteConversation(id: String) async throws
    func pendingApprovals() async throws -> [ApprovalRequest]

    func securityState() async throws -> SecurityState
    func setPrivacyMode(_ update: PrivacyModeUpdate) async throws
    func setKillSwitch(_ update: KillSwitchUpdate) async throws
    func setPermission(key: String, _ update: PermissionUpdate) async throws
    func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws
    func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord>
    func capabilities() async throws -> [Capability]
    func costSummary(groupBy: CostGroupBy) async throws -> CostSummary
    func modelRoutes() async throws -> [ModelRouteInfo]
    /// `GET /v1/models/routes?privacy_mode=`: the routes as they would be under `privacyMode` (nil = server setting).
    func modelRoutes(privacyMode: PrivacyMode?) async throws -> [ModelRouteInfo]

    /// `GET /v1/voice/config`.
    func voiceConfig() async throws -> VoiceConfig
    /// `PUT /v1/voice/settings`; returns the settings the server stored.
    func updateVoiceSettings(_ settings: VoiceSettings) async throws -> VoiceSettings
    /// `POST /v1/voice/live-session` (empty JSON body): a short-lived grant for the realtime voice provider.
    func liveSession() async throws -> LiveSessionGrant
}

extension APIRequest {
    public static func modelRoutes(privacyMode: PrivacyMode?) -> APIRequest {
        .get("/v1/models/routes", query: [URLQueryItem(name: "privacy_mode", value: privacyMode?.rawValue)])
    }
    public static let voiceConfig = APIRequest.get("/v1/voice/config")
    public static func updateVoiceSettings(_ settings: VoiceSettings) throws -> APIRequest {
        try .json(.put, "/v1/voice/settings", body: settings)
    }
    public static let liveSession = APIRequest(method: .post, path: "/v1/voice/live-session", body: Data("{}".utf8))
}

/// Defaults built on `send`, so every `ZoroAPI` (including test fakes that answer `send`) gets them.
extension ZoroAPI {
    public func modelRoutes(privacyMode: PrivacyMode?) async throws -> [ModelRouteInfo] {
        try await send(.modelRoutes(privacyMode: privacyMode), as: ListOrPage<ModelRouteInfo>.self).items
    }
    public func voiceConfig() async throws -> VoiceConfig {
        try await send(.voiceConfig, as: VoiceConfig.self)
    }
    public func updateVoiceSettings(_ settings: VoiceSettings) async throws -> VoiceSettings {
        try await send(.updateVoiceSettings(settings), as: VoiceSettings.self)
    }
    public func liveSession() async throws -> LiveSessionGrant {
        try await send(.liveSession, as: LiveSessionGrant.self)
    }
}

/// Decodes either a bare JSON array or an object with `items` (tolerant list endpoints).
public struct ListOrPage<T: Decodable & Sendable>: Decodable, Sendable {
    public var items: [T]
    private enum K: String, CodingKey { case items }
    public init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([T].self) {
            items = array
        } else {
            items = try decoder.container(keyedBy: K.self).decode([T].self, forKey: .items)
        }
    }
}
