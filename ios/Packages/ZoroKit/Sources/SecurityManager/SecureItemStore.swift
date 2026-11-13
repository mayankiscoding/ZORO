import Foundation
import Security
import ZoroCore

/// How a stored secret may be read.
public enum SecureItemAccess: Sendable {
    /// Readable after the first unlock since boot, never synced or migrated.
    case afterFirstUnlockThisDeviceOnly
    /// Readable only while the device is unlocked, never synced or migrated.
    case whenUnlockedThisDeviceOnly
    /// Each read requires Face ID / Touch ID / passcode.
    case userPresence
}

/// A small secret store: the Keychain in the app, memory in tests.
public protocol SecureItemStoring: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String, access: SecureItemAccess) throws
    func delete(_ account: String) throws
}

/// Generic-password items in the data-protection Keychain.
public struct KeychainStore: SecureItemStoring {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "app.zoro.secure", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read(_ account: String) throws -> Data? {
        try read(account, extra: [:])
    }

    func read(_ account: String, extra: [String: Any]) throws -> Data? {
        var q = baseQuery(account)
        q.merge(extra) { _, new in new }
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled: throw ZoroError.userCancelled
        case errSecAuthFailed: throw ZoroError.authenticationFailed("keychain")
        default: throw ZoroError.keyUnavailable("keychain read failed (\(status))")
        }
    }

    public func write(_ data: Data, account: String, access: SecureItemAccess) throws {
        try delete(account)
        var q = baseQuery(account)
        q[kSecValueData as String] = data
        switch access {
        case .afterFirstUnlockThisDeviceOnly:
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedThisDeviceOnly:
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .userPresence:
            var error: Unmanaged<CFError>?
            guard let ac = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error)
            else {
                throw ZoroError.keyUnavailable("access control: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            }
            q[kSecAttrAccessControl as String] = ac
        }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw ZoroError.keyUnavailable("keychain write failed (\(status))") }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ZoroError.keyUnavailable("keychain delete failed (\(status))")
        }
    }
}

/// Test and preview store. Records the requested access level so tests can assert it.
public final class InMemorySecureItemStore: SecureItemStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (Data, SecureItemAccess)] = [:]

    public init() {}

    public func read(_ account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[account]?.0
    }

    public func write(_ data: Data, account: String, access: SecureItemAccess) throws {
        lock.lock()
        defer { lock.unlock() }
        items[account] = (data, access)
    }

    public func delete(_ account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[account] = nil
    }

    public func access(of account: String) -> SecureItemAccess? {
        lock.lock()
        defer { lock.unlock() }
        return items[account]?.1
    }

    public var accounts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items.keys.sorted()
    }
}
