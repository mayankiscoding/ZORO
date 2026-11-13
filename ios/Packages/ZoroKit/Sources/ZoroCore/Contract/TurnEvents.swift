import Foundation

// Mirrors the TurnEvent union in backend/app/schemas/turns.py. Payload structs omit `type`; the
// `TurnEvent` enum reads and writes it.

public struct TurnStarted: Codable, Sendable, Equatable {
    public var turnId: String
    public var conversationId: String
    public var privacyMode: PrivacyMode
    public init(turnId: String, conversationId: String, privacyMode: PrivacyMode) {
        self.turnId = turnId
        self.conversationId = conversationId
        self.privacyMode = privacyMode
    }
    enum CodingKeys: String, CodingKey {
        case turnId = "turn_id"
        case conversationId = "conversation_id"
        case privacyMode = "privacy_mode"
    }
}

public enum RouteEngine: String, Codable, Sendable, CaseIterable {
    case deterministic
    case localModel = "local_model"
    case cloudModel = "cloud_model"
}

public struct RouteDecided: Codable, Sendable, Equatable {
    public var agents: [AgentId]
    public var reason: String
    public var dataClasses: [DataClass]
    public var engine: RouteEngine
    public init(agents: [AgentId], reason: String, dataClasses: [DataClass], engine: RouteEngine) {
        self.agents = agents
        self.reason = reason
        self.dataClasses = dataClasses
        self.engine = engine
    }
    enum CodingKeys: String, CodingKey {
        case agents, reason
        case dataClasses = "data_classes"
        case engine
    }
}

public struct AgentStarted: Codable, Sendable, Equatable {
    public var agent: AgentId
    public var task: String
    public init(agent: AgentId, task: String) {
        self.agent = agent
        self.task = task
    }
}

public struct AgentFinished: Codable, Sendable, Equatable {
    public var agent: AgentId
    public var ok: Bool
    public var durationMs: Int
    public init(agent: AgentId, ok: Bool, durationMs: Int) {
        self.agent = agent
        self.ok = ok
        self.durationMs = durationMs
    }
    enum CodingKeys: String, CodingKey {
        case agent, ok
        case durationMs = "duration_ms"
    }
}

public struct ToolStarted: Codable, Sendable, Equatable {
    public var callId: String
    public var tool: String
    public var agent: AgentId
    public var risk: RiskLevel
    public init(callId: String, tool: String, agent: AgentId, risk: RiskLevel) {
        self.callId = callId
        self.tool = tool
        self.agent = agent
        self.risk = risk
    }
    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case tool, agent, risk
    }
}

public struct ToolFinished: Codable, Sendable, Equatable {
    public var callId: String
    public var ok: Bool
    public var durationMs: Int
    public var summary: String?
    public init(callId: String, ok: Bool, durationMs: Int, summary: String? = nil) {
        self.callId = callId
        self.ok = ok
        self.durationMs = durationMs
        self.summary = summary
    }
    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case ok
        case durationMs = "duration_ms"
        case summary
    }
}

public struct TextDelta: Codable, Sendable, Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct CardEvent: Codable, Sendable, Equatable {
    public var card: UICard
    public init(card: UICard) { self.card = card }
}

public struct ApprovalRequired: Codable, Sendable, Equatable {
    public var approval: ApprovalRequest
    public init(approval: ApprovalRequest) { self.approval = approval }
}

public struct DeviceActionEvent: Codable, Sendable, Equatable {
    public var action: DeviceActionRequest
    public init(action: DeviceActionRequest) { self.action = action }
}

public enum SuspendReason: String, Codable, Sendable, CaseIterable {
    case approval
    case deviceAction = "device_action"
}

public struct TurnSuspended: Codable, Sendable, Equatable {
    public var turnId: String
    public var reason: SuspendReason
    public init(turnId: String, reason: SuspendReason) {
        self.turnId = turnId
        self.reason = reason
    }
    enum CodingKeys: String, CodingKey {
        case turnId = "turn_id"
        case reason
    }
}

public struct TurnCompleted: Codable, Sendable, Equatable {
    public var turnId: String
    public var messageId: String
    public var language: String
    public var dataClasses: [DataClass]
    /// False: the app must speak this reply with the on-device voice.
    public var cloudVoiceAllowed: Bool
    public var usage: UsageSummary
    public init(turnId: String, messageId: String, language: String, dataClasses: [DataClass], cloudVoiceAllowed: Bool, usage: UsageSummary) {
        self.turnId = turnId
        self.messageId = messageId
        self.language = language
        self.dataClasses = dataClasses
        self.cloudVoiceAllowed = cloudVoiceAllowed
        self.usage = usage
    }
    enum CodingKeys: String, CodingKey {
        case turnId = "turn_id"
        case messageId = "message_id"
        case language
        case dataClasses = "data_classes"
        case cloudVoiceAllowed = "cloud_voice_allowed"
        case usage
    }
}

public struct TurnError: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
    enum CodingKeys: String, CodingKey { case code, message, retryable }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        message = try c.decode(String.self, forKey: .message)
        retryable = try c.value(.retryable, default: false)
    }
}

