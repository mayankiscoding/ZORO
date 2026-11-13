import Foundation

/// Every service a feature package may use, injected through the SwiftUI environment.
/// `ZoroApp` wires concrete implementations; the default is `.unavailable`, whose members fail with
/// typed `ZoroError` values instead of crashing or inventing data.
public struct ZoroServices: Sendable {
    public var api: any ZoroAPI
    public var identity: any DeviceIdentityProviding
    public var keys: any KeyStoring
    public var biometrics: any BiometricAuthenticating
    public var approvals: any ApprovalHandling
    public var voice: any VoiceSessionControlling
    public var deviceActions: any DeviceActionExecuting
    public var photos: any PhotoSearching
    public var health: any HealthDataProviding
    public var music: any MusicControlling
    public var intents: any LocalIntentClassifying

    public init(
        api: any ZoroAPI, identity: any DeviceIdentityProviding, keys: any KeyStoring,
        biometrics: any BiometricAuthenticating, approvals: any ApprovalHandling, voice: any VoiceSessionControlling,
        deviceActions: any DeviceActionExecuting, photos: any PhotoSearching, health: any HealthDataProviding,
        music: any MusicControlling, intents: any LocalIntentClassifying
    ) {
        self.api = api
        self.identity = identity
        self.keys = keys
        self.biometrics = biometrics
        self.approvals = approvals
        self.voice = voice
        self.deviceActions = deviceActions
        self.photos = photos
        self.health = health
        self.music = music
        self.intents = intents
    }

    public static let unavailable: ZoroServices = {
        let u = UnavailableService()
        return ZoroServices(
            api: u, identity: u, keys: u, biometrics: u, approvals: u, voice: u, deviceActions: u, photos: u,
            health: u, music: u, intents: u)
    }()
}

/// The not-configured implementation of every service protocol.
public struct UnavailableService: Sendable {
    public init() {}
    private func fail<T>(_ capability: String) throws -> T {
        throw ZoroError.unavailable(capability: capability, reason: "not configured in this build")
    }
}

extension UnavailableService: ZoroAPI {
    public func pair(_ request: PairRequest) async throws -> PairResponse { throw ZoroError.notPaired }
    public func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { throw ZoroError.notPaired }
    public func token(_ request: TokenRequest) async throws -> TokenResponse { throw ZoroError.notPaired }
    public func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response { throw ZoroError.notPaired }
    public func send(_ request: APIRequest) async throws { throw ZoroError.notPaired }
    public func sendRaw(_ request: APIRequest) async throws -> Data { throw ZoroError.notPaired }
    public func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ZoroError.notPaired) }
    }
    public func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ZoroError.notPaired) }
    }
    public func cancelTurn(id turnId: String) async throws { throw ZoroError.notPaired }
    public func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> { throw ZoroError.notPaired }
    public func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> { throw ZoroError.notPaired }
    public func deleteConversation(id: String) async throws { throw ZoroError.notPaired }
    public func pendingApprovals() async throws -> [ApprovalRequest] { throw ZoroError.notPaired }
    public func securityState() async throws -> SecurityState { throw ZoroError.notPaired }
    public func setPrivacyMode(_ update: PrivacyModeUpdate) async throws { throw ZoroError.notPaired }
    public func setKillSwitch(_ update: KillSwitchUpdate) async throws { throw ZoroError.notPaired }
    public func setPermission(key: String, _ update: PermissionUpdate) async throws { throw ZoroError.notPaired }
    public func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws { throw ZoroError.notPaired }
    public func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> { throw ZoroError.notPaired }
    public func capabilities() async throws -> [Capability] { throw ZoroError.notPaired }
    public func costSummary(groupBy: CostGroupBy) async throws -> CostSummary { throw ZoroError.notPaired }
    public func modelRoutes() async throws -> [ModelRouteInfo] { throw ZoroError.notPaired }
}

extension UnavailableService: DeviceIdentityProviding {
    public func deviceId() async -> String? { nil }
    public func pairRequest(pairingCode: String, deviceName: String, platform: DevicePlatform, capabilities: [String], appVersion: String?) async throws -> PairRequest { try fail("Device identity") }
    public func completePairing(_ response: PairResponse) async throws { try fail("Device identity") as Void }
    public func signChallenge(nonce: String) async throws -> TokenRequest { throw ZoroError.notPaired }
    public func signApproval(_ request: ApprovalRequest, approved: Bool, at date: Date) async throws -> ApprovalDecision { throw ZoroError.notPaired }
    public func signProof(action: String, subject: String, key: ProofKey, at date: Date) async throws -> SignedProof { throw ZoroError.notPaired }
    public func unpair() async throws {}
}

