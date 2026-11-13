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

/// A fake `ZoroAPI`. Generic `send` calls are answered by closures keyed "METHOD /path"; the typed
/// shortcuts have their own closures. Everything not set fails with `.transport("no handler")`.
/// Records every request so tests can assert that nothing was sent.
final class FakeAPI: ZoroAPI, @unchecked Sendable {
    typealias Handler = @Sendable (APIRequest) async throws -> Any

    let requests = Locked<[APIRequest]>([])
    let calls = Locked<[String]>([])
    let handlers = Locked<[String: Handler]>([:])

    var securityStateHandler: (@Sendable () async throws -> SecurityState)?
    var setPrivacyModeHandler: (@Sendable (PrivacyModeUpdate) async throws -> Void)?
    var setKillSwitchHandler: (@Sendable (KillSwitchUpdate) async throws -> Void)?
    var setPermissionHandler: (@Sendable (String, PermissionUpdate) async throws -> Void)?
    var revokeDeviceHandler: (@Sendable (String, DeviceRevoke) async throws -> Void)?
    var auditHandler: (@Sendable (String?, Int?) async throws -> Page<AuditRecord>)?
    var capabilitiesHandler: (@Sendable () async throws -> [Capability])?
    var costHandler: (@Sendable (CostGroupBy) async throws -> CostSummary)?
    var routesHandler: (@Sendable () async throws -> [ModelRouteInfo])?
    var conversationsHandler: (@Sendable (String?, Int?) async throws -> Page<ConversationSummary>)?
    var messagesHandler: (@Sendable (String, String?, Int?) async throws -> Page<Message>)?
    var deleteConversationHandler: (@Sendable (String) async throws -> Void)?
    var pendingApprovalsHandler: (@Sendable () async throws -> [ApprovalRequest])?

    func on(_ key: String, _ handler: @escaping Handler) {
        handlers.withLock { $0[key] = handler }
    }

    var sentRequests: [APIRequest] { requests.get }
    func sent(_ method: HTTPMethod, _ path: String) -> [APIRequest] {
        requests.get.filter { $0.method == method && $0.path == path }
    }

    private func record(_ call: String) { calls.withLock { $0.append(call) } }
    private func missing() -> ZoroError { .transport("no handler") }

