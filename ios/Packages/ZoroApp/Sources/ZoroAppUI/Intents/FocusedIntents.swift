import AppIntents
import Foundation
import SwiftUI
import ZoroCore

// Focused intents: each maps its parameters to one turn (`IntentTurnText`) or one direct call, and
// answers with dialog plus snippet. All of them send personal data to the owner's server, so all require
// an unlocked phone (`IntentPrivacy`).

/// "Ask ZORO how much I spent on food last month."
public struct CheckSpendingIntent: AppIntent, ForegroundContinuableIntent {
    public static let title: LocalizedStringResource = "Check spending"
    public static let description = IntentDescription("Asks ZORO how much you spent in a period, optionally in one category. Read-only.")
    public static let openAppWhenRun = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    #if compiler(>=6.2)
    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #endif

    @Parameter(title: "Period", requestValueDialog: "For which period?")
    public var period: SpendingPeriod

    @Parameter(title: "Category")
    public var category: SpendingCategory?

    /// Resolved by the system from `AppDependencyManager` while the intent runs (`ZoroIntents.register`).
    @Dependency(default: ZoroIntentDependencies.shared)
    var dependencies: ZoroIntentDependencies

    public init() {}

    public init(period: SpendingPeriod, category: SpendingCategory? = nil) {
        self.period = period
        self.category = category
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Check spending \(\.$period) on \(\.$category)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let services = dependencies.current
        let text = IntentTurnText.spending(period: period, category: category, language: services.language())
        let plan = await IntentTurnFlow.plan(text: text, services: services)
        let spoken = try await IntentTurnFlow.deliver(plan, from: self)
        return .result(dialog: .text(spoken), view: IntentSnippetView(snippet: plan.snippet))
    }
}

/// "Compare my basket with ZORO."
public struct CompareBasketIntent: AppIntent, ForegroundContinuableIntent {
    public static let title: LocalizedStringResource = "Compare my basket"
    public static let description = IntentDescription("Asks ZORO to compare your current basket across stores. Ordering finishes in the store's app.")
    public static let openAppWhenRun = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    #if compiler(>=6.2)
    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #endif

    /// Resolved by the system from `AppDependencyManager` while the intent runs (`ZoroIntents.register`).
    @Dependency(default: ZoroIntentDependencies.shared)
    var dependencies: ZoroIntentDependencies

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let services = dependencies.current
        let plan = await IntentTurnFlow.plan(text: IntentTurnText.compareBasket(language: services.language()), services: services)
        let spoken = try await IntentTurnFlow.deliver(plan, from: self)
        return .result(dialog: .text(spoken), view: IntentSnippetView(snippet: plan.snippet))
    }
}

/// "Play music with ZORO" → "What should ZORO play?" Optionally on the Mac.
public struct PlayMusicIntent: AppIntent, ForegroundContinuableIntent {
    public static let title: LocalizedStringResource = "Play music"
    public static let description = IntentDescription("Asks ZORO to play a song, artist, album or playlist, here or on your Mac.")
    public static let openAppWhenRun = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    #if compiler(>=6.2)
    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #endif

    @Parameter(title: "Music", requestValueDialog: "What should ZORO play?")
    public var query: String

    @Parameter(title: "On my Mac", default: false)
    public var onMac: Bool

    /// Resolved by the system from `AppDependencyManager` while the intent runs (`ZoroIntents.register`).
    @Dependency(default: ZoroIntentDependencies.shared)
    var dependencies: ZoroIntentDependencies

    public init() {}

    public init(query: String, onMac: Bool = false) {
        self.query = query
        self.onMac = onMac
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$query)") { \.$onMac }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let services = dependencies.current
        guard let text = IntentTurnText.playMusic(query, onMac: onMac, language: services.language()) else {
            throw $query.needsValueError(.text(IntentCopy(services.language()).playPrompt))
        }
        let plan = await IntentTurnFlow.plan(text: text, services: services)
        let spoken = try await IntentTurnFlow.deliver(plan, from: self)
        return .result(dialog: .text(spoken), view: IntentSnippetView(snippet: plan.snippet))
    }
}

