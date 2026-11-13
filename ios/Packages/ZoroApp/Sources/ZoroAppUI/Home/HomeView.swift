import SwiftUI
import ZoroCore
import ZoroDesign

/// Callbacks of the Home screen, so the screen itself is a pure function of `HomePresentation`
/// (previews and snapshots render it without services).
public struct HomeActions {
    public var orbTap: () -> Void = {}
    public var send: () -> Void = {}
    public var suggestion: (Suggestion) -> Void = { _ in }
    public var issue: (HomeIssue.Action) -> Void = { _ in }
    public var openLiveVoice: () -> Void = {}
    public var continuePriming: () -> Void = {}
    public var dismissPriming: () -> Void = {}
    public var changePrivacy: () -> Void = {}
    public init() {}
}

/// Home: the orb centred, the rekha with the current exchange, who is working, result cards,
/// suggestions from real context, and a composer for silent use.
public struct HomeScreen: View {
    let presentation: HomePresentation
    let level: Double
    let priming: AppPermission?
    let cards: CardRendererRegistry
    @Binding var draft: String
    let actions: HomeActions
    let isSnapshot: Bool

    /// - Parameter isSnapshot: true only for offscreen snapshots, which cannot draw scroll views or text fields.
    public init(
        presentation: HomePresentation, level: Double = 0, priming: AppPermission? = nil, cards: CardRendererRegistry,
        draft: Binding<String>, actions: HomeActions, isSnapshot: Bool = false
    ) {
        self.presentation = presentation
        self.level = level
        self.priming = priming
        self.cards = cards
        self._draft = draft
        self.actions = actions
        self.isSnapshot = isSnapshot
    }

    @ScaledMetric(relativeTo: .largeTitle) private var orbSize: CGFloat = 200

    public var body: some View {
        let p = presentation
        SnapshotSafeScroll(scrolls: !isSnapshot) {
            VStack(alignment: .leading, spacing: ZoroSpace.xl.value) {
                if let mode = p.privacyMode {
                    PrivacyModeBanner(mode, actionTitle: "Change", action: actions.changePrivacy)
                }
                VStack(spacing: 0) {
                    OrbControl(state: p.orbState, level: level, satellites: p.satellites, hint: OrbControl.hint(for: p.orbState), action: actions.orbTap)
                        .frame(width: orbSize, height: orbSize)
                    Text(p.stateLabel)
                        .zoroText(.detail)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, ZoroSpace.s.value)

                if let issue = p.issue {
                    IssueView(issue: issue, perform: actions.issue)
                }
                if let priming {
                    PermissionPrimingCard(permission: priming, onContinue: actions.continuePriming, onDismiss: actions.dismissPriming)
                }

                AgentChipsRow(agents: p.agents)
                ExchangeStage(zoroText: p.zoroText, ownerText: p.ownerText, isStreaming: p.zoroIsStreaming)

                if !p.cards.isEmpty {
                    VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                        ForEach(Array(p.cards.enumerated()), id: \.offset) { _, card in
                            cards.view(for: card)
                        }
                    }
                }
            }
            .padding(.horizontal, ZoroSpace.l.value)
            .padding(.bottom, ZoroSpace.xl.value)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                if !p.suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ZoroSpace.s.value) {
                            ForEach(p.suggestions) { s in
                                ZoroChip(s.title, symbol: s.symbol) { actions.suggestion(s) }
                            }
                        }
                    }
                }
                Composer(text: $draft, canSend: p.canSend, isSnapshot: isSnapshot, onSend: actions.send, onVoice: actions.openLiveVoice)
            }
            .padding(.horizontal, ZoroSpace.l.value)
            .padding(.vertical, ZoroSpace.s.value)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .background(ZoroNeutral.background)
        }
        .background(ZoroNeutral.background)
    }
}

/// Home bound to its view model.
public struct HomeView: View {
    @Bindable var model: HomeViewModel
    let navigation: AppNavigation
    let cards: CardRendererRegistry
    let openSystemSettings: () -> Void
    let pairAgain: () -> Void

    /// - Parameters:
    ///   - openSystemSettings: opens this app's page in system Settings (permission turned off).
    ///   - pairAgain: returns to the connect step of first run (not paired, or this device was removed).
    public init(
        model: HomeViewModel, navigation: AppNavigation, cards: CardRendererRegistry,
        openSystemSettings: @escaping () -> Void = {}, pairAgain: @escaping () -> Void = {}
    ) {
        self.model = model
        self.navigation = navigation
        self.cards = cards
        self.openSystemSettings = openSystemSettings
        self.pairAgain = pairAgain
    }

    public var body: some View {
        let p = model.presentation
        HomeScreen(
            presentation: p, level: model.level, priming: model.priming, cards: cards, draft: $model.draft,
            actions: actions)
            .task(id: p.orbState) { model.orbDidShow(p.orbState) }
            .zoroHaptic(.listenStart, trigger: p.orbState == .listening)
            .zoroHaptic(.failure, trigger: p.orbState == .error)
            .task(id: navigation.pendingAsk) {
                guard let ask = navigation.pendingAsk else { return }
                navigation.pendingAsk = nil
                await model.send(ask)
            }
    }

    private var actions: HomeActions {
        var a = HomeActions()
        let model = model
        let navigation = navigation
        a.orbTap = { Task { await model.handle(.tap) } }
        a.send = { Task { await model.sendDraft() } }
        a.suggestion = { s in Task { await model.perform(s, navigation: navigation) } }
        a.openLiveVoice = { navigation.open(.liveVoice) }
        a.continuePriming = { Task { await model.continuePriming() } }
        a.dismissPriming = { model.dismissPriming() }
        a.changePrivacy = { navigation.open(.security) }
        let openSettings = openSystemSettings
        let pairAgain = pairAgain
        a.issue = { action in
            switch action {
            case .reconnect: Task { await model.refresh() }
            case .pair: pairAgain()
            case .openSection(let s): navigation.open(s)
            case .retry: Task { await model.retryLast() }
            case .typeInstead: model.dismissVoiceIssue()
            case .openSystemSettings: openSettings()
            }
        }
        return a
    }
}
