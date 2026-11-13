import ConversationManager
import Foundation
import Observation
import SwiftUI
import ZoroCore

/// Every screen this package provides. The iPhone tabs show these as lists; the Mac sidebar can use
/// `SystemScreenView` for the detail pane.
public enum SystemScreen: String, CaseIterable, Hashable, Sendable, Identifiable {
    case memory, integrations, deviceControl, security, settings
    case activity, history

    public var id: String { rawValue }

    /// The sections of the You tab, in order.
    public static let youSections: [SystemScreen] = [.memory, .integrations, .deviceControl, .security, .settings]
    /// The sections of the Activity tab, in order.
    public static let activitySections: [SystemScreen] = [.activity, .history]

    public var title: String {
        switch self {
        case .memory: "Memory"
        case .integrations: "Integrations"
        case .deviceControl: "Device control"
        case .security: "Security and privacy"
        case .settings: "Settings"
        case .activity: "Now"
        case .history: "History"
        }
    }

    public var detail: String {
        switch self {
        case .memory: "What ZORO has saved about you."
        case .integrations: "What ZORO can connect to, and what each one needs."
        case .deviceControl: "Your devices, quick actions and what iOS doesn't allow."
        case .security: "Privacy mode, kill switch, permissions and the audit log."
        case .settings: "Server, voice, language, appearance, models and costs."
        case .activity: "Agents and steps that are running now."
        case .history: "Your past conversations."
        }
    }

    public var symbol: String {
        switch self {
        case .memory: "brain"
        case .integrations: "puzzlepiece.extension"
        case .deviceControl: "iphone.and.laptopcomputer"
        case .security: "lock.shield"
        case .settings: "gearshape"
        case .activity: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// Builds every view model of this package from the app's services and holds them, so state survives
/// tab switches. Create one in the composition root and pass it to `YouTabView` and `ActivityTabView`.
@MainActor
public final class SystemFeaturesContainer {
    public let memory: MemoryViewModel
    public let integrations: IntegrationsViewModel
    public let deviceControl: DeviceControlViewModel
    public let security: SecurityViewModel
    public let audit: AuditLogViewModel
    public let settings: SettingsViewModel
    public let cost: CostViewModel
    public let history: HistoryViewModel
    public let activity: AgentActivityViewModel

    /// Opens the app's pairing flow (server address and pairing code).
    public var onPair: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - services: the app's services; only `api`, `identity`, `keys`, `biometrics` and `deviceActions` are used.
    ///   - conversations: the shared conversation manager, for live agent activity.
    ///   - deviceRegistry: what this device can do natively; merged into Integrations when given.
    ///   - localHistory: the encrypted on-device conversation store (`ConversationStore`), for offline history.
    ///   - serverAddress: the address the device is paired with, for display.
    ///   - preferences: per-device preferences (appearance).
    ///   - quickActions: device quick actions; only those the device supports are enabled.
    ///   - onContinueConversation: called with a conversation id when the owner continues it from History.
    public init(
        services: ZoroServices, conversations: ConversationManager, deviceRegistry: (any DeviceCapabilityRegistry)? = nil,
        localHistory: (any LocalConversationStoring)? = nil, serverAddress: any ServerAddressProviding = StaticServerAddress(nil),
        preferences: any PreferencesStoring = UserDefaultsPreferences(), quickActions: [DeviceQuickAction] = DeviceQuickAction.suggested,
        onPair: (@MainActor () -> Void)? = nil, onContinueConversation: (@MainActor (String) -> Void)? = nil
    ) {
        memory = MemoryViewModel(api: services.api, identity: services.identity)
        integrations = IntegrationsViewModel(api: services.api, deviceRegistry: deviceRegistry)
        deviceControl = DeviceControlViewModel(api: services.api, identity: services.identity, executor: services.deviceActions, quickActions: quickActions)
        security = SecurityViewModel(api: services.api, identity: services.identity, keys: services.keys, biometrics: services.biometrics)
        audit = AuditLogViewModel(api: services.api)
        settings = SettingsViewModel(api: services.api, identity: services.identity, address: serverAddress, preferences: preferences)
        cost = CostViewModel(api: services.api)
        history = HistoryViewModel(api: services.api, local: localHistory)
        activity = AgentActivityViewModel(manager: conversations, api: services.api)
        self.onPair = onPair
        history.onContinue = onContinueConversation
    }

    /// For `.preferredColorScheme(_:)` at the root of the app; nil follows the device.
    public var preferredColorScheme: ColorScheme? {
        switch settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
