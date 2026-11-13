import ConversationManager
import Foundation
import Observation
import SecurityManager
import ZoroCore

/// The composition root's product: every model the shell's views need, wired once at launch.
@MainActor
@Observable
public final class ZoroAppShell {
    public let navigation: AppNavigation
    public let sections: SectionRegistry
    public let cards: CardRendererRegistry
    public let home: HomeViewModel
    public let approvals: ApprovalSheetPresenter
    public let confirmations: DeviceActionConfirmationPresenter
    public let onboarding: OnboardingModel
    public let inbox: IntentInbox
    /// False shows first run.
    public var isPaired: Bool
    /// One sentence when a Handoff could not be continued.
    public private(set) var continuationError: String?

    public init(
        home: HomeViewModel, approvals: ApprovalSheetPresenter, confirmations: DeviceActionConfirmationPresenter,
        onboarding: OnboardingModel, isPaired: Bool, navigation: AppNavigation = AppNavigation(),
        sections: SectionRegistry = SectionRegistry(), cards: CardRendererRegistry = CardRendererRegistry(),
        inbox: IntentInbox = .shared
    ) {
        self.home = home
        self.approvals = approvals
        self.confirmations = confirmations
        self.onboarding = onboarding
        self.isPaired = isPaired
        self.navigation = navigation
        self.sections = sections
        self.cards = cards
        self.inbox = inbox
    }

    /// Wires the standard shell from `ZoroServices`: approvals go through `ApprovalCoordinator` and this
    /// shell's sheet; device actions flagged for confirmation go through the confirmation sheet first.
    public static func make(
        services: ZoroServices, clientContext: ClientContext, store: ConversationStore? = nil,
        pairing: any ServerPairing, preferences: any PreferencesStoring = UserDefaultsPreferences(),
        permissions: any PermissionPriming = SystemPermissionPriming(), context: (any HomeContextProviding)? = nil,
        isPaired: Bool
    ) -> ZoroAppShell {
        let presenter = ApprovalSheetPresenter(biometrics: services.biometrics)
        let coordinator = ApprovalCoordinator(identity: services.identity, biometrics: services.biometrics, presenter: presenter)
        let confirmations = DeviceActionConfirmationPresenter()
        let executor = ConfirmingDeviceActionExecutor(base: services.deviceActions, confirmer: confirmations)
        let conversation = ConversationManager(
            api: services.api, approvals: coordinator, deviceActions: executor, store: store, clientContext: clientContext)
        let home = HomeViewModel(
            conversation: conversation, voice: services.voice, api: services.api, context: context, permissions: permissions)
        home.voiceOptions = { [weak home] in
            // Read each time, so a language chosen in first run or Settings applies to the next session.
            VoiceSessionOptions(
                engine: .onDevice, languageHint: preferences.load().language.rawValue,
                privacyMode: home?.effectivePrivacyMode ?? .strictPrivate)
        }
        #if os(iOS)
        let guide = true
        #else
        let guide = false
        #endif
        let onboarding = OnboardingModel(pairing: pairing, preferences: preferences, showsShortcutGuide: guide)
        return ZoroAppShell(home: home, approvals: presenter, confirmations: confirmations, onboarding: onboarding, isPaired: isPaired)
    }

    /// Opens a URL from `onOpenURL`. Pairing links go to first run (or are ignored once paired).
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard navigation.handle(url) else { return false }
        consumePendingPairing()
        return true
    }

    /// Applies links the intents posted.
    public func drainIntents() {
        for link in inbox.drain() {
            navigation.handle(link)
        }
        consumePendingPairing()
    }

    /// Leaves first run once it reaches `.done`.
    public func onboardingStepChanged() {
        if onboarding.step == .done {
            isPaired = true
            Task { await home.refresh() }
        }
    }

    /// Back to first run (not paired, or this device was removed).
    public func pairAgain() {
        isPaired = false
    }

    /// Picks up a conversation handed off from another device.
    public func continueActivity(_ activity: NSUserActivity) {
        guard let continuation = ConversationActivity.parse(activity) else {
            continuationError = "This Handoff isn't a ZORO conversation."
            return
        }
        continuationError = nil
        navigation.open(continuation.section)
        Task { await self.openConversation(id: continuation.conversationId) }
    }

    /// Opens a conversation that may have started on another device (Handoff, or the Mac picking up a
    /// conversation from the iPhone): fetched from the server and adopted, so the next turn continues
    /// it. Falls back to this device's encrypted copy when the server can't be reached.
    public func openConversation(id: String) async {
        let conversation = home.conversation
        do {
            try await conversation.loadRemoteConversation(id: id)
            continuationError = nil
        } catch {
            do {
                try await conversation.loadConversation(id: id)
                guard conversation.conversationId == id else { throw ZoroError.storage("not on this device") }
                continuationError = nil
            } catch {
                continuationError = "The conversation couldn't be opened on this device."
            }
        }
    }

    private func consumePendingPairing() {
        guard let link = navigation.pendingPairing else { return }
        navigation.pendingPairing = nil
        guard !isPaired else {
            navigation.linkError = "This device is already connected. Unpair it in Security and privacy first."
            return
        }
        Task { await onboarding.apply(link) }
    }
}
