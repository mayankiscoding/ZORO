import Foundation

// Mirrors backend/app/schemas/data.py (memory, conversations, voice).

public enum MemoryStatus: String, Codable, Sendable, CaseIterable {
    case active
    case pendingReview = "pending_review"
    case archived
}

public struct MemoryRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var category: MemoryCategory
    public var text: String
    public var source: String
    public var confidence: Double
    public var sensitivity: DataClass
    public var status: MemoryStatus
    public var userEditable: Bool
    public var createdAt: Date
    public var lastVerifiedAt: Date?
    public var expiresAt: Date?

    public init(
        id: String, category: MemoryCategory, text: String, source: String, confidence: Double, sensitivity: DataClass,
        status: MemoryStatus = .active, userEditable: Bool = true, createdAt: Date, lastVerifiedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.text = text
        self.source = source
        self.confidence = confidence
        self.sensitivity = sensitivity
        self.status = status
        self.userEditable = userEditable
        self.createdAt = createdAt
        self.lastVerifiedAt = lastVerifiedAt
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case id, category, text, source, confidence, sensitivity, status
        case userEditable = "user_editable"
        case createdAt = "created_at"
        case lastVerifiedAt = "last_verified_at"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(MemoryCategory.self, forKey: .category)
        text = try c.decode(String.self, forKey: .text)
        source = try c.decode(String.self, forKey: .source)
        confidence = try c.decode(Double.self, forKey: .confidence)
        sensitivity = try c.decode(DataClass.self, forKey: .sensitivity)
        status = try c.value(.status, default: .active)
        userEditable = try c.value(.userEditable, default: true)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastVerifiedAt = try c.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
    }
}

public struct MemoryCreate: Codable, Sendable, Equatable {
    public var category: MemoryCategory
    public var text: String
    public var sensitivity: DataClass
    public init(category: MemoryCategory, text: String, sensitivity: DataClass = .personal) {
        self.category = category
        self.text = text
        self.sensitivity = sensitivity
    }
    enum CodingKeys: String, CodingKey { case category, text, sensitivity }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try c.decode(MemoryCategory.self, forKey: .category)
        text = try c.decode(String.self, forKey: .text)
        sensitivity = try c.value(.sensitivity, default: .personal)
    }
}

/// Only non-nil fields are sent.
public struct MemoryPatch: Codable, Sendable, Equatable {
    public var text: String?
    public var status: MemoryStatus?
    /// True stamps `last_verified_at`.
    public var verified: Bool?
    public init(text: String? = nil, status: MemoryStatus? = nil, verified: Bool? = nil) {
        self.text = text
        self.status = status
        self.verified = verified
    }
}

public struct MemoryCategorySetting: Codable, Sendable, Equatable {
    public var category: MemoryCategory
    public var enabled: Bool
    /// nil = keep until deleted.
    public var retentionDays: Int?
    public init(category: MemoryCategory, enabled: Bool, retentionDays: Int? = nil) {
        self.category = category
        self.enabled = enabled
        self.retentionDays = retentionDays
    }
    enum CodingKeys: String, CodingKey {
        case category, enabled
        case retentionDays = "retention_days"
    }
}

public struct MemorySettings: Codable, Sendable, Equatable {
    public var categories: [MemoryCategorySetting]
    public var conversationRetentionDays: Int
    public init(categories: [MemoryCategorySetting], conversationRetentionDays: Int) {
        self.categories = categories
        self.conversationRetentionDays = conversationRetentionDays
    }
    enum CodingKeys: String, CodingKey {
        case categories
        case conversationRetentionDays = "conversation_retention_days"
    }
}

/// Signed subject: `all` or a category value. Action name: `export_memory`.
public struct MemoryExportRequest: Codable, Sendable, Equatable {
    public var category: MemoryCategory?
    public var proof: SignedProof
    public init(category: MemoryCategory? = nil, proof: SignedProof) {
        self.category = category
        self.proof = proof
    }
}

/// Signed subject: the category value. Action name: `delete_memory_category`.
public struct MemoryDeleteCategoryRequest: Codable, Sendable, Equatable {
    public var proof: SignedProof
    public init(proof: SignedProof) { self.proof = proof }
}

public struct ConversationSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var updatedAt: Date
    public var lastMessagePreview: String
    public var messageCount: Int

    public init(id: String, title: String, updatedAt: Date, lastMessagePreview: String = "", messageCount: Int = 0) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.lastMessagePreview = lastMessagePreview
        self.messageCount = messageCount
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case updatedAt = "updated_at"
        case lastMessagePreview = "last_message_preview"
        case messageCount = "message_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        lastMessagePreview = try c.value(.lastMessagePreview, default: "")
        messageCount = try c.value(.messageCount, default: 0)
    }
}

public enum MessageRole: String, Codable, Sendable, CaseIterable {
    case user, assistant
}

public struct Message: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var role: MessageRole
    public var text: String
    public var language: String
    public var createdAt: Date
    public var agents: [AgentId]
    public var cards: [UICard]

    public init(id: String, role: MessageRole, text: String, language: String = "en", createdAt: Date, agents: [AgentId] = [], cards: [UICard] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.language = language
        self.createdAt = createdAt
        self.agents = agents
        self.cards = cards
    }

    enum CodingKeys: String, CodingKey {
        case id, role, text, language
        case createdAt = "created_at"
        case agents, cards
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(MessageRole.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        language = try c.value(.language, default: "en")
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        agents = try c.value(.agents, default: [])
        cards = try c.value(.cards, default: [])
    }
}

