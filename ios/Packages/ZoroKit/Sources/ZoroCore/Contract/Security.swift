import Foundation

// Mirrors backend/app/schemas/security.py.

public struct PermissionGrant: Codable, Sendable, Equatable {
    public var key: String
    public var title: String
    public var granted: Bool
    public var updatedAt: Date?

    public init(key: String, title: String, granted: Bool, updatedAt: Date? = nil) {
        self.key = key
        self.title = title
        self.granted = granted
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case key, title, granted
        case updatedAt = "updated_at"
    }
}

public struct SecurityState: Codable, Sendable, Equatable {
    public var privacyMode: PrivacyMode
    public var killSwitch: Bool
    public var strictAllowPublicExternal: Bool
    public var biometricForHighRisk: Bool
    public var sessionExpiresAt: Date
    public var permissions: [PermissionGrant]
    public var devices: [DeviceInfo]

    public init(
        privacyMode: PrivacyMode, killSwitch: Bool, strictAllowPublicExternal: Bool, biometricForHighRisk: Bool,
        sessionExpiresAt: Date, permissions: [PermissionGrant], devices: [DeviceInfo]
    ) {
        self.privacyMode = privacyMode
        self.killSwitch = killSwitch
        self.strictAllowPublicExternal = strictAllowPublicExternal
        self.biometricForHighRisk = biometricForHighRisk
        self.sessionExpiresAt = sessionExpiresAt
        self.permissions = permissions
        self.devices = devices
    }

    enum CodingKeys: String, CodingKey {
        case privacyMode = "privacy_mode"
        case killSwitch = "kill_switch"
        case strictAllowPublicExternal = "strict_allow_public_external"
        case biometricForHighRisk = "biometric_for_high_risk"
        case sessionExpiresAt = "session_expires_at"
        case permissions, devices
    }
}

/// Signed subject: the mode value. Action name: `set_privacy_mode`.
public struct PrivacyModeUpdate: Codable, Sendable, Equatable {
    public var mode: PrivacyMode
    public var proof: SignedProof
    public init(mode: PrivacyMode, proof: SignedProof) {
        self.mode = mode
        self.proof = proof
    }
}

/// Signed subject: `true` or `false`. Action name: `set_kill_switch`.
public struct KillSwitchUpdate: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var proof: SignedProof
    public init(enabled: Bool, proof: SignedProof) {
        self.enabled = enabled
        self.proof = proof
    }
}

/// Signed subject: `{key}={true|false}`. Action name: `set_permission`.
public struct PermissionUpdate: Codable, Sendable, Equatable {
    public var granted: Bool
    public var proof: SignedProof
    public init(granted: Bool, proof: SignedProof) {
        self.granted = granted
        self.proof = proof
    }
}

/// Signed subject: the device id being revoked. Action name: `revoke_device`.
public struct DeviceRevoke: Codable, Sendable, Equatable {
    public var proof: SignedProof
    public init(proof: SignedProof) { self.proof = proof }
}

public enum AuditDecision: String, Codable, Sendable, CaseIterable {
    case allowed, approved, denied, blocked, failed, info
}

public struct AuditRecord: Codable, Sendable, Equatable {
    public var id: String
    public var ts: Date
    public var actor: String
    public var action: String
    public var tool: String?
    public var risk: RiskLevel?
    public var decision: AuditDecision
    public var dataClasses: [DataClass]
    public var detail: String
    public var prevHash: String
    public var hash: String

    public init(
        id: String, ts: Date, actor: String, action: String, tool: String? = nil, risk: RiskLevel? = nil,
        decision: AuditDecision, dataClasses: [DataClass] = [], detail: String = "", prevHash: String, hash: String
    ) {
        self.id = id
        self.ts = ts
        self.actor = actor
        self.action = action
        self.tool = tool
        self.risk = risk
        self.decision = decision
        self.dataClasses = dataClasses
        self.detail = detail
        self.prevHash = prevHash
        self.hash = hash
    }

    enum CodingKeys: String, CodingKey {
        case id, ts, actor, action, tool, risk, decision
        case dataClasses = "data_classes"
        case detail
        case prevHash = "prev_hash"
        case hash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ts = try c.decode(Date.self, forKey: .ts)
        actor = try c.decode(String.self, forKey: .actor)
        action = try c.decode(String.self, forKey: .action)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        risk = try c.decodeIfPresent(RiskLevel.self, forKey: .risk)
        decision = try c.decode(AuditDecision.self, forKey: .decision)
        dataClasses = try c.value(.dataClasses, default: [])
        detail = try c.value(.detail, default: "")
        prevHash = try c.decode(String.self, forKey: .prevHash)
        hash = try c.decode(String.self, forKey: .hash)
    }
}

