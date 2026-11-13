import AppIntents
import Foundation
import Observation
import SwiftUI

/// Links delivered by App Intents while the app opens. The root view drains it on launch and
/// whenever it changes.
@MainActor
@Observable
public final class IntentInbox {
    public static let shared = IntentInbox()
    public private(set) var pending: [DeepLink] = []
    /// A conversation an intent asked the app to show (a long Siri answer). The app takes it with
    /// `takeConversation()` and opens it with `ZoroAppShell.openConversation(id:)`.
    public private(set) var pendingConversationId: String?

    public init() {}

    public func post(_ link: DeepLink) { pending.append(link) }

    public func drain() -> [DeepLink] {
        defer { pending = [] }
        return pending
    }

    /// Also posts `.section(.home)`, so the ZORO tab is showing when the conversation opens.
    public func postConversation(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingConversationId = trimmed
        post(.section(.home))
    }

    public func takeConversation() -> String? {
        defer { pendingConversationId = nil }
        return pendingConversationId
    }
}

/// Parameter handling for the intents, kept pure so it is unit-tested.
public enum IntentRouting {
    /// nil when the phrase is empty after trimming (the intent then asks for a value).
    public static func askLink(phrase: String?) -> DeepLink? {
        let text = (phrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return .ask(String(text.prefix(AskLimits.maxPhraseLength)))
    }

    public static func sectionLink(_ section: AppSection) -> DeepLink {
        section == .liveVoice ? .voice : .section(section)
    }
}

/// Lets the app target include these intents (`AppIntentsPackage`, iOS 17 / macOS 14 and later).
public struct ZoroAppIntentsPackage: AppIntentsPackage {}

extension AppSection: AppEnum {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Section"

    // A dictionary literal: the App Intents build step reads it at compile time and rejects computed values.
    // Keep in step with AppSection.title and .symbol (checked by a test).
    public static let caseDisplayRepresentations: [AppSection: DisplayRepresentation] = [
        .home: DisplayRepresentation(title: "ZORO", image: .init(systemName: "circle.circle")),
        .liveVoice: DisplayRepresentation(title: "Live voice", image: .init(systemName: "waveform")),
        .history: DisplayRepresentation(title: "History", image: .init(systemName: "clock.arrow.circlepath")),
        .activity: DisplayRepresentation(title: "Agent activity", image: .init(systemName: "point.3.connected.trianglepath.dotted")),
        .shopping: DisplayRepresentation(title: "Shopping", image: .init(systemName: "basket")),
        .finance: DisplayRepresentation(title: "Finance", image: .init(systemName: "indianrupeesign")),
        .investments: DisplayRepresentation(title: "Investments", image: .init(systemName: "chart.pie")),
        .fitness: DisplayRepresentation(title: "Fitness", image: .init(systemName: "figure.walk")),
        .photos: DisplayRepresentation(title: "Photos", image: .init(systemName: "photo.on.rectangle")),
        .music: DisplayRepresentation(title: "Music", image: .init(systemName: "music.note")),
        .memory: DisplayRepresentation(title: "Memory", image: .init(systemName: "brain")),
        .integrations: DisplayRepresentation(title: "Integrations", image: .init(systemName: "puzzlepiece.extension")),
        .deviceControl: DisplayRepresentation(title: "Device control", image: .init(systemName: "iphone.gen3")),
        .security: DisplayRepresentation(title: "Security and privacy", image: .init(systemName: "lock.shield")),
        .settings: DisplayRepresentation(title: "Settings", image: .init(systemName: "gearshape")),
    ]
}

/// "Ask ZORO …": runs a normal turn in the background and Siri speaks the answer, with a snippet of the
/// reply and its first card. The app comes forward only when the turn needs an approval or a device
/// action, or the answer is too long to read out; Siri says why first. Requires the phone to be
/// unlocked (`IntentPrivacy`).
public struct AskZoroIntent: AppIntent, ForegroundContinuableIntent {
    public static let title: LocalizedStringResource = "Ask ZORO"
    public static let description = IntentDescription(
        "Asks ZORO and reads the answer. Approvals and device steps continue in the app.")
    /// Background first; `IntentTurnFlow.deliver` brings the app forward only when needed.
    public static let openAppWhenRun = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    #if compiler(>=6.2)
    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #endif

    @Parameter(title: "Request", requestValueDialog: "What should I ask ZORO?")
    public var phrase: String

    /// Resolved by the system from `AppDependencyManager` while the intent runs (`ZoroIntents.register`).
    @Dependency(default: ZoroIntentDependencies.shared)
    var dependencies: ZoroIntentDependencies

    public init() {}

    public init(phrase: String) {
        self.phrase = phrase
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let services = dependencies.current
        guard let link = IntentRouting.askLink(phrase: phrase), case .ask(let text) = link else {
            throw $phrase.needsValueError(.text(IntentCopy(services.language()).askPrompt))
        }
        let plan = await IntentTurnFlow.plan(text: text, services: services)
        let spoken = try await IntentTurnFlow.deliver(plan, from: self)
        return .result(dialog: .text(spoken), view: IntentSnippetView(snippet: plan.snippet))
    }
}

/// Opens Live Voice and starts listening. The Action Button and the Lock Screen control run this.
public struct StartVoiceIntent: AppIntent {
    public static let title: LocalizedStringResource = "Talk to ZORO"
    public static let description = IntentDescription("Opens ZORO's live voice screen.")
    public static let openAppWhenRun = true
    #if compiler(>=6.2)
    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    #endif

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentInbox.shared.post(.voice)
        return .result()
    }
}

/// Opens one section of the app.
public struct OpenSectionIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open a ZORO section"
    public static let description = IntentDescription("Opens a section of ZORO, like Shopping or Security and privacy.")
    public static let openAppWhenRun = true
    #if compiler(>=6.2)
    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    #endif

    @Parameter(title: "Section")
    public var section: AppSection

    public init() {}

    public init(section: AppSection) {
        self.section = section
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentInbox.shared.post(IntentRouting.sectionLink(section))
        return .result()
    }
}
