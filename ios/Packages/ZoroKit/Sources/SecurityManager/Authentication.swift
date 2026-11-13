import Foundation
import LocalAuthentication
import ZoroCore

/// Owner authentication with LocalAuthentication (biometrics, falling back to the device passcode).
public struct BiometricAuthenticator: BiometricAuthenticating {
    public init() {}

    public func availability() async -> BiometricAvailability {
        let context = LAContext()
        var error: NSError?
        let can = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        let kind: BiometryKind
        switch context.biometryType {
        case .faceID: kind = .faceID
        case .touchID: kind = .touchID
        case .opticID: kind = .opticID
        default: kind = .none
        }
        return BiometricAvailability(kind: kind, canAuthenticate: can, reason: can ? nil : error?.localizedDescription)
    }

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        defer { context.invalidate() }
        try await Self.evaluate(context, reason: reason)
    }

    /// Evaluates owner authentication on `context`, mapping LocalAuthentication errors to `ZoroError`.
    static func evaluate(_ context: LAContext, reason: String) async throws {
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard ok else { throw ZoroError.authenticationFailed("not verified") }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback:
                throw ZoroError.userCancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                throw ZoroError.biometryUnavailable(error.localizedDescription)
            default:
                throw ZoroError.authenticationFailed(error.localizedDescription)
            }
        }
    }
}

/// Presents an approval to the owner. Returns true to approve, false to decline; throws
/// `ZoroError.userCancelled` when dismissed without a choice.
public protocol ApprovalPresenting: Sendable {
    @MainActor func present(_ request: ApprovalRequest) async throws -> Bool
    /// Presents again after the biometric step failed or was cancelled; `notice` says what happened.
    /// The default shows the request as on the first try.
    @MainActor func present(_ request: ApprovalRequest, notice: String?) async throws -> Bool
}

extension ApprovalPresenting {
    @MainActor public func present(_ request: ApprovalRequest, notice: String?) async throws -> Bool {
        try await present(request)
    }
}

/// `ApprovalRequest` → present → authenticate (biometric level, approve only) → signed `ApprovalDecision`.
/// An expired request is never shown or signed. When the biometric step is cancelled or fails, the
/// request goes back to the presenter for another try (the owner can still decline or dismiss); the
/// turn ends only after `maximumAttempts`. With `PresenceAuthenticating` biometrics and a
/// `PresenceSharingApprovalSigner` identity, one authenticated context covers both the check and the
/// approval key, so the owner is asked once.
public struct ApprovalCoordinator: ApprovalHandling {
    public static let maximumAttempts = 5
    public static let cancelledNotice = "Verification was cancelled. Approve again or decline."
    public static let failedNotice = "Verification didn't go through. Try again or decline."

    private let identity: any DeviceIdentityProviding
    private let biometrics: any BiometricAuthenticating
    private let presenter: any ApprovalPresenting
    private let now: @Sendable () -> Date

    public init(
        identity: any DeviceIdentityProviding, biometrics: any BiometricAuthenticating, presenter: any ApprovalPresenting,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.identity = identity
        self.biometrics = biometrics
        self.presenter = presenter
        self.now = now
    }

    public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        var notice: String?
        var attempt = 0
        while true {
            attempt += 1
            guard request.expiresAt > now() else { throw ZoroError.approvalExpired }
            let approved = notice == nil
                ? try await presenter.present(request)
                : try await presenter.present(request, notice: notice)
            guard request.expiresAt > now() else { throw ZoroError.approvalExpired }
            guard approved, request.level == .biometric else {
                return try await identity.signApproval(request, approved: approved, at: now())
            }
            do {
                return try await signWithPresence(request)
            } catch let error as ZoroError where error == .userCancelled || Self.isAuthenticationFailure(error) {
                guard attempt < Self.maximumAttempts else { throw error }
                notice = error == .userCancelled ? Self.cancelledNotice : Self.failedNotice
            }
        }
    }

    /// One prompt when both sides can share the context; otherwise authenticate, then sign.
    private func signWithPresence(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        if let presenceAuth = biometrics as? any PresenceAuthenticating, let signer = identity as? any PresenceSharingApprovalSigner {
            let presence = try await presenceAuth.authenticatePresence(reason: request.title)
            defer { presence.invalidate() }
            return try await signer.signApproval(request, approved: true, at: now(), presence: presence)
        }
        try await biometrics.authenticate(reason: request.title)
        return try await identity.signApproval(request, approved: true, at: now())
    }

    private static func isAuthenticationFailure(_ error: ZoroError) -> Bool {
        if case .authenticationFailed = error { return true }
        return false
    }
}

/// Session tokens: challenge → signed nonce → bearer token, cached until shortly before expiry.
/// Concurrent callers share one re-authentication.
public actor SessionManager: AccessTokenProviding {
    private let auth: any ZoroAuthAPI
    private let identity: any DeviceIdentityProviding
    private let now: @Sendable () -> Date
    private let leeway: TimeInterval
    private let log = ZoroLog("session")

    private var token: String?
    public private(set) var expiresAt: Date?
    private var refreshing: Task<String, Error>?

    public init(
        auth: any ZoroAuthAPI, identity: any DeviceIdentityProviding, now: @escaping @Sendable () -> Date = { Date() },
        refreshLeeway: TimeInterval = 30
    ) {
        self.auth = auth
        self.identity = identity
        self.now = now
        self.leeway = refreshLeeway
    }

    public var isAuthenticated: Bool {
        guard token != nil, let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now()) > leeway
    }

    public func validAccessToken() async throws -> String {
        if let token, isAuthenticated { return token }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.authenticate() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    public func invalidate(token stale: String) async {
        guard stale == token else { return }
        token = nil
        expiresAt = nil
    }

    public func signOut() {
        token = nil
        expiresAt = nil
    }

    private func authenticate() async throws -> String {
        guard let deviceId = await identity.deviceId() else { throw ZoroError.notPaired }
        let challenge = try await auth.challenge(ChallengeRequest(deviceId: deviceId))
        let signed = try await identity.signChallenge(nonce: challenge.nonce)
        let response = try await auth.token(signed)
        guard !response.accessToken.isEmpty, response.expiresIn > 0 else {
            throw ZoroError.invalidResponse("empty session token")
        }
        token = response.accessToken
        expiresAt = now().addingTimeInterval(TimeInterval(response.expiresIn))
        log.info("session established, expires in \(response.expiresIn)s")
        return response.accessToken
    }
}