    // Generic
    func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        requests.withLock { $0.append(request) }
        guard let handler = handlers.get["\(request.method.rawValue) \(request.path)"] else { throw missing() }
        let value = try await handler(request)
        guard let typed = value as? Response else { throw ZoroError.decoding("fake returned \(Swift.type(of: value)) for \(Response.self)") }
        return typed
    }
    func send(_ request: APIRequest) async throws {
        requests.withLock { $0.append(request) }
        guard let handler = handlers.get["\(request.method.rawValue) \(request.path)"] else { throw missing() }
        _ = try await handler(request)
    }
    func sendRaw(_ request: APIRequest) async throws -> Data {
        requests.withLock { $0.append(request) }
        guard let handler = handlers.get["\(request.method.rawValue) \(request.path)"] else { throw missing() }
        guard let data = try await handler(request) as? Data else { throw ZoroError.decoding("fake did not return Data") }
        return data
    }

    // Auth (unused)
    func pair(_ request: PairRequest) async throws -> PairResponse { throw missing() }
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { throw missing() }
    func token(_ request: TokenRequest) async throws -> TokenResponse { throw missing() }

    // Turns (unused)
    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> { AsyncThrowingStream { $0.finish(throwing: ZoroError.transport("no handler")) } }
    func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> { AsyncThrowingStream { $0.finish(throwing: ZoroError.transport("no handler")) } }
    func cancelTurn(id turnId: String) async throws {}

    func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> {
        record("conversations:\(cursor ?? "-")")
        guard let h = conversationsHandler else { throw missing() }
        return try await h(cursor, limit)
    }
    func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> {
        record("messages:\(conversationId):\(cursor ?? "-")")
        guard let h = messagesHandler else { throw missing() }
        return try await h(conversationId, cursor, limit)
    }
    func deleteConversation(id: String) async throws {
        record("deleteConversation:\(id)")
        guard let h = deleteConversationHandler else { throw missing() }
        try await h(id)
    }
    func pendingApprovals() async throws -> [ApprovalRequest] {
        record("pendingApprovals")
        guard let h = pendingApprovalsHandler else { throw missing() }
        return try await h()
    }
    func securityState() async throws -> SecurityState {
        record("securityState")
        guard let h = securityStateHandler else { throw missing() }
        return try await h()
    }
    func setPrivacyMode(_ update: PrivacyModeUpdate) async throws {
        record("setPrivacyMode:\(update.mode.rawValue)")
        guard let h = setPrivacyModeHandler else { throw missing() }
        try await h(update)
    }
    func setKillSwitch(_ update: KillSwitchUpdate) async throws {
        record("setKillSwitch:\(update.enabled)")
        guard let h = setKillSwitchHandler else { throw missing() }
        try await h(update)
    }
    func setPermission(key: String, _ update: PermissionUpdate) async throws {
        record("setPermission:\(key)=\(update.granted)")
        guard let h = setPermissionHandler else { throw missing() }
        try await h(key, update)
    }
    func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws {
        record("revokeDevice:\(id)")
        guard let h = revokeDeviceHandler else { throw missing() }
        try await h(id, revoke)
    }
    func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> {
        record("auditLog:\(cursor ?? "-")")
        guard let h = auditHandler else { throw missing() }
        return try await h(cursor, limit)
    }
    func capabilities() async throws -> [Capability] {
        record("capabilities")
        guard let h = capabilitiesHandler else { throw missing() }
        return try await h()
    }
    func costSummary(groupBy: CostGroupBy) async throws -> CostSummary {
        record("costSummary:\(groupBy.rawValue)")
        guard let h = costHandler else { throw missing() }
        return try await h(groupBy)
    }
    func modelRoutes() async throws -> [ModelRouteInfo] {
        record("modelRoutes")
        guard let h = routesHandler else { throw missing() }
        return try await h()
    }
}

/// Signs nothing real. Records what was asked to be signed.
final class FakeIdentity: DeviceIdentityProviding, @unchecked Sendable {
    var id: String? = "dev_me"
    var proofError: Error?
    var unpairError: Error?
    let signed = Locked<[SignedAction]>([])
    let unpaired = Locked<Int>(0)

    func deviceId() async -> String? { id }
    func pairRequest(pairingCode: String, deviceName: String, platform: DevicePlatform, capabilities: [String], appVersion: String?) async throws -> PairRequest { throw ZoroError.busy }
    func completePairing(_ response: PairResponse) async throws {}
    func signChallenge(nonce: String) async throws -> TokenRequest { throw ZoroError.busy }
    func signApproval(_ request: ApprovalRequest, approved: Bool, at date: Date) async throws -> ApprovalDecision { throw ZoroError.busy }
    func signProof(action: String, subject: String, key: ProofKey, at date: Date) async throws -> SignedProof {
        if let proofError { throw proofError }
        // Record the structured action through its wire form.
        signed.withLock { $0.append(SignedActionRecord.decode(action: action, subject: subject)) }
        return SignedProof(deviceId: id ?? "none", signedAt: date, signatureB64: "c2ln", key: key)
    }
    func unpair() async throws {
        if let unpairError { throw unpairError }
        unpaired.withLock { $0 += 1 }
        id = nil
    }
}

enum SignedActionRecord {
    static func decode(action: String, subject: String) -> SignedAction {
        switch action {
        case "set_privacy_mode": return .setPrivacyMode(PrivacyMode(rawValue: subject) ?? .strictPrivate)
        case "set_kill_switch": return .setKillSwitch(subject == "true")
        case "set_permission":
            let parts = subject.split(separator: "=", maxSplits: 1).map(String.init)
            return .setPermission(key: parts[0], granted: parts.last == "true")
        case "revoke_device": return .revokeDevice(id: subject)
        case "export_memory": return .exportMemory(MemoryCategory(rawValue: subject))
        default: return .deleteMemoryCategory(MemoryCategory(rawValue: subject) ?? .profile)
        }
    }
}