/// "Ask ZORO to remember something" → "What should ZORO remember?"
public struct RememberThisIntent: AppIntent, ForegroundContinuableIntent {
    public static let title: LocalizedStringResource = "Remember this"
    public static let description = IntentDescription("Tells ZORO something to remember. You can see and delete it in Memory.")
    public static let openAppWhenRun = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    #if compiler(>=6.2)
    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #endif

    @Parameter(title: "What to remember", requestValueDialog: "What should ZORO remember?")
    public var note: String

    /// Resolved by the system from `AppDependencyManager` while the intent runs (`ZoroIntents.register`).
    @Dependency(default: ZoroIntentDependencies.shared)
    var dependencies: ZoroIntentDependencies

    public init() {}

    public init(note: String) {
        self.note = note
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let services = dependencies.current
        guard let text = IntentTurnText.remember(note, language: services.language()) else {
            throw $note.needsValueError(.text(IntentCopy(services.language()).rememberPrompt))
        }
        let plan = await IntentTurnFlow.plan(text: text, services: services)
        let spoken = try await IntentTurnFlow.deliver(plan, from: self)
        return .result(dialog: .text(spoken), view: IntentSnippetView(snippet: plan.snippet))
    }
}

/// "Find a photo with ZORO" → "What's in the photo?" Photos are searched on this device, so the app
/// opens and shows the results there.
public struct FindPhotoIntent: AppIntent {
    public static let title: LocalizedStringResource = "Find a photo"
    public static let description = IntentDescription("Opens ZORO and searches your photos on this device.")
    public static let openAppWhenRun = true
    #if compiler(>=6.2)
    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    #endif

    @Parameter(title: "Photo of", requestValueDialog: "What's in the photo?")
    public var query: String

    /// Resolved by the system from `AppDependencyManager` while the intent runs (`ZoroIntents.register`).
    @Dependency(default: ZoroIntentDependencies.shared)
    var dependencies: ZoroIntentDependencies

    public init() {}

    public init(query: String) {
        self.query = query
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let language = dependencies.current.language()
        guard let text = IntentTurnText.findPhoto(query, language: language) else {
            throw $query.needsValueError(.text(IntentCopy(language).photoPrompt))
        }
        IntentTurnFlow.post(.ask(text))
        return .result(dialog: .text(IntentCopy(language).openingPhotos))
    }
}

/// "Turn on private mode in ZORO". Tightening only: there is deliberately no intent that turns cloud
/// intelligence back on; that happens in Security and privacy in the app.
public struct SwitchToPrivateModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Turn on private mode"
    public static let description = IntentDescription(
        "Switches ZORO to private mode, so nothing leaves your server. Turning it off is done in the app.")
    public static let openAppWhenRun = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    /// Resolved by the system from `AppDependencyManager` while the intent runs (`ZoroIntents.register`).
    @Dependency(default: ZoroIntentDependencies.shared)
    var dependencies: ZoroIntentDependencies

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = dependencies.current
        return .result(dialog: .text(await Self.dialog(services: services)))
    }

    /// The sentence for each result (exposed for tests).
    static func dialog(services: ZoroIntentServices) async -> String {
        let copy = IntentCopy(services.language())
        guard services.isConfigured else { return copy.failure(.notConfigured) }
        do {
            return try await services.privacy.switchToStrictPrivate() ? copy.privateModeOn : copy.privateModeAlreadyOn
        } catch {
            switch ZoroError.wrap(error) {
            case .transport: return copy.failure(.offline)
            case .notPaired: return copy.failure(.notPaired)
            case .unauthorized: return copy.failure(.unauthorized)
            case .http(_, let body?) where body.code == "kill_switch_active": return copy.failure(.paused)
            default: return copy.privateModeUnchanged
            }
        }
    }
}
