import Foundation

// Mirrors backend/app/schemas/turns.py (requests, approvals, device actions). Events: TurnEvents.swift.

public enum InputModality: String, Codable, Sendable, CaseIterable {
    case text, voice
}

public struct TurnInput: Codable, Sendable, Equatable {
    public var text: String
    public var modality: InputModality
    public var languageHint: String?

    public init(text: String, modality: InputModality = .text, languageHint: String? = nil) {
        self.text = text
        self.modality = modality
        self.languageHint = languageHint
    }

    enum CodingKeys: String, CodingKey {
        case text, modality
        case languageHint = "language_hint"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        modality = try c.value(.modality, default: .text)
        languageHint = try c.decodeIfPresent(String.self, forKey: .languageHint)
    }
}

public struct ClientContext: Codable, Sendable, Equatable {
    public var platform: DevicePlatform
    public var locale: String
    public var timezone: String
    public var locationRef: String?
    public var capabilities: [String]
    public var appState: JSONObject

    public init(
        platform: DevicePlatform, locale: String = "en-IN", timezone: String = "Asia/Kolkata",
        locationRef: String? = nil, capabilities: [String] = [], appState: JSONObject = [:]
    ) {
        self.platform = platform
        self.locale = locale
        self.timezone = timezone
        self.locationRef = locationRef
        self.capabilities = capabilities
        self.appState = appState
    }

    enum CodingKeys: String, CodingKey {
        case platform, locale, timezone
        case locationRef = "location_ref"
        case capabilities
        case appState = "app_state"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(DevicePlatform.self, forKey: .platform)
        locale = try c.value(.locale, default: "en-IN")
        timezone = try c.value(.timezone, default: "Asia/Kolkata")
        locationRef = try c.decodeIfPresent(String.self, forKey: .locationRef)
        capabilities = try c.value(.capabilities, default: [])
        appState = try c.value(.appState, default: [:])
    }
}

public struct TurnRequest: Codable, Sendable, Equatable {
    public var conversationId: String?
    public var input: TurnInput
    public var client: ClientContext
    /// May only be stricter than the server setting.
    public var privacyMode: PrivacyMode?

    public init(conversationId: String? = nil, input: TurnInput, client: ClientContext, privacyMode: PrivacyMode? = nil) {
        self.conversationId = conversationId
        self.input = input
        self.client = client
        self.privacyMode = privacyMode
    }

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case input, client
        case privacyMode = "privacy_mode"
    }
}

public struct ApprovalRequest: Codable, Sendable, Equatable, Identifiable {
    public var approvalId: String
    public var turnId: String?
    public var tool: String
    public var agent: AgentId?
    public var risk: RiskLevel
    public var level: ApprovalLevel
    public var title: String
    public var summary: String
    public var details: [LabelValue]
    public var actionDigest: String
    public var expiresAt: Date
    /// The request came from a turn that read external content (web, email, files). Missing in JSON = false.
    public var tainted: Bool

    public var id: String { approvalId }

    public init(
        approvalId: String, turnId: String? = nil, tool: String, agent: AgentId? = nil, risk: RiskLevel,
        level: ApprovalLevel, title: String, summary: String, details: [LabelValue] = [], actionDigest: String,
        expiresAt: Date, tainted: Bool = false
    ) {
        self.approvalId = approvalId
        self.turnId = turnId
        self.tool = tool
        self.agent = agent
        self.risk = risk
        self.level = level
        self.title = title
        self.summary = summary
        self.details = details
        self.actionDigest = actionDigest
        self.expiresAt = expiresAt
        self.tainted = tainted
    }

    enum CodingKeys: String, CodingKey {
        case approvalId = "approval_id"
        case turnId = "turn_id"
        case tool, agent, risk, level, title, summary, details
        case actionDigest = "action_digest"
        case expiresAt = "expires_at"
        case tainted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvalId = try c.decode(String.self, forKey: .approvalId)
        turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
        tool = try c.decode(String.self, forKey: .tool)
        agent = try c.decodeIfPresent(AgentId.self, forKey: .agent)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        level = try c.decode(ApprovalLevel.self, forKey: .level)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        details = try c.value(.details, default: [])
        actionDigest = try c.decode(String.self, forKey: .actionDigest)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        tainted = try c.value(.tainted, default: false)
    }
}

/// `signatureB64` signs `zoro-approval-v1|{approval_id}|{action_digest}|{1 or 0}|{signed_at}`.
public struct ApprovalDecision: Codable, Sendable, Equatable {
    public var approvalId: String
    public var approved: Bool
    public var actionDigest: String
    public var deviceId: String
    public var signedAt: Date
    public var signatureB64: String

    public init(approvalId: String, approved: Bool, actionDigest: String, deviceId: String, signedAt: Date, signatureB64: String) {
        self.approvalId = approvalId
        self.approved = approved
        self.actionDigest = actionDigest
        self.deviceId = deviceId
        self.signedAt = signedAt
        self.signatureB64 = signatureB64
    }