// MARK: - Voice

public struct VoiceSettings: Codable, Sendable, Equatable {
    public enum Personality: String, Codable, Sendable, CaseIterable { case calm, warm, crisp }
    public enum Gender: String, Codable, Sendable, CaseIterable { case female, male, neutral }
    public enum Language: String, Codable, Sendable, CaseIterable { case auto, en, hi, hinglish }
    public enum Engine: String, Codable, Sendable, CaseIterable { case local, cloud }
    public enum ResponseLength: String, Codable, Sendable, CaseIterable { case brief, balanced, detailed }
    public enum Activation: String, Codable, Sendable, CaseIterable {
        case button
        case holdToTalk = "hold_to_talk"
        case wakeWordInSession = "wake_word_in_session"
    }

    public var personality: Personality
    public var voiceGender: Gender
    public var speakingRate: Double
    public var language: Language
    public var engine: Engine
    public var responseLength: ResponseLength
    public var activation: Activation
    public var voiceId: String?

    public init(
        personality: Personality = .warm, voiceGender: Gender = .female, speakingRate: Double = 1.0,
        language: Language = .auto, engine: Engine = .local, responseLength: ResponseLength = .brief,
        activation: Activation = .button, voiceId: String? = nil
    ) {
        self.personality = personality
        self.voiceGender = voiceGender
        self.speakingRate = speakingRate
        self.language = language
        self.engine = engine
        self.responseLength = responseLength
        self.activation = activation
        self.voiceId = voiceId
    }

    enum CodingKeys: String, CodingKey {
        case personality
        case voiceGender = "voice_gender"
        case speakingRate = "speaking_rate"
        case language, engine
        case responseLength = "response_length"
        case activation
        case voiceId = "voice_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personality = try c.value(.personality, default: .warm)
        voiceGender = try c.value(.voiceGender, default: .female)
        speakingRate = try c.value(.speakingRate, default: 1.0)
        language = try c.value(.language, default: .auto)
        engine = try c.value(.engine, default: .local)
        responseLength = try c.value(.responseLength, default: .brief)
        activation = try c.value(.activation, default: .button)
        voiceId = try c.decodeIfPresent(String.self, forKey: .voiceId)
    }
}

public struct VoiceOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var engine: String
    public var gender: String
    public var languages: [String]
    public init(id: String, name: String, engine: String, gender: String, languages: [String]) {
        self.id = id
        self.name = name
        self.engine = engine
        self.gender = gender
        self.languages = languages
    }
}

public struct VoiceEngineStatus: Codable, Sendable, Equatable {
    public var id: String
    public var available: Bool
    public var reason: String
    public init(id: String, available: Bool, reason: String = "") {
        self.id = id
        self.available = available
        self.reason = reason
    }
    enum CodingKeys: String, CodingKey { case id, available, reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        available = try c.decode(Bool.self, forKey: .available)
        reason = try c.value(.reason, default: "")
    }
}

public struct VoiceConfig: Codable, Sendable, Equatable {
    public var settings: VoiceSettings
    public var engines: [VoiceEngineStatus]
    public var voices: [VoiceOption]
    public init(settings: VoiceSettings, engines: [VoiceEngineStatus], voices: [VoiceOption]) {
        self.settings = settings
        self.engines = engines
        self.voices = voices
    }
}

/// Short-lived grant so the device talks to the realtime voice provider without holding its key.
public struct LiveSessionGrant: Codable, Sendable, Equatable {
    public var provider: String
    public var model: String
    public var wsUrl: String
    public var ephemeralToken: String
    public var expiresAt: Date
    public var systemInstruction: String
    public var inputSampleRate: Int
    public var outputSampleRate: Int

    public init(
        provider: String, model: String, wsUrl: String, ephemeralToken: String, expiresAt: Date,
        systemInstruction: String, inputSampleRate: Int = 16000, outputSampleRate: Int = 24000
    ) {
        self.provider = provider
        self.model = model
        self.wsUrl = wsUrl
        self.ephemeralToken = ephemeralToken
        self.expiresAt = expiresAt
        self.systemInstruction = systemInstruction
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
    }

    enum CodingKeys: String, CodingKey {
        case provider, model
        case wsUrl = "ws_url"
        case ephemeralToken = "ephemeral_token"
        case expiresAt = "expires_at"
        case systemInstruction = "system_instruction"
        case inputSampleRate = "input_sample_rate"
        case outputSampleRate = "output_sample_rate"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        wsUrl = try c.decode(String.self, forKey: .wsUrl)
        ephemeralToken = try c.decode(String.self, forKey: .ephemeralToken)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        systemInstruction = try c.decode(String.self, forKey: .systemInstruction)
        inputSampleRate = try c.value(.inputSampleRate, default: 16000)
        outputSampleRate = try c.value(.outputSampleRate, default: 24000)
    }
}

public struct TTSRequest: Codable, Sendable, Equatable {
    public enum Language: String, Codable, Sendable, CaseIterable { case en, hi, hinglish }
    public var text: String
    public var language: Language
    public var voiceId: String?
    public init(text: String, language: Language = .en, voiceId: String? = nil) {
        self.text = text
        self.language = language
        self.voiceId = voiceId
    }
    enum CodingKeys: String, CodingKey {
        case text, language
        case voiceId = "voice_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        language = try c.value(.language, default: .en)
        voiceId = try c.decodeIfPresent(String.self, forKey: .voiceId)
    }
}