struct FakeKeys: KeyStoring {
    var protection: KeyProtection = .secureEnclave
    func ensureSigningKeys() async throws {}
    func publicKey(for purpose: DeviceKeyPurpose) async throws -> Data { Data() }
    func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String) async throws -> Data { Data() }
    func symmetricKey(named name: String) async throws -> Data { Data() }
    func deleteAllKeys() async throws {}
}

struct FakeBiometrics: BiometricAuthenticating {
    var kind: BiometryKind = .faceID
    var can = true
    func availability() async -> BiometricAvailability { BiometricAvailability(kind: kind, canAuthenticate: can) }
    func authenticate(reason: String) async throws {}
}

final class FakeExecutor: DeviceActionExecuting, @unchecked Sendable {
    var tools: [String]
    var result: (@Sendable (DeviceActionRequest) -> DeviceActionResult)?
    let executed = Locked<[DeviceActionRequest]>([])

    init(tools: [String] = []) { self.tools = tools }

    var supportedTools: [String] { get async { tools } }
    func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
        executed.withLock { $0.append(request) }
        if let result { return result(request) }
        return DeviceActionResult(actionId: request.actionId, ok: true, executedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}

// MARK: - Sample values (tests only)

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func memory(_ id: String, _ text: String = "Likes chai", category: MemoryCategory = .profile, status: MemoryStatus = .active, editable: Bool = true) -> MemoryRecord {
    MemoryRecord(id: id, category: category, text: text, source: "chat", confidence: 0.9, sensitivity: .personal, status: status, userEditable: editable, createdAt: t0)
}

func memorySettings(enabled: Bool = true) -> MemorySettings {
    MemorySettings(categories: MemoryCategory.allCases.map { MemoryCategorySetting(category: $0, enabled: enabled) }, conversationRetentionDays: 30)
}

func device(_ id: String, _ name: String = "iPhone", platform: DevicePlatform = .ios, online: Bool = true, revoked: Bool = false) -> DeviceInfo {
    DeviceInfo(deviceId: id, name: name, platform: platform, capabilities: [], lastSeenAt: t0, online: online, revoked: revoked)
}

func securityState(
    mode: PrivacyMode = .strictPrivate, kill: Bool = false, permissions: [PermissionGrant]? = nil, devices: [DeviceInfo]? = nil
) -> SecurityState {
    SecurityState(
        privacyMode: mode, killSwitch: kill, strictAllowPublicExternal: false, biometricForHighRisk: false,
        sessionExpiresAt: t0.addingTimeInterval(900),
        permissions: permissions ?? [
            PermissionGrant(key: "cloud.sensitive", title: "Send sensitive data to cloud models", granted: false),
            PermissionGrant(key: "finance.read", title: "Read finance data", granted: true),
        ],
        devices: devices ?? [device("dev_me", "My iPhone"), device("dev_mac", "My Mac", platform: .macos, online: false)])
}

func audit(_ id: String, decision: AuditDecision = .allowed) -> AuditRecord {
    AuditRecord(id: id, ts: t0, actor: "dev_me", action: "tool.run", tool: "finance.spending_summary", risk: .low, decision: decision, prevHash: "p\(id)", hash: "h\(id)")
}

func conversation(_ id: String, _ title: String = "Groceries") -> ConversationSummary {
    ConversationSummary(id: id, title: title, updatedAt: t0, lastMessagePreview: "Added milk", messageCount: 2)
}

func message(_ id: String, at offset: TimeInterval = 0, role: MessageRole = .user) -> Message {
    Message(id: id, role: role, text: "text \(id)", createdAt: t0.addingTimeInterval(offset))
}

struct Boom: Error {}