extension UnavailableService: KeyStoring {
    public var protection: KeyProtection { .memory }
    public func ensureSigningKeys() async throws { try fail("Device keys") as Void }
    public func publicKey(for purpose: DeviceKeyPurpose) async throws -> Data { try fail("Device keys") }
    public func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String) async throws -> Data { try fail("Device keys") }
    public func symmetricKey(named name: String) async throws -> Data { try fail("Device keys") }
    public func deleteAllKeys() async throws {}
}

extension UnavailableService: BiometricAuthenticating, ApprovalHandling {
    public func availability() async -> BiometricAvailability {
        BiometricAvailability(kind: .none, canAuthenticate: false, reason: "not configured in this build")
    }
    public func authenticate(reason: String) async throws { throw ZoroError.biometryUnavailable("not configured in this build") }
    public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision { try fail("Approvals") }
}

extension UnavailableService: VoiceSessionControlling {
    public func start(_ options: VoiceSessionOptions) async throws { try fail("Voice") as Void }
    public func stop() async {}
    public func finishListening() async {}
    public func interrupt() async {}
    public func currentState() async -> VoiceSessionState { .idle }
    public func stateUpdates() -> AsyncStream<VoiceSessionState> { AsyncStream { $0.finish() } }
    public func levelUpdates() -> AsyncStream<Float> { AsyncStream { $0.finish() } }
    public func transcriptUpdates() -> AsyncStream<VoiceTranscript> { AsyncStream { $0.finish() } }
}

extension UnavailableService: DeviceActionExecuting {
    public var supportedTools: [String] { [] }
    public func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
        .failure(request, code: .unsupported, message: "Device actions are not configured in this build.", capabilityStatus: .unavailable)
    }
}

extension UnavailableService: PhotoSearching {
    public func authorizationStatus() async -> MediaAuthorization { .restricted }
    public func requestAuthorization() async -> MediaAuthorization { .restricted }
    public func indexStatus() async -> PhotoIndexStatus { PhotoIndexStatus(state: .notStarted) }
    public func search(_ query: PhotoQuery) async throws -> PhotoSearchResult { try fail("Photo search") }
    public func rebuildIndex() async throws { try fail("Photo search") as Void }
    public func deleteIndex() async throws {}
}

extension UnavailableService: HealthDataProviding {
    public func authorization() async -> HealthAuthorization { .unavailable }
    public func requestAuthorization() async throws { try fail("Health") as Void }
    public func dailySummary(for day: Date) async throws -> HealthDailySummary { try fail("Health") }
    public func weeklySummary(weekContaining day: Date) async throws -> HealthWeeklySummary { try fail("Health") }
    public func workouts(in interval: DateInterval, limit: Int) async throws -> [WorkoutSummary] { try fail("Health") }
    public func dataFreshness() async throws -> [HealthDataFreshness] { try fail("Health") }
}

extension UnavailableService: MusicControlling {
    public func authorization() async -> MediaAuthorization { .restricted }
    public func search(_ query: MusicSearchQuery) async throws -> [MusicItem] { try fail("Music") }
    public func play(_ item: MusicItem?) async throws { try fail("Music") as Void }
    public func pause() async throws { try fail("Music") as Void }
    public func skipToNext() async throws { try fail("Music") as Void }
    public func skipToPrevious() async throws { try fail("Music") as Void }
    public func queue(_ item: MusicItem, at position: QueuePosition) async throws { try fail("Music") as Void }
    public func outputDevices() async throws -> [MusicOutputDevice] { try fail("Music") }
    public func transfer(toDeviceId deviceId: String) async throws { try fail("Music") as Void }
    public func nowPlaying() async throws -> NowPlaying? { try fail("Music") }
}

extension UnavailableService: LocalIntentClassifying {
    public func classify(_ text: String, languageHint: String?) async -> LocalIntent? { nil }
}

#if canImport(SwiftUI)
import SwiftUI

private struct ZoroServicesKey: EnvironmentKey {
    static let defaultValue: ZoroServices = .unavailable
}

extension EnvironmentValues {
    /// `@Environment(\.zoroServices) private var services`
    public var zoroServices: ZoroServices {
        get { self[ZoroServicesKey.self] }
        set { self[ZoroServicesKey.self] = newValue }
    }
}

extension View {
    public func zoroServices(_ services: ZoroServices) -> some View {
        environment(\.zoroServices, services)
    }
}
#endif
