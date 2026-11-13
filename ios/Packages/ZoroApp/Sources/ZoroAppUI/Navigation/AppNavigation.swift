import Foundation
import Observation

/// What `@SceneStorage` keeps between launches. Live Voice is never restored: the app must not
/// reopen the microphone screen on its own.
public struct NavigationRestoration: Codable, Sendable, Equatable {
    public var tab: AppTab
    public var spacesPath: [AppSection]
    public var activityPath: [AppSection]
    public var youPath: [AppSection]
    public var sidebar: AppSection?

    public init(tab: AppTab = .zoro, spacesPath: [AppSection] = [], activityPath: [AppSection] = [], youPath: [AppSection] = [], sidebar: AppSection? = .home) {
        self.tab = tab
        self.spacesPath = spacesPath
        self.activityPath = activityPath
        self.youPath = youPath
        self.sidebar = sidebar
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Unreadable or foreign data restores the default (ZORO tab) instead of failing.
    public static func decode(_ data: Data?) -> NavigationRestoration? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(NavigationRestoration.self, from: data)
    }
}

/// Navigation state for both layouts: iPhone tabs with one stack per tab, and the Mac sidebar.
@MainActor
@Observable
public final class AppNavigation {
    public var selectedTab: AppTab = .zoro
    public var spacesPath: [AppSection] = []
    public var activityPath: [AppSection] = []
    public var youPath: [AppSection] = []
    /// Mac sidebar selection.
    public var sidebarSelection: AppSection? = .home
    public var isLiveVoicePresented = false
    /// Set by a `zoro://pair` link; the onboarding form reads and clears it.
    public var pendingPairing: PairingLink?
    /// Set by `zoro://ask` and `AskZoroIntent`; Home sends it as a turn and clears it.
    public var pendingAsk: String?
    /// One sentence when a link could not be opened.
    public var linkError: String?

    public init() {}

    /// Shows a section in both layouts. Home closes Live Voice and pops the ZORO tab.
    public func open(_ section: AppSection) {
        linkError = nil
        sidebarSelection = section == .liveVoice ? .home : section
        selectedTab = section.tab
        switch section.tab {
        case .zoro:
            isLiveVoicePresented = section == .liveVoice
        case .spaces: spacesPath = [section]
        case .activity: activityPath = [section]
        case .you: youPath = [section]
        }
    }

    public func path(for tab: AppTab) -> [AppSection] {
        switch tab {
        case .zoro: []
        case .spaces: spacesPath
        case .activity: activityPath
        case .you: youPath
        }
    }

    public func setPath(_ path: [AppSection], for tab: AppTab) {
        // A section may only sit in its own tab's stack.
        let valid = path.filter { $0.tab == tab }
        switch tab {
        case .zoro: break
        case .spaces: spacesPath = valid
        case .activity: activityPath = valid
        case .you: youPath = valid
        }
    }

    /// Opens a URL. Returns false (and sets `linkError`) when the link is not a ZORO link it understands.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        do {
            handle(try DeepLink.parse(url))
            return true
        } catch {
            linkError = error.errorDescription
            return false
        }
    }

    public func handle(_ link: DeepLink) {
        linkError = nil
        switch link {
        case .section(let section): open(section)
        case .voice: open(.liveVoice)
        case .ask(let text):
            open(.home)
            pendingAsk = text
        case .pair(let pairing):
            pendingPairing = pairing
        }
    }

    // MARK: - Restoration

    public var restoration: NavigationRestoration {
        NavigationRestoration(tab: selectedTab, spacesPath: spacesPath, activityPath: activityPath, youPath: youPath, sidebar: sidebarSelection)
    }

    public func restore(_ state: NavigationRestoration) {
        selectedTab = state.tab
        setPath(state.spacesPath, for: .spaces)
        setPath(state.activityPath, for: .activity)
        setPath(state.youPath, for: .you)
        sidebarSelection = state.sidebar == .liveVoice ? .home : state.sidebar
        isLiveVoicePresented = false
    }
}
