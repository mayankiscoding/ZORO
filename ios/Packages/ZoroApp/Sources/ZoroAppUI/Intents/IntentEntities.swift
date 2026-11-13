import AppIntents
import CoreSpotlight
import Foundation
import ZoroCore

/// A recent conversation, for Spotlight, Shortcuts and "open my conversation about …".
/// Only the title is indexed; message text never goes into the Spotlight index.
public struct ConversationEntity: AppEntity, IndexedEntity, Identifiable, Sendable, Equatable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Conversation"
    public static let defaultQuery = ConversationEntityQuery()

    public var id: String
    public var title: String
    public var updatedAt: Date

    public init(id: String, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }

    public init(_ summary: ConversationSummary) {
        let trimmed = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: summary.id, title: trimmed.isEmpty ? "Conversation with ZORO" : trimmed, updatedAt: summary.updatedAt)
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(updatedAt.formatted(date: .abbreviated, time: .shortened))",
            image: DisplayRepresentation.Image(systemName: "bubble.left.and.text.bubble.right"))
    }
}

/// Recent conversations from the server, newest first.
public struct ConversationEntityQuery: EntityStringQuery {
    /// How many conversations Siri and Shortcuts are offered, and Spotlight indexes.
    public static let recentLimit = 20

    // Reads the registered box directly: queries also run outside an intent's perform flow (Spotlight,
    // the Shortcuts editor), where an `@Dependency` would not be initialised.
    private var dependencies: ZoroIntentDependencies { .shared }

    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        let wanted = Set(identifiers)
        return try await recent().filter { wanted.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [ConversationEntity] {
        try await recent()
    }

    public func entities(matching string: String) async throws -> [ConversationEntity] {
        Self.filter(try await recent(), matching: string)
    }

    private func recent() async throws -> [ConversationEntity] {
        let services = dependencies.current
        guard services.isConfigured else { return [] }
        return try await services.conversations.recentConversations(limit: Self.recentLimit).map(ConversationEntity.init)
    }

    /// Case- and diacritic-insensitive match on every word of `string` (pure; tested).
    public static func filter(_ entities: [ConversationEntity], matching string: String) -> [ConversationEntity] {
        let words = string.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entities }
        return entities.filter { entity in
            words.allSatisfy { entity.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

/// A section of the app as an entity, so Spotlight can offer "Finance — ZORO".
public struct SectionEntity: AppEntity, IndexedEntity, Identifiable, Sendable, Equatable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "ZORO section"
    public static let defaultQuery = SectionEntityQuery()

    public var section: AppSection
    public var id: String { section.rawValue }

    public init(_ section: AppSection) { self.section = section }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(section.title)", subtitle: "\(section.subtitle)",
            image: DisplayRepresentation.Image(systemName: section.symbol))
    }

    /// Every section except Live Voice, which is reached through "Talk to ZORO".
    public static var all: [SectionEntity] { AppSection.allCases.filter { $0 != .liveVoice }.map(SectionEntity.init) }
}

public struct SectionEntityQuery: EnumerableEntityQuery {
    public init() {}
    public func allEntities() async throws -> [SectionEntity] { SectionEntity.all }
    public func entities(for identifiers: [String]) async throws -> [SectionEntity] {
        identifiers.compactMap { AppSection(rawValue: $0) }.map(SectionEntity.init)
    }
    public func suggestedEntities() async throws -> [SectionEntity] { SectionEntity.all }
}

/// Opens a conversation (Spotlight result, Shortcuts) in the app.
public struct OpenConversationIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open a ZORO conversation"
    public static let description = IntentDescription("Opens a recent conversation in ZORO.")
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Conversation")
    public var target: ConversationEntity

    public init() {}

    public init(target: ConversationEntity) {
        self.target = target
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentTurnFlow.post(.conversation(target.id))
        return .result()
    }
}

/// Opens a section from Spotlight or Shortcuts.
public struct OpenSectionEntityIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open ZORO section"
    public static let isDiscoverable = false

    @Parameter(title: "Section")
    public var target: SectionEntity

    public init() {}

    public init(target: SectionEntity) {
        self.target = target
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentInbox.shared.post(IntentRouting.sectionLink(target.section))
        return .result()
    }
}

/// Spotlight indexing and donations, so Siri and Spotlight suggest ZORO actions.
public enum ZoroIntentDiscovery {
    /// Indexes the sections and the titles of recent conversations, then refreshes App Shortcut
    /// parameters. Call after pairing, when the app becomes active, and after a conversation ends.
    public static func refresh(services: ZoroIntentServices = ZoroIntentDependencies.shared.current) async {
        guard services.isConfigured else { return }
        let index = CSSearchableIndex.default()
        try? await index.indexAppEntities(SectionEntity.all)
        if let recent = try? await services.conversations.recentConversations(limit: ConversationEntityQuery.recentLimit) {
            try? await index.deleteAppEntities(ofType: ConversationEntity.self)
            try? await index.indexAppEntities(recent.map(ConversationEntity.init))
        }
        services.updateShortcutParameters()
    }

    /// Removes every ZORO entity from Spotlight (unpairing, or the owner turned Spotlight off for ZORO).
    public static func removeAll() async {
        let index = CSSearchableIndex.default()
        try? await index.deleteAppEntities(ofType: ConversationEntity.self)
        try? await index.deleteAppEntities(ofType: SectionEntity.self)
    }

    /// What the owner just did in the app, donated so Siri can suggest the same action later.
    public enum Action: Sendable, Equatable {
        case voice
        case section(AppSection)
        /// A request and the data classes of its reply. Replies with sensitive, financial, health or secret
        /// data are not donated, so a private question never turns up as a Siri suggestion.
        case ask(String, replyDataClasses: [DataClass])
        case spending(SpendingPeriod, SpendingCategory?)
        case compareBasket
    }

    /// Donates the matching intent. Questions are donated only for requests the owner typed or said in
    /// the app; nothing from the server or from a web page is donated.
    public static func donate(_ action: Action) {
        switch action {
        case .voice: _ = StartVoiceIntent().donate()
        case .section(let section): _ = OpenSectionIntent(section: section).donate()
        case .ask(let text, let classes):
            guard shouldDonate(replyDataClasses: classes) else { return }
            guard let link = IntentRouting.askLink(phrase: text), case .ask(let clean) = link else { return }
            _ = AskZoroIntent(phrase: clean).donate()
        case .spending(let period, let category): _ = CheckSpendingIntent(period: period, category: category).donate()
        case .compareBasket: _ = CompareBasketIntent().donate()
        }
    }

    /// Only public or personal replies may become suggestions.
    public static func shouldDonate(replyDataClasses classes: [DataClass]) -> Bool {
        Set(classes).isSubset(of: [.public, .personal])
    }
}
