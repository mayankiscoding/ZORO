// Mirrors backend/app/core/types.py. Raw values are the wire contract: never change one here alone.

public enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case low, medium, high, critical

    public var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rank < rhs.rank }
}

public enum ApprovalLevel: String, Codable, Sendable, CaseIterable {
    case none, confirm, biometric
}

public enum PrivacyMode: String, Codable, Sendable, CaseIterable {
    case strictPrivate = "strict_private"
    case cloudIntelligence = "cloud_intelligence"
}

public enum DataClass: String, Codable, Sendable, CaseIterable {
    case `public`, personal, sensitive, financial, health, secret

    public var rank: Int {
        switch self {
        case .public: 0
        case .personal: 1
        case .sensitive: 2
        case .financial, .health: 3
        case .secret: 9
        }
    }
}

public enum Locality: String, Codable, Sendable, CaseIterable {
    case onDevice = "on_device"
    case local
    case privateNetwork = "private_network"
    case external
}

public enum DevicePlatform: String, Codable, Sendable, CaseIterable {
    case ios, macos
}

public enum AgentId: String, Codable, Sendable, CaseIterable {
    case supervisor, voice
    case personalAssistant = "personal_assistant"
    case memory, finance, investment, shopping
    case productResearch = "product_research"
    case vision, communication, fitness, music
    case deviceControl = "device_control"
    case document
    case browserResearch = "browser_research"
    case automation, security
}

public enum TaskClass: String, Codable, Sendable, CaseIterable {
    case realtimeVoice = "realtime_voice"
    case intentClassification = "intent_classification"
    case routineChat = "routine_chat"
    case complexReasoning = "complex_reasoning"
    case codingResearch = "coding_research"
    case financialInterpretation = "financial_interpretation"
    case summarization, embedding, tts
}

public enum IntegrationLevel: String, Codable, Sendable, CaseIterable {
    case fullyIntegrated = "fully_integrated"
    case officialApi = "official_api"
    case affiliateSearch = "affiliate_search"
    case deepLinkHandoff = "deep_link_handoff"
    case manualFallback = "manual_fallback"
    case unavailable
}

public enum CapabilityStatus: String, Codable, Sendable, CaseIterable {
    case workingNative = "working_native"
    case workingLocal = "working_local"
    case workingIntegration = "working_integration"
    case requiresCredentials = "requires_credentials"
    case requiresPartnership = "requires_partnership"
    case manualUserStep = "manual_user_step"
    case restrictedByIos = "restricted_by_ios"
    case unavailable
}

public enum MemoryCategory: String, Codable, Sendable, CaseIterable {
    case profile, episodic, financial, fitness, visual, knowledge
    case conversationState = "conversation_state"
}

public enum TurnStatus: String, Codable, Sendable, CaseIterable {
    case running, suspended, completed, failed, cancelled
}

/// Raw-value lists of every mirrored enum, keyed by the Python class name (used by drift tests).
public enum ContractEnums {
    public static let rawValues: [String: [String]] = [
        "RiskLevel": RiskLevel.allCases.map(\.rawValue),
        "ApprovalLevel": ApprovalLevel.allCases.map(\.rawValue),
        "PrivacyMode": PrivacyMode.allCases.map(\.rawValue),
        "DataClass": DataClass.allCases.map(\.rawValue),
        "Locality": Locality.allCases.map(\.rawValue),
        "DevicePlatform": DevicePlatform.allCases.map(\.rawValue),
        "AgentId": AgentId.allCases.map(\.rawValue),
        "TaskClass": TaskClass.allCases.map(\.rawValue),
        "IntegrationLevel": IntegrationLevel.allCases.map(\.rawValue),
        "CapabilityStatus": CapabilityStatus.allCases.map(\.rawValue),
        "MemoryCategory": MemoryCategory.allCases.map(\.rawValue),
        "TurnStatus": TurnStatus.allCases.map(\.rawValue),
    ]
}
