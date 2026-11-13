import AppIntents
import Foundation
import ZoroCore

/// Recent conversations for the conversation entity, Spotlight and suggestions.
public protocol IntentConversationListing: Sendable {
    func recentConversations(limit: Int) async throws -> [ConversationSummary]
}

/// Tightens privacy to strict private mode. Loosening is deliberately not offered to intents: it happens
/// only in the app's Security and privacy screen.
public protocol PrivacyModeTightening: Sendable {
    /// Returns false when strict private mode was already on.
    func switchToStrictPrivate() async throws -> Bool
}

public struct APIConversationListing: IntentConversationListing {
    private let api: any ZoroAPI
    public init(api: any ZoroAPI) { self.api = api }
    public func recentConversations(limit: Int) async throws -> [ConversationSummary] {
        try await api.conversations(cursor: nil, limit: limit).items
    }
}

/// Reads the server's mode, then sends a `set_privacy_mode` change signed with this device's approval key
/// (a user-presence prompt on a real device). Never sends an unsigned or foreign-device proof.
public struct SignedPrivacyModeTightener: PrivacyModeTightening {
    private let api: any ZoroAPI
    private let identity: any DeviceIdentityProviding
    private let now: @Sendable () -> Date

    public init(api: any ZoroAPI, identity: any DeviceIdentityProviding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.identity = identity
        self.now = now
    }

    public func switchToStrictPrivate() async throws -> Bool {
        let state = try await api.securityState()
        guard state.privacyMode != .strictPrivate else { return false }
        guard let deviceId = await identity.deviceId() else { throw ZoroError.notPaired }
        let proof = try await identity.signProof(.setPrivacyMode(.strictPrivate), key: .approval, at: now())
        guard proof.deviceId == deviceId, !proof.signatureB64.isEmpty else {
            throw ZoroError.signingFailed("the proof did not come from this device")
        }
        try await api.setPrivacyMode(PrivacyModeUpdate(mode: .strictPrivate, proof: proof))
        return true
    }
}

/// Everything the intents need, registered once at launch through `ZoroIntents.register`.
public struct ZoroIntentServices: Sendable {
    public var turns: any IntentTurnRunning
    public var conversations: any IntentConversationListing
    public var privacy: any PrivacyModeTightening
    /// The owner's language (first run / Settings), read on every run.
    public var language: @Sendable () -> ZoroLanguage
    /// Calls `ZOROShortcuts.updateAppShortcutParameters()` in the app target.
    public var updateShortcutParameters: @Sendable () -> Void
    public var isConfigured: Bool

    public init(
        turns: any IntentTurnRunning, conversations: any IntentConversationListing, privacy: any PrivacyModeTightening,
        language: @escaping @Sendable () -> ZoroLanguage, updateShortcutParameters: @escaping @Sendable () -> Void = {},
        isConfigured: Bool = true
    ) {
        self.turns = turns
        self.conversations = conversations
        self.privacy = privacy
        self.language = language
        self.updateShortcutParameters = updateShortcutParameters
        self.isConfigured = isConfigured
    }

    /// The real services, built from the app's `ZoroServices`.
    public static func live(
        services: ZoroServices, clientContext: ClientContext, preferences: any PreferencesStoring,
        timeout: Duration = ZoroIntentTurnRunner.defaultTimeout, updateShortcutParameters: @escaping @Sendable () -> Void = {}
    ) -> ZoroIntentServices {
        ZoroIntentServices(
            turns: ZoroIntentTurnRunner(api: services.api, client: clientContext, timeout: timeout),
            conversations: APIConversationListing(api: services.api),
            privacy: SignedPrivacyModeTightener(api: services.api, identity: services.identity),
            language: { preferences.load().language },
            updateShortcutParameters: updateShortcutParameters)
    }

    /// Used until the app registers: every intent answers with `IntentTurnFailure.notConfigured`.
    public static let notConfigured = ZoroIntentServices(
        turns: NotConfiguredRunner(), conversations: NotConfiguredRunner(), privacy: NotConfiguredRunner(),
        language: { .english }, isConfigured: false)

    struct NotConfiguredRunner: IntentTurnRunning, IntentConversationListing, PrivacyModeTightening {
        func run(_ request: IntentTurnRequest) async -> IntentTurnOutcome { .failed(.notConfigured) }
        func recentConversations(limit: Int) async throws -> [ConversationSummary] { [] }
        func switchToStrictPrivate() async throws -> Bool { throw ZoroError.notPaired }
    }
}

/// The one object registered with `AppDependencyManager`; intents resolve it with `@Dependency`.
/// Re-registering (tests, re-pairing) swaps its contents instead of adding a second dependency.
public final class ZoroIntentDependencies: @unchecked Sendable {
    public static let shared = ZoroIntentDependencies()

    private let lock = NSLock()
    private var services: ZoroIntentServices = .notConfigured
    private var addedToManager = false

    public var current: ZoroIntentServices { lock.withLock { services } }

    func replace(with services: ZoroIntentServices) -> Bool {
        lock.withLock {
            self.services = services
            defer { addedToManager = true }
            return !addedToManager
        }
    }
}

/// The single entry point the app calls at launch.
public enum ZoroIntents {
    /// Registers what the App Intents need. Call once in the app's `init()`, before any scene appears,
    /// on both iPhone and Mac:
    ///
    ///     ZoroIntents.register(
    ///         services: services, clientContext: clientContext,
    ///         updateShortcutParameters: { ZOROShortcuts.updateAppShortcutParameters() })
    @MainActor
    public static func register(
        services: ZoroServices, clientContext: ClientContext,
        preferences: any PreferencesStoring = UserDefaultsPreferences(),
        updateShortcutParameters: @escaping @Sendable () -> Void = {}
    ) {
        register(.live(
            services: services, clientContext: clientContext, preferences: preferences,
            updateShortcutParameters: updateShortcutParameters))
    }

    /// Registers prebuilt services (tests use this with fakes).
    public static func register(_ services: ZoroIntentServices) {
        let box = ZoroIntentDependencies.shared
        if box.replace(with: services) {
            AppDependencyManager.shared.add(dependency: box)
        }
    }
}
