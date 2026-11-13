import CryptoKit
import Foundation
import LocalAuthentication
import Security
import ZoroCore

func account(_ purpose: DeviceKeyPurpose) -> String { "signing.\(purpose.rawValue)" }
private func symmetricAccount(_ name: String) -> String { "symmetric.\(name)" }

private func loadOrCreateSymmetricKey(_ name: String, in items: any SecureItemStoring) throws -> Data {
    if let existing = try items.read(symmetricAccount(name)), existing.count == 32 { return existing }
    let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    try items.write(key, account: symmetricAccount(name), access: .afterFirstUnlockThisDeviceOnly)
    return key
}

/// Picks the Secure Enclave when present, otherwise the Keychain software fallback.
public enum DeviceKeyStores {
    public static func makeDefault(items: any SecureItemStoring = KeychainStore(service: "app.zoro.keys")) -> any KeyStoring {
        SecureEnclave.isAvailable ? SecureEnclaveKeyStore(items: items) : SoftwareKeyStore(items: items)
    }
}

/// P-256 keys generated inside the Secure Enclave. The auth key needs only an unlocked device; the
/// approval key's every use requires user presence (Face ID / Touch ID / passcode). Only the
/// enclave-wrapped key blobs are stored in the Keychain; the private keys never leave the enclave.
public struct SecureEnclaveKeyStore: KeyStoring {
    public let items: any SecureItemStoring
    public var protection: KeyProtection { .secureEnclave }

    public init(items: any SecureItemStoring = KeychainStore(service: "app.zoro.keys")) {
        self.items = items
    }

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    private func accessControl(_ purpose: DeviceKeyPurpose) throws -> SecAccessControl {
        let flags: SecAccessControlCreateFlags = purpose == .approval ? [.privateKeyUsage, .userPresence] : [.privateKeyUsage]
        var error: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw ZoroError.keyUnavailable("access control: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return ac
    }

    public func ensureSigningKeys() async throws {
        guard SecureEnclave.isAvailable else { throw ZoroError.keyUnavailable("no Secure Enclave on this device") }
        for purpose in DeviceKeyPurpose.allCases where try items.read(account(purpose)) == nil {
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: try accessControl(purpose))
                try items.write(key.dataRepresentation, account: account(purpose), access: .afterFirstUnlockThisDeviceOnly)
            } catch let e as ZoroError {
                throw e
            } catch {
                throw ZoroError.keyUnavailable("Secure Enclave key creation failed")
            }
        }
    }

    private func load(_ purpose: DeviceKeyPurpose, reason: String?) throws -> SecureEnclave.P256.Signing.PrivateKey {
        let context = LAContext()
        if let reason { context.localizedReason = reason }
        return try load(purpose, context: context)
    }

    private func load(_ purpose: DeviceKeyPurpose, context: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard let blob = try items.read(account(purpose)) else { throw ZoroError.keyUnavailable("\(purpose.rawValue) key missing") }
        do {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        } catch {
            throw ZoroError.keyUnavailable("\(purpose.rawValue) key cannot be opened")
        }
    }

    public func publicKey(for purpose: DeviceKeyPurpose) async throws -> Data {
        try load(purpose, reason: nil).publicKey.x963Representation
    }

    public func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String) async throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        return try signLoaded(message, purpose: purpose, context: context)
    }

    /// Signs with the key opened under `context` (a fresh one prompts; an evaluated one does not).
    func signLoaded(_ message: Data, purpose: DeviceKeyPurpose, context: LAContext) throws -> Data {
        let key = try load(purpose, context: context)
        do {
            return try key.signature(for: message).derRepresentation
        } catch let e as LAError where [.userCancel, .appCancel, .systemCancel].contains(e.code) {
            throw ZoroError.userCancelled
        } catch {
            throw ZoroError.signingFailed("\(purpose.rawValue) key")
        }
    }

    public func symmetricKey(named name: String) async throws -> Data {
        try loadOrCreateSymmetricKey(name, in: items)
    }

    public func deleteAllKeys() async throws {
        for purpose in DeviceKeyPurpose.allCases { try items.delete(account(purpose)) }
    }
}

