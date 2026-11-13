import Foundation

/// The two signing keys a device registers (design spec section 4).
public enum DeviceKeyPurpose: String, Sendable, CaseIterable {
    /// Signs session challenges and `confirm`-level approvals.
    case auth
    /// Use requires user presence (Face ID / Touch ID / passcode); signs `biometric` approvals and proofs.
    case approval
}

/// Where a key lives; shown honestly in Security and privacy.
public enum KeyProtection: String, Sendable {
    case secureEnclave = "secure_enclave"
    case keychainSoftware = "keychain_software"
    case memory
}

/// Holds the device's P-256 signing keys and symmetric data keys.
public protocol KeyStoring: Sendable {
    var protection: KeyProtection { get }
    /// Creates both signing keys when absent.
    func ensureSigningKeys() async throws
    /// X9.63 uncompressed public key (65 bytes).
    func publicKey(for purpose: DeviceKeyPurpose) async throws -> Data
    /// ECDSA P-256 over SHA-256 of `message`; DER signature. `reason` is shown by a user-presence prompt.
    func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String) async throws -> Data
    /// A 32-byte symmetric key for local encryption, created on first use.
    func symmetricKey(named name: String) async throws -> Data
    /// Removes every key (unpairing).
    func deleteAllKeys() async throws
}

/// The paired device identity: pairing payload and every signed string the server verifies.
public protocol DeviceIdentityProviding: Sendable {
    func deviceId() async -> String?
    func pairRequest(
        pairingCode: String, deviceName: String, platform: DevicePlatform, capabilities: [String], appVersion: String?
    ) async throws -> PairRequest
    func completePairing(_ response: PairResponse) async throws
    /// Signs `zoro-auth-v1|{device_id}|{nonce}` with the auth key.
    func signChallenge(nonce: String) async throws -> TokenRequest
    /// Signs `zoro-approval-v1|…` with the key matching `request.level`.
    func signApproval(_ request: ApprovalRequest, approved: Bool, at date: Date) async throws -> ApprovalDecision
    /// Signs `zoro-action-v1|{action}|{subject}|{signed_at}`.
    func signProof(action: String, subject: String, key: ProofKey, at date: Date) async throws -> SignedProof
    func unpair() async throws
}

public enum BiometryKind: String, Sendable {
    case none, touchID, faceID, opticID
}

public struct BiometricAvailability: Sendable, Equatable {
    public var kind: BiometryKind
    /// Biometrics or the device passcode can authenticate the owner.
    public var canAuthenticate: Bool
    public var reason: String?
    public init(kind: BiometryKind, canAuthenticate: Bool, reason: String? = nil) {
        self.kind = kind
        self.canAuthenticate = canAuthenticate
        self.reason = reason
    }
}

public protocol BiometricAuthenticating: Sendable {
    func availability() async -> BiometricAvailability
    /// Throws `ZoroError.userCancelled` or `.authenticationFailed`.
    func authenticate(reason: String) async throws
}

/// Turns a server `ApprovalRequest` into a signed decision (shows UI, authenticates when needed).
/// Throwing `ZoroError.userCancelled` means the owner dismissed without deciding.
public protocol ApprovalHandling: Sendable {
    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision
}
