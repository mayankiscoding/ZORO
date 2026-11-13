import SwiftUI
import ZoroCore
import ZoroDesign

/// The app's root: first run until paired, then the iPhone tabs or the Mac sidebar, built from one
/// `AppSection` model. Handles deep links, intents, Handoff, state restoration and the approval and
/// device-action sheets.
public struct ZoroRootView: View {
    @Bindable var shell: ZoroAppShell
    let scanner: ((@escaping (PairingLink) -> Void) -> AnyView)?
    let openSystemSettings: () -> Void

    /// - Parameters:
    ///   - scanner: the setup QR scanner (on iPhone, `SetupCodeScanner`); nil hides scanning.
    ///   - openSystemSettings: opens this app's page in system Settings.
    public init(
        shell: ZoroAppShell, scanner: ((@escaping (PairingLink) -> Void) -> AnyView)? = nil,
        openSystemSettings: @escaping () -> Void = {}
    ) {
        self.shell = shell
        self.scanner = scanner
        self.openSystemSettings = openSystemSettings
    }

    @SceneStorage("zoro.navigation") private var restorationData: Data?
    @State private var restored = false

    public var body: some View {
        Group {
            if shell.isPaired {
                main
            } else {
                OnboardingView(model: shell.onboarding, scanner: scanner)
            }
        }
        .onOpenURL { shell.handle($0) }
        .onChange(of: shell.onboarding.step) { shell.onboardingStepChanged() }
        .onChange(of: shell.inbox.pending) { shell.drainIntents() }
        .onChange(of: shell.navigation.restoration) { _, new in restorationData = new.encoded() }
        .onChange(of: shell.home.conversation.phase) { _, phase in
            if case .awaitingApproval(let request) = phase {
                shell.approvals.conversationMoved(awaitingApprovalId: request.approvalId)
            } else {
                shell.approvals.conversationMoved(awaitingApprovalId: nil)
            }
        }
        .task {
            if !restored, let state = NavigationRestoration.decode(restorationData) {
                shell.navigation.restore(state)
            }
            restored = true
            shell.drainIntents()
            await shell.home.start()
        }
        .sheet(item: approvalBinding) { model in
            ApprovalSheetView(
                model: model, onApprove: { shell.approvals.approve() }, onDecline: { shell.approvals.decline() },
                onClose: { shell.approvals.dismiss() })
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled(model.phase == .authenticating)
        }
        .sheet(item: confirmationBinding) { request in
            DeviceActionConfirmationView(
                content: DeviceActionSheetContent(request), onConfirm: { shell.confirmations.confirmCurrent() },
                onDecline: { shell.confirmations.declineCurrent() })
                .presentationDetents([.medium])
        }
        .userActivity(ConversationActivity.type, isActive: shell.isPaired && shell.home.conversation.conversationId != nil) { activity in
            if let id = shell.home.conversation.conversationId {
                ConversationActivity.configure(activity, conversationId: id)
            }
        }
        .onContinueUserActivity(ConversationActivity.type) { shell.continueActivity($0) }
    }

    @ViewBuilder
    private var main: some View {
        #if os(macOS)
        SidebarLayout(shell: shell, openSystemSettings: openSystemSettings)
        #else
        TabLayout(shell: shell, openSystemSettings: openSystemSettings)
        #endif
    }

    private var approvalBinding: Binding<ApprovalSheetModel?> {
        Binding(get: { shell.approvals.current }, set: { if $0 == nil { shell.approvals.dismiss() } })
    }

    private var confirmationBinding: Binding<DeviceActionRequest?> {
        Binding(get: { shell.confirmations.current }, set: { if $0 == nil { shell.confirmations.declineCurrent() } })
    }
}

/// iPhone: ZORO, Spaces, Activity, You.
struct TabLayout: View {
    @Bindable var shell: ZoroAppShell
    let openSystemSettings: () -> Void