/// Fallback when there is no Secure Enclave: CryptoKit software keys kept in the Keychain. The approval
/// key's item is stored with user-presence access control, so reading it to sign prompts the owner.
public struct SoftwareKeyStore: KeyStoring {
    public let items: any SecureItemStoring
    public var protection: KeyProtection { .keychainSoftware }

    public init(items: any SecureItemStoring) {
        self.items = items
    }

    public func ensureSigningKeys() async throws {
        for purpose in DeviceKeyPurpose.allCases where try items.read(account(purpose)) == nil {
            let key = P256.Signing.PrivateKey()
            try items.write(
                key.rawRepresentation, account: account(purpose),
                access: purpose == .approval ? .userPresence : .whenUnlockedThisDeviceOnly)
            // The public half is stored separately so reading it never needs user presence.
            try items.write(key.publicKey.x963Representation, account: account(purpose) + ".pub", access: .afterFirstUnlockThisDeviceOnly)
        }
    }

    public func publicKey(for purpose: DeviceKeyPurpose) async throws -> Data {
        guard let pub = try items.read(account(purpose) + ".pub") else { throw ZoroError.keyUnavailable("\(purpose.rawValue) key missing") }
        return pub
    }

    public func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String) async throws -> Data {
        try Self.sign(message, raw: try items.read(account(purpose)), purpose: purpose)
    }

    static func sign(_ message: Data, raw: Data?, purpose: DeviceKeyPurpose) throws -> Data {
        guard let raw else { throw ZoroError.keyUnavailable("\(purpose.rawValue) key missing") }
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: raw).signature(for: message).derRepresentation
        } catch {
            throw ZoroError.signingFailed("\(purpose.rawValue) key")
        }
    }

    public func symmetricKey(named name: String) async throws -> Data {
        try loadOrCreateSymmetricKey(name, in: items)
    }

    public func deleteAllKeys() async throws {
        for purpose in DeviceKeyPurpose.allCases {
            try items.delete(account(purpose))
            try items.delete(account(purpose) + ".pub")
        }
    }
}

/// Keys in memory only, for tests and previews. `approvalGate` simulates the user-presence prompt
/// of the approval key (throw `ZoroError.userCancelled` to simulate a cancel).
public actor InMemoryKeyStore: PresenceSharingKeyStore {
    public nonisolated var protection: KeyProtection { .memory }
    private var signing: [DeviceKeyPurpose: P256.Signing.PrivateKey] = [:]
    private var symmetric: [String: Data] = [:]
    private let approvalGate: (@Sendable (String) async throws -> Void)?
    public private(set) var signatures: [(DeviceKeyPurpose, String)] = []

    public init(approvalGate: (@Sendable (String) async throws -> Void)? = nil) {
        self.approvalGate = approvalGate
    }

    public func ensureSigningKeys() async throws {
        for purpose in DeviceKeyPurpose.allCases where signing[purpose] == nil {
            signing[purpose] = P256.Signing.PrivateKey()
        }
    }

    public func publicKey(for purpose: DeviceKeyPurpose) async throws -> Data {
        guard let key = signing[purpose] else { throw ZoroError.keyUnavailable("\(purpose.rawValue) key missing") }
        return key.publicKey.x963Representation
    }

    public func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String) async throws -> Data {
        guard let key = signing[purpose] else { throw ZoroError.keyUnavailable("\(purpose.rawValue) key missing") }
        if purpose == .approval, let approvalGate { try await approvalGate(reason) }
        signatures.append((purpose, String(decoding: message, as: UTF8.self)))
        return try key.signature(for: message).derRepresentation
    }

    /// The owner already authenticated for this signature, so `approvalGate` is not asked again.
    public func sign(_ message: Data, with purpose: DeviceKeyPurpose, reason: String, presence: PresenceContext) async throws -> Data {
        guard let key = signing[purpose] else { throw ZoroError.keyUnavailable("\(purpose.rawValue) key missing") }
        signatures.append((purpose, String(decoding: message, as: UTF8.self)))
        return try key.signature(for: message).derRepresentation
    }

    public func symmetricKey(named name: String) async throws -> Data {
        if let existing = symmetric[name] { return existing }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        symmetric[name] = key
        return key
    }

    public func deleteAllKeys() async throws {
        signing.removeAll()
        symmetric.removeAll()
    }
}
