import SwiftUI
import ZoroCore
import ZoroDesign

/// The detail view for one screen, without its own navigation container. Use it in a Mac sidebar's
/// detail pane or as a `navigationDestination`.
public struct SystemScreenView: View {
    let screen: SystemScreen
    let container: SystemFeaturesContainer

    public init(_ screen: SystemScreen, container: SystemFeaturesContainer) {
        self.screen = screen
        self.container = container
    }

    public var body: some View {
        switch screen {
        case .memory: MemoryView(model: container.memory)
        case .integrations: IntegrationsView(model: container.integrations)
        case .deviceControl: DeviceControlView(model: container.deviceControl)
        case .security: SecurityView(model: container.security, audit: container.audit)
        case .settings: SettingsView(model: container.settings, cost: container.cost, onPair: container.onPair)
        case .activity: AgentActivityView(model: container.activity)
        case .history: HistoryView(model: container.history)
        }
    }
}

/// The "You" tab: Memory, Integrations, Device control, Security and privacy, Settings.
public struct YouTabView: View {
    let container: SystemFeaturesContainer
    @State private var path: [SystemScreen] = []

    public init(container: SystemFeaturesContainer) { self.container = container }

    public var body: some View {
        NavigationStack(path: $path) {
            ScreenScroll {
                Text("You").zoroText(.title).accessibilityAddTraits(.isHeader)
                if let mode = container.security.privacyBannerMode {
                    PrivacyModeBanner(mode, actionTitle: "Change") { path.append(.security) }
                }
                ZoroCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(SystemScreen.youSections.enumerated()), id: \.element) { index, screen in
                            if index > 0 { RowDivider() }
                            NavigationLink(value: screen) {
                                InfoRow(screen.title, detail: screen.detail, symbol: screen.symbol) {
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                                }
                                .padding(.vertical, ZoroSpace.xs.value)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("You")
            .systemInlineTitle()
            .navigationDestination(for: SystemScreen.self) { SystemScreenView($0, container: container) }
            .task { if container.security.phase == .idle { await container.security.load() } }
        }
        .environment(\.systemOpenSettings, { path.append(.settings) })
    }
}

/// The "Activity" tab: what is running now, and past conversations.
public struct ActivityTabView: View {
    let container: SystemFeaturesContainer
    @State private var selection: SystemScreen = .activity

    public init(container: SystemFeaturesContainer) { self.container = container }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $selection) {
                    ForEach(SystemScreen.activitySections) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, SystemLayout.gutter)
                .padding(.vertical, ZoroSpace.s.value)
                SystemScreenView(selection, container: container)
            }
            .background(ZoroNeutral.background)
            .navigationTitle("Activity")
            .systemInlineTitle()
        }
    }
}