    var body: some View {
        @Bindable var navigation = shell.navigation
        TabView(selection: $navigation.selectedTab) {
            Tab(AppTab.zoro.title, systemImage: AppTab.zoro.symbol, value: AppTab.zoro) {
                NavigationStack {
                    HomeContainer(shell: shell, openSystemSettings: openSystemSettings)
                }
            }
            ForEach([AppTab.spaces, .activity, .you]) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    NavigationStack(path: pathBinding(tab)) {
                        SectionListView(tab: tab, registry: shell.sections)
                            .navigationDestination(for: AppSection.self) { shell.sections.view(for: $0) }
                    }
                }
            }
        }
        .zoroLiveVoiceCover(isPresented: $navigation.isLiveVoicePresented) {
            LiveVoiceView(model: shell.home) { shell.navigation.isLiveVoicePresented = false }
        }
    }

    private func pathBinding(_ tab: AppTab) -> Binding<[AppSection]> {
        Binding(get: { shell.navigation.path(for: tab) }, set: { shell.navigation.setPath($0, for: tab) })
    }
}

/// Mac: a sidebar with the same sections and the same order.
struct SidebarLayout: View {
    @Bindable var shell: ZoroAppShell
    let openSystemSettings: () -> Void

    var body: some View {
        @Bindable var navigation = shell.navigation
        NavigationSplitView {
            List(selection: $navigation.sidebarSelection) {
                ForEach(SidebarGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.symbol).tag(section)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            NavigationStack {
                switch navigation.sidebarSelection ?? .home {
                case .home: HomeContainer(shell: shell, openSystemSettings: openSystemSettings)
                case .liveVoice: LiveVoiceView(model: shell.home) { navigation.sidebarSelection = .home }
                case let section: shell.sections.view(for: section)
                }
            }
        }
        .zoroLiveVoiceCover(isPresented: $navigation.isLiveVoicePresented) {
            LiveVoiceView(model: shell.home) { shell.navigation.isLiveVoicePresented = false }
        }
    }
}

/// Home inside its navigation container, with the new-conversation and live-voice actions.
struct HomeContainer: View {
    let shell: ZoroAppShell
    let openSystemSettings: () -> Void

    var body: some View {
        HomeView(
            model: shell.home, navigation: shell.navigation, cards: shell.cards, openSystemSettings: openSystemSettings,
            pairAgain: { shell.pairAgain() })
            .navigationTitle("ZORO")
            .zoroInlineTitle()
            .toolbar {
                ToolbarItem {
                    Button {
                        shell.home.startNewConversation()
                    } label: {
                        Label("New conversation", systemImage: "square.and.pencil")
                    }
                    .disabled(shell.home.conversation.isBusy)
                }
                ToolbarItem {
                    Button {
                        shell.navigation.open(.liveVoice)
                    } label: {
                        Label("Live voice", systemImage: "waveform")
                    }
                }
            }
            .overlay(alignment: .top) {
                if let message = shell.navigation.linkError ?? shell.continuationError {
                    Text(message)
                        .zoroText(.detail)
                        .padding(.vertical, ZoroSpace.s.value)
                        .padding(.horizontal, ZoroSpace.l.value)
                        .background(ZoroNeutral.raised, in: Capsule())
                        .padding(.top, ZoroSpace.s.value)
                        .onTapGesture { shell.navigation.linkError = nil }
                        .accessibilityAddTraits(.isStaticText)
                }
            }
    }
}

/// The list of sections inside a tab (Spaces, Activity, You).
struct SectionListView: View {
    let tab: AppTab
    let registry: SectionRegistry

    var body: some View {
        List {
            ForEach(tab.sections) { section in
                NavigationLink(value: section) {
                    HStack(alignment: .firstTextBaseline, spacing: ZoroSpace.m.value) {
                        Image(systemName: section.symbol).foregroundStyle(.neel).frame(width: 24).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title).zoroText(.body)
                            Text(registry.isRegistered(section) ? section.subtitle : "Not connected yet")
                                .zoroText(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle(tab.title)
    }
}
