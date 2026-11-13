import ConversationManager
import Foundation
import SecurityManager
import ZoroCore
@testable import ZoroAppUI

/// A thread-safe box for recording calls from Sendable fakes.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

/// A server fake: scripted security state and turn events; everything else is unavailable.
struct FakeAPI: ZoroAPI {
    var security: Result<SecurityState, ZoroError> = .success(FakeAPI.state(.strictPrivate))
    var approvals: [ApprovalRequest] = []
    var turnEvents: [TurnEvent] = []
    var turnError: ZoroError?
    /// Server-side conversations for `messages(conversationId:…)`; a missing id is unavailable.
    var remoteMessages: [String: [Message]] = [:]
    let turns = Recorder<TurnRequest>()

    static func state(_ mode: PrivacyMode, killSwitch: Bool = false) -> SecurityState {
        SecurityState(
            privacyMode: mode, killSwitch: killSwitch, strictAllowPublicExternal: false, biometricForHighRisk: false,
            sessionExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), permissions: [], devices: [])
    }

    private var u: UnavailableService { UnavailableService() }

    func pair(_ request: PairRequest) async throws -> PairResponse { try await u.pair(request) }
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { try await u.challenge(request) }
    func token(_ request: TokenRequest) async throws -> TokenResponse { try await u.token(request) }
    func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response { try await u.send(request, as: type) }
    func send(_ request: APIRequest) async throws { try await u.send(request) }
    func sendRaw(_ request: APIRequest) async throws -> Data { try await u.sendRaw(request) }
    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        turns.append(request)
        let events = turnEvents
        let error = turnError
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish(throwing: error)
        }
    }
    func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> { u.resumeTurn(id: turnId, request) }
    func cancelTurn(id turnId: String) async throws {}
    func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> { try await u.conversations(cursor: cursor, limit: limit) }
    func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> {
        guard let items = remoteMessages[conversationId] else { return try await u.messages(conversationId: conversationId, cursor: cursor, limit: limit) }
        return Page(items: items)
    }
    func deleteConversation(id: String) async throws {}
    func pendingApprovals() async throws -> [ApprovalRequest] { approvals }
    func securityState() async throws -> SecurityState { try security.get() }
    func setPrivacyMode(_ update: PrivacyModeUpdate) async throws {}
    func setKillSwitch(_ update: KillSwitchUpdate) async throws {}
    func setPermission(key: String, _ update: PermissionUpdate) async throws {}
    func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws {}
    func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> { try await u.auditLog(cursor: cursor, limit: limit) }
    func capabilities() async throws -> [Capability] { [] }
    func costSummary(groupBy: CostGroupBy) async throws -> CostSummary { try await u.costSummary(groupBy: groupBy) }
    func modelRoutes() async throws -> [ModelRouteInfo] { [] }
}

/// Records voice commands; state and level streams are driven by the test.
final class FakeVoice: VoiceSessionControlling, @unchecked Sendable {
    enum Call: Equatable, Sendable { case start(VoiceSessionOptions), stop, finishListening, interrupt }
    let calls = Recorder<Call>()
    var startError: ZoroError?
    var state: VoiceSessionState = .idle

    func start(_ options: VoiceSessionOptions) async throws {
        calls.append(.start(options))
        if let startError { throw startError }
    }
    func stop() async { calls.append(.stop) }
    func finishListening() async { calls.append(.finishListening) }
    func interrupt() async { calls.append(.interrupt) }
    func currentState() async -> VoiceSessionState { state }
    func stateUpdates() -> AsyncStream<VoiceSessionState> { AsyncStream { $0.finish() } }
    func levelUpdates() -> AsyncStream<Float> { AsyncStream { $0.finish() } }
    /// Transcripts the test pushes with `say(_:)`.
    let (transcripts, transcriptContinuation) = AsyncStream.makeStream(of: VoiceTranscript.self)
    func transcriptUpdates() -> AsyncStream<VoiceTranscript> { transcripts }
    func say(_ t: VoiceTranscript) { transcriptContinuation.yield(t) }
}

final class FakePermissions: PermissionPriming, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [AppPermission: PermissionStatus]
    private let answers: [AppPermission: PermissionStatus]
    let requests = Recorder<AppPermission>()

    init(_ statuses: [AppPermission: PermissionStatus], answers: [AppPermission: PermissionStatus] = [:]) {
        self.statuses = statuses
        self.answers = answers
    }

    func status(of permission: AppPermission) async -> PermissionStatus {
        lock.withLock { statuses[permission] ?? .notDetermined }
    }

    func request(_ permission: AppPermission) async -> PermissionStatus {
        requests.append(permission)
        let answer = answers[permission] ?? .denied
        lock.withLock { statuses[permission] = answer }
        return answer
    }

    static let allGranted = FakePermissions([.microphone: .granted, .speechRecognition: .granted, .notifications: .granted])
}

struct NoApprovals: ApprovalHandling {
    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision { throw ZoroError.userCancelled }
}

struct NoDeviceActions: DeviceActionExecuting {
    var supportedTools: [String] { [] }
    func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
        .failure(request, code: .unsupported)
    }
}

struct FixedContext: HomeContextProviding {
    var context = SuggestionContext()
    func suggestionContext() async -> SuggestionContext { context }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { [self] in self.now } }
}

struct FakeBiometrics: BiometricAuthenticating {
    var kind: BiometryKind = .faceID
    var result: ZoroError?
    let calls = Recorder<String>()
    func availability() async -> BiometricAvailability { BiometricAvailability(kind: kind, canAuthenticate: true) }
    func authenticate(reason: String) async throws {
        calls.append(reason)
        if let result { throw result }
    }
}

@MainActor
func makeHome(
    api: FakeAPI = FakeAPI(), voice: FakeVoice = FakeVoice(), permissions: FakePermissions = .allGranted,
    context: SuggestionContext = SuggestionContext()
) -> HomeViewModel {
    let manager = ConversationManager(
        api: api, approvals: NoApprovals(), deviceActions: NoDeviceActions(), clientContext: ClientContext(platform: .ios))
    return HomeViewModel(conversation: manager, voice: voice, api: api, context: FixedContext(context: context), permissions: permissions)
}

func approvalRequest(level: ApprovalLevel = .confirm, risk: RiskLevel = .high, expiresIn: TimeInterval = 120, now: Date) -> ApprovalRequest {
    ApprovalRequest(
        approvalId: "apr_1", turnId: "turn_1", tool: "communication.send_message", agent: .communication, risk: risk, level: level,
        title: "Send a message", summary: "Send this message on WhatsApp.",
        details: [LabelValue(label: "To", value: "Contact"), LabelValue(label: "Message", value: "Text")],
        actionDigest: "digest", expiresAt: now.addingTimeInterval(expiresIn))
}

/// Polls until `condition` holds (or gives up after ~1 s of yields).
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() {
        await Task.yield()
    }
}
