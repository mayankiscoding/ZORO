import Foundation

/// Security-settings actions that carry a `SignedProof` (action name + signed subject, per the
/// docstrings in backend/app/schemas/security.py and data.py).
public enum SignedAction: Sendable, Equatable {
    case setPrivacyMode(PrivacyMode)
    case setKillSwitch(Bool)
    case setPermission(key: String, granted: Bool)
    case revokeDevice(id: String)
    case exportMemory(MemoryCategory?)
    case deleteMemoryCategory(MemoryCategory)

    public var action: String {
        switch self {
        case .setPrivacyMode: "set_privacy_mode"
        case .setKillSwitch: "set_kill_switch"
        case .setPermission: "set_permission"
        case .revokeDevice: "revoke_device"
        case .exportMemory: "export_memory"
        case .deleteMemoryCategory: "delete_memory_category"
        }
    }

    public var subject: String {
        switch self {
        case .setPrivacyMode(let mode): mode.rawValue
        case .setKillSwitch(let on): on ? "true" : "false"
        case .setPermission(let key, let granted): "\(key)=\(granted ? "true" : "false")"
        case .revokeDevice(let id): id
        case .exportMemory(let category): category?.rawValue ?? "all"
        case .deleteMemoryCategory(let category): category.rawValue
        }
    }
}

extension DeviceIdentityProviding {
    /// Signs a security-settings action with the approval (user-presence) key.
    public func signProof(_ action: SignedAction, key: ProofKey = .approval, at date: Date = Date()) async throws -> SignedProof {
        try await signProof(action: action.action, subject: action.subject, key: key, at: date)
    }
}