/// One server-sent turn event, discriminated by its `type` field. Unknown types decode to `.unknown`
/// so an older app keeps working against a newer server.
public enum TurnEvent: Codable, Sendable, Equatable {
    case turnStarted(TurnStarted)
    case route(RouteDecided)
    case agentStarted(AgentStarted)
    case agentFinished(AgentFinished)
    case toolStarted(ToolStarted)
    case toolFinished(ToolFinished)
    case textDelta(TextDelta)
    case card(CardEvent)
    case approvalRequired(ApprovalRequired)
    case deviceAction(DeviceActionEvent)
    case turnSuspended(TurnSuspended)
    case turnCompleted(TurnCompleted)
    case error(TurnError)
    case unknown(type: String, payload: JSONValue)

    /// Wire `type` values of every known variant.
    public static let knownTypes: [String] = [
        "turn_started", "route", "agent_started", "agent_finished", "tool_started", "tool_finished", "text_delta",
        "card", "approval_required", "device_action", "turn_suspended", "turn_completed", "error",
    ]

    public var type: String {
        switch self {
        case .turnStarted: "turn_started"
        case .route: "route"
        case .agentStarted: "agent_started"
        case .agentFinished: "agent_finished"
        case .toolStarted: "tool_started"
        case .toolFinished: "tool_finished"
        case .textDelta: "text_delta"
        case .card: "card"
        case .approvalRequired: "approval_required"
        case .deviceAction: "device_action"
        case .turnSuspended: "turn_suspended"
        case .turnCompleted: "turn_completed"
        case .error: "error"
        case .unknown(let t, _): t
        }
    }

    /// True for events after which the server ends the stream.
    public var isTerminal: Bool {
        switch self {
        case .turnSuspended, .turnCompleted, .error: true
        default: false
        }
    }

    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        let type = try c.decode(String.self, forKey: .type)
        self = try Self.decode(type: type, from: decoder)
    }

    static func decode(type: String, from decoder: Decoder) throws -> TurnEvent {
        switch type {
        case "turn_started": return .turnStarted(try TurnStarted(from: decoder))
        case "route": return .route(try RouteDecided(from: decoder))
        case "agent_started": return .agentStarted(try AgentStarted(from: decoder))
        case "agent_finished": return .agentFinished(try AgentFinished(from: decoder))
        case "tool_started": return .toolStarted(try ToolStarted(from: decoder))
        case "tool_finished": return .toolFinished(try ToolFinished(from: decoder))
        case "text_delta": return .textDelta(try TextDelta(from: decoder))
        case "card": return .card(try CardEvent(from: decoder))
        case "approval_required": return .approvalRequired(try ApprovalRequired(from: decoder))
        case "device_action": return .deviceAction(try DeviceActionEvent(from: decoder))
        case "turn_suspended": return .turnSuspended(try TurnSuspended(from: decoder))
        case "turn_completed": return .turnCompleted(try TurnCompleted(from: decoder))
        case "error": return .error(try TurnError(from: decoder))
        default: return .unknown(type: type, payload: try JSONValue(from: decoder))
        }
    }

    /// Decodes an SSE frame. When the JSON lacks `type`, the SSE `event:` name supplies it.
    public static func decode(eventName: String?, data: Data) throws -> TurnEvent {
        let decoder = ZoroJSON.decoder()
        let raw = try decoder.decode(JSONValue.self, from: data)
        guard case .object(var object) = raw else {
            throw ZoroError.decoding("turn event is not a JSON object")
        }
        if object["type"]?.stringValue == nil {
            guard let name = eventName, !name.isEmpty, name != "message" else {
                throw ZoroError.decoding("turn event without a type")
            }
            object["type"] = .string(name)
            return try decoder.decode(TurnEvent.self, from: ZoroJSON.encoder().encode(JSONValue.object(object)))
        }
        return try decoder.decode(TurnEvent.self, from: data)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .unknown(let t, let payload):
            var o = payload.objectValue ?? [:]
            o["type"] = .string(t)
            try JSONValue.object(o).encode(to: encoder)
            return
        case .turnStarted(let e): try e.encode(to: encoder)
        case .route(let e): try e.encode(to: encoder)
        case .agentStarted(let e): try e.encode(to: encoder)
        case .agentFinished(let e): try e.encode(to: encoder)
        case .toolStarted(let e): try e.encode(to: encoder)
        case .toolFinished(let e): try e.encode(to: encoder)
        case .textDelta(let e): try e.encode(to: encoder)
        case .card(let e): try e.encode(to: encoder)
        case .approvalRequired(let e): try e.encode(to: encoder)
        case .deviceAction(let e): try e.encode(to: encoder)
        case .turnSuspended(let e): try e.encode(to: encoder)
        case .turnCompleted(let e): try e.encode(to: encoder)
        case .error(let e): try e.encode(to: encoder)
        }
        // Requested after the payload so both share one keyed container.
        var c = encoder.container(keyedBy: TypeKey.self)
        try c.encode(type, forKey: .type)
    }
}