public struct Capability: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var domain: String
    public var status: CapabilityStatus
    public var integrationLevel: IntegrationLevel?
    public var requires: [String]
    public var note: String

    public init(
        id: String, title: String, domain: String, status: CapabilityStatus,
        integrationLevel: IntegrationLevel? = nil, requires: [String] = [], note: String = ""
    ) {
        self.id = id
        self.title = title
        self.domain = domain
        self.status = status
        self.integrationLevel = integrationLevel
        self.requires = requires
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, title, domain, status
        case integrationLevel = "integration_level"
        case requires, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        domain = try c.decode(String.self, forKey: .domain)
        status = try c.decode(CapabilityStatus.self, forKey: .status)
        integrationLevel = try c.decodeIfPresent(IntegrationLevel.self, forKey: .integrationLevel)
        requires = try c.value(.requires, default: [])
        note = try c.value(.note, default: "")
    }
}

public struct CostRow: Codable, Sendable, Equatable {
    public var key: String
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var audioSeconds: Double
    public var avgLatencyMs: Double
    public var errorRate: Double
    public var costUsd: Decimal

    public init(
        key: String, requests: Int, inputTokens: Int, outputTokens: Int, audioSeconds: Double = 0,
        avgLatencyMs: Double = 0, errorRate: Double = 0, costUsd: Decimal = 0
    ) {
        self.key = key
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.audioSeconds = audioSeconds
        self.avgLatencyMs = avgLatencyMs
        self.errorRate = errorRate
        self.costUsd = costUsd
    }

    enum CodingKeys: String, CodingKey {
        case key, requests
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case audioSeconds = "audio_seconds"
        case avgLatencyMs = "avg_latency_ms"
        case errorRate = "error_rate"
        case costUsd = "cost_usd"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        requests = try c.decode(Int.self, forKey: .requests)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        audioSeconds = try c.value(.audioSeconds, default: 0)
        avgLatencyMs = try c.value(.avgLatencyMs, default: 0)
        errorRate = try c.value(.errorRate, default: 0)
        costUsd = try c.decodeDecimalStringIfPresent(forKey: .costUsd) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(requests, forKey: .requests)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(audioSeconds, forKey: .audioSeconds)
        try c.encode(avgLatencyMs, forKey: .avgLatencyMs)
        try c.encode(errorRate, forKey: .errorRate)
        try c.encodeDecimalString(costUsd, forKey: .costUsd)
    }
}

public enum CostGroupBy: String, Codable, Sendable, CaseIterable {
    case provider, model, task, agent, day
}

public struct CostSummary: Codable, Sendable, Equatable {
    public var groupBy: CostGroupBy
    public var totalCostUsd: Decimal
    public var items: [CostRow]

    public init(groupBy: CostGroupBy, totalCostUsd: Decimal, items: [CostRow]) {
        self.groupBy = groupBy
        self.totalCostUsd = totalCostUsd
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case groupBy = "group_by"
        case totalCostUsd = "total_cost_usd"
        case items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupBy = try c.decode(CostGroupBy.self, forKey: .groupBy)
        totalCostUsd = try c.decodeDecimalString(forKey: .totalCostUsd)
        items = try c.decode([CostRow].self, forKey: .items)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groupBy, forKey: .groupBy)
        try c.encodeDecimalString(totalCostUsd, forKey: .totalCostUsd)
        try c.encode(items, forKey: .items)
    }
}

public struct ModelRouteInfo: Codable, Sendable, Equatable {
    public var task: TaskClass
    public var models: [String]
    public var activeModel: String?
    public var locality: Locality?
    public var reason: String

    public init(task: TaskClass, models: [String], activeModel: String?, locality: Locality?, reason: String = "") {
        self.task = task
        self.models = models
        self.activeModel = activeModel
        self.locality = locality
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case task, models
        case activeModel = "active_model"
        case locality, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = try c.decode(TaskClass.self, forKey: .task)
        models = try c.decode([String].self, forKey: .models)
        activeModel = try c.decodeIfPresent(String.self, forKey: .activeModel)
        locality = try c.decodeIfPresent(Locality.self, forKey: .locality)
        reason = try c.value(.reason, default: "")
    }
}
