import Foundation
import LocalAuthentication
import Security
import ZoroCore

// One user-presence prompt per biometric approval: the owner authenticates once with an `LAContext`,
// and the approval key is then used with that same, already evaluated context.
//
// UNVERIFIED-ON-HOST: that the Secure Enclave key (`authenticationContext:`) and a user-presence Keychain
// item (`kSecUseAuthenticationContext`) accept an evaluated context without asking again is Apple's
// documented behaviour, but it cannot be exercised on this machine: tests never touch the Keychain,
// the Secure Enclave or biometrics. Everything that depends on it is in this file and in the
// `presence:` overloads of the key stores; the coordinator logic around it is tested with fakes.

/// An owner-authenticated LocalAuthentication context. Used only for the one signature it was made for.
public final class PresenceContext: @unchecked Sendable {
    /// Reads and writes happen on the approval path only, one at a time.
    public let context: LAContext
    public init(context: LAContext = LAContext()) { self.context = context }

    /// Ends the context so it cannot authorise anything else.
    public func invalidate() { context.invalidate() }
}

/// Authenticates the owner and hands back the evaluated context.
public protocol PresenceAuthenticating: Sendable {
    /// Throws `ZoroError.userCancelled`, `.authenticationFailed` or `.biometryUnavailable`.
    func authenticatePresence(reason: String) async throws -> PresenceContext
}

/// A key store that can use the approval key with an already evaluated context.
public protocol PresenceSharingKeyStore: KeyStoring {
    func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String, presence: PresenceContext) async throws -> Data
}

/// Signs an approval with the approval key under an already evaluated context.
public protocol PresenceSharingApprovalSigner: Sendable {
    func signApproval(_ request: ApprovalRequest, approved: Bool, at date: Date, presence: PresenceContext) async throws -> ApprovalDecision
}

extension BiometricAuthenticator: PresenceAuthenticating {
    public func authenticatePresence(reason: String) async throws -> PresenceContext {
        let presence = PresenceContext()
        try await Self.evaluate(presence.context, reason: reason)
        return presence
    }
}

extension SecureEnclaveKeyStore: PresenceSharingKeyStore {
    public func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String, presence: PresenceContext) async throws -> Data {
        try signLoaded(message, purpose: purpose, context: presence.context)
    }
}

extension SoftwareKeyStore: PresenceSharingKeyStore {
    public func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String, presence: PresenceContext) async throws -> Data {
        let raw: Data?
        if let keychain = items as? KeychainStore {
            raw = try keychain.read(account(purpose), context: presence.context)
        } else {
            raw = try items.read(account(purpose))
        }
        return try Self.sign(message, raw: raw, purpose: purpose)
    }
}

extension KeychainStore {
    /// Reads an item with an already evaluated context (no second prompt for a user-presence item).
    public func read(_ account: String, context: LAContext) throws -> Data? {
        try read(account, extra: [kSecUseAuthenticationContext as String: context])
    }
}

extension DeviceIdentity: PresenceSharingApprovalSigner {
    public func signApproval(_ request: ApprovalRequest, approved: Bool, at date: Date, presence: PresenceContext) async throws -> ApprovalDecision {
        guard let shared = keys as? any PresenceSharingKeyStore else {
            return try await signApproval(request, approved: approved, at: date)
        }
        return try await signApproval(request, approved: approved, at: date) { message, purpose in
            try await shared.sign(message, with: purpose, reason: request.title, presence: presence)
        }
    }
}