    enum CodingKeys: String, CodingKey {
        case approvalId = "approval_id"
        case approved
        case actionDigest = "action_digest"
        case deviceId = "device_id"
        case signedAt = "signed_at"
        case signatureB64 = "signature_b64"
    }
}

public struct DeviceActionRequest: Codable, Sendable, Equatable, Identifiable {
    public var actionId: String
    public var turnId: String?
    public var targetDeviceId: String?
    public var tool: String
    public var args: JSONObject
    public var risk: RiskLevel
    public var requiresUserConfirmation: Bool
    public var expiresAt: Date

    public var id: String { actionId }

    public init(
        actionId: String, turnId: String? = nil, targetDeviceId: String? = nil, tool: String, args: JSONObject = [:],
        risk: RiskLevel, requiresUserConfirmation: Bool = false, expiresAt: Date
    ) {
        self.actionId = actionId
        self.turnId = turnId
        self.targetDeviceId = targetDeviceId
        self.tool = tool
        self.args = args
        self.risk = risk
        self.requiresUserConfirmation = requiresUserConfirmation
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case actionId = "action_id"
        case turnId = "turn_id"
        case targetDeviceId = "target_device_id"
        case tool, args, risk
        case requiresUserConfirmation = "requires_user_confirmation"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actionId = try c.decode(String.self, forKey: .actionId)
        turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
        targetDeviceId = try c.decodeIfPresent(String.self, forKey: .targetDeviceId)
        tool = try c.decode(String.self, forKey: .tool)
        args = try c.value(.args, default: [:])
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        requiresUserConfirmation = try c.value(.requiresUserConfirmation, default: false)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
    }
}

/// Stable device-action error codes (`DeviceActionResult.errorCode`).
public enum DeviceActionErrorCode: String, Codable, Sendable, CaseIterable {
    case permissionDenied = "permission_denied"
    case unsupported
    case userCancelled = "user_cancelled"
    /// The arguments are missing, malformed or outside the contract.
    case invalidArguments = "invalid_arguments"
    case failed
    case expired
}

public struct DeviceActionResult: Codable, Sendable, Equatable {
    public var actionId: String
    public var ok: Bool
    public var result: JSONObject?
    public var errorCode: String?
    public var errorMessage: String?
    public var capabilityStatus: CapabilityStatus?
    public var executedAt: Date

    public init(
        actionId: String, ok: Bool, result: JSONObject? = nil, errorCode: String? = nil, errorMessage: String? = nil,
        capabilityStatus: CapabilityStatus? = nil, executedAt: Date
    ) {
        self.actionId = actionId
        self.ok = ok
        self.result = result
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.capabilityStatus = capabilityStatus
        self.executedAt = executedAt
    }

    /// A failed result with a stable error code.
    public static func failure(
        _ request: DeviceActionRequest, code: DeviceActionErrorCode, message: String? = nil,
        capabilityStatus: CapabilityStatus? = nil, at date: Date = Date()
    ) -> DeviceActionResult {
        DeviceActionResult(
            actionId: request.actionId, ok: false, errorCode: code.rawValue, errorMessage: message,
            capabilityStatus: capabilityStatus, executedAt: date)
    }

    enum CodingKeys: String, CodingKey {
        case actionId = "action_id"
        case ok, result
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case capabilityStatus = "capability_status"
        case executedAt = "executed_at"
    }
}

public struct ResumeRequest: Codable, Sendable, Equatable {
    public var approval: ApprovalDecision?
    public var deviceResult: DeviceActionResult?

    public init(approval: ApprovalDecision? = nil, deviceResult: DeviceActionResult? = nil) {
        self.approval = approval
        self.deviceResult = deviceResult
    }

    enum CodingKeys: String, CodingKey {
        case approval
        case deviceResult = "device_result"
    }
}

public struct UsageSummary: Codable, Sendable, Equatable {
    public var modelCalls: Int
    public var toolCalls: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUsd: Decimal
    public var durationMs: Int

    public init(modelCalls: Int = 0, toolCalls: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0, costUsd: Decimal = 0, durationMs: Int = 0) {
        self.modelCalls = modelCalls
        self.toolCalls = toolCalls
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUsd = costUsd
        self.durationMs = durationMs
    }

    enum CodingKeys: String, CodingKey {
        case modelCalls = "model_calls"
        case toolCalls = "tool_calls"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUsd = "cost_usd"
        case durationMs = "duration_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelCalls = try c.value(.modelCalls, default: 0)
        toolCalls = try c.value(.toolCalls, default: 0)
        inputTokens = try c.value(.inputTokens, default: 0)
        outputTokens = try c.value(.outputTokens, default: 0)
        costUsd = try c.decodeDecimalStringIfPresent(forKey: .costUsd) ?? 0
        durationMs = try c.value(.durationMs, default: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelCalls, forKey: .modelCalls)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encodeDecimalString(costUsd, forKey: .costUsd)
        try c.encode(durationMs, forKey: .durationMs)
    }
}
