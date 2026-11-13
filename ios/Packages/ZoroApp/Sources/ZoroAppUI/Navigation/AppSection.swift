import Foundation

/// The fifteen sections of the app (design spec section 10). One model drives the iPhone tabs, the
/// Mac sidebar, deep links, App Intents and state restoration.
public enum AppSection: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case home
    case liveVoice = "live-voice"
    case history
    case activity
    case shopping
    case finance
    case investments
    case fitness
    case photos
    case music
    case memory
    case integrations
    case deviceControl = "device-control"
    case security
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "ZORO"
        case .liveVoice: "Live voice"
        case .history: "History"
        case .activity: "Agent activity"
        case .shopping: "Shopping"
        case .finance: "Finance"
        case .investments: "Investments"
        case .fitness: "Fitness"
        case .photos: "Photos"
        case .music: "Music"
        case .memory: "Memory"
        case .integrations: "Integrations"
        case .deviceControl: "Device control"
        case .security: "Security and privacy"
        case .settings: "Settings"
        }
    }

    /// SF Symbol for rows, the sidebar and intents.
    public var symbol: String {
        switch self {
        case .home: "circle.circle"
        case .liveVoice: "waveform"
        case .history: "clock.arrow.circlepath"
        case .activity: "point.3.connected.trianglepath.dotted"
        case .shopping: "basket"
        case .finance: "indianrupeesign"
        case .investments: "chart.pie"
        case .fitness: "figure.walk"
        case .photos: "photo.on.rectangle"
        case .music: "music.note"
        case .memory: "brain"
        case .integrations: "puzzlepiece.extension"
        case .deviceControl: "iphone.gen3"
        case .security: "lock.shield"
        case .settings: "gearshape"
        }
    }

    /// One plain line under the title in the Spaces and You lists.
    public var subtitle: String {
        switch self {
        case .home: "Talk to ZORO"
        case .liveVoice: "Full-screen voice"
        case .history: "Conversations, newest first"
        case .activity: "What each agent is doing"
        case .shopping: "Baskets, lists and store comparisons"
        case .finance: "Spending, read-only"
        case .investments: "Holdings and allocation, read-only"
        case .fitness: "Activity and workouts"
        case .photos: "Search your photos on this device"
        case .music: "Play, queue and choose a speaker"
        case .memory: "What ZORO remembers about you"
        case .integrations: "Connected services and what each can do"
        case .deviceControl: "Alarms, reminders and Mac automation"
        case .security: "Privacy mode, devices and the audit log"
        case .settings: "Language, voice and the Action Button"
        }
    }

    /// The iPhone tab that holds this section.
    public var tab: AppTab {
        switch self {
        case .home, .liveVoice: .zoro
        case .shopping, .finance, .investments, .fitness, .photos, .music: .spaces
        case .activity, .history: .activity
        case .memory, .integrations, .deviceControl, .security, .settings: .you
        }
    }

    /// Accepts the raw value, the case name and a few spoken forms ("live_voice", "liveVoice", "device control").
    public init?(name: String) {
        let key = name.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        if let exact = AppSection(rawValue: key) { self = exact; return }
        let compact = key.replacingOccurrences(of: "-", with: "")
        if let match = AppSection.allCases.first(where: { $0.rawValue.replacingOccurrences(of: "-", with: "") == compact }) {
            self = match
            return
        }
        switch compact {
        case "zoro": self = .home
        case "voice": self = .liveVoice
        case "agents", "agentactivity": self = .activity
        case "securityandprivacy", "privacy": self = .security
        case "devices": self = .deviceControl
        case "investment": self = .investments
        default: return nil
        }
    }
}

/// The four iPhone tabs (design spec section 10).
public enum AppTab: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case zoro, spaces, activity, you

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .zoro: "ZORO"
        case .spaces: "Spaces"
        case .activity: "Activity"
        case .you: "You"
        }
    }

    public var symbol: String {
        switch self {
        case .zoro: "circle.circle"
        case .spaces: "square.grid.2x2"
        case .activity: "point.3.connected.trianglepath.dotted"
        case .you: "person.crop.circle"
        }
    }

    /// Sections listed inside this tab, in display order. The ZORO tab is Home itself.
    public var sections: [AppSection] {
        switch self {
        case .zoro: []
        case .spaces: [.shopping, .finance, .investments, .fitness, .photos, .music]
        case .activity: [.activity, .history]
        case .you: [.memory, .integrations, .deviceControl, .security, .settings]
        }
    }
}

/// Groups of the Mac sidebar: the same sections, the same order as the iPhone tabs.
public enum SidebarGroup: String, CaseIterable, Sendable, Identifiable {
    case zoro, spaces, activity, you
    public var id: String { rawValue }
    public var title: String { tab.title }
    public var tab: AppTab { AppTab(rawValue: rawValue)! }
    public var sections: [AppSection] {
        switch self {
        case .zoro: [.home, .liveVoice]
        default: tab.sections
        }
    }
}
