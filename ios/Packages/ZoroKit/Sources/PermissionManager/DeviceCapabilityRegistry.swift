import Foundation
import ZoroCore
#if canImport(HealthKit)
import HealthKit
#endif

/// Facts about the device the registry needs besides permissions.
public struct DeviceEnvironment: Sendable, Equatable {
    public var platform: DevicePlatform
    /// Major OS version (26 for iOS 26 or macOS 26).
    public var osMajorVersion: Int
    public var healthDataAvailable: Bool
    /// `MFMessageComposeViewController.canSendText()`: false on Mac, iPad without Messages and the simulator.
    public var canComposeMessages: Bool
    /// True once the app has a HomeKit implementation wired for `ios.home.run_scene`.
    public var homeKitScenesEnabled: Bool
    /// `SystemLanguageModel.default.isAvailable` (Apple's on-device model, English only for ZORO).
    public var onDeviceLanguageModelAvailable: Bool

    public init(
        platform: DevicePlatform, osMajorVersion: Int, healthDataAvailable: Bool = false, canComposeMessages: Bool = false,
        homeKitScenesEnabled: Bool = false, onDeviceLanguageModelAvailable: Bool = false
    ) {
        self.platform = platform
        self.osMajorVersion = osMajorVersion
        self.healthDataAvailable = healthDataAvailable
        self.canComposeMessages = canComposeMessages
        self.homeKitScenesEnabled = homeKitScenesEnabled
        self.onDeviceLanguageModelAvailable = onDeviceLanguageModelAvailable
    }

    /// Reads platform, OS version and HealthKit availability from the running system. Flags the system
    /// cannot tell from here (message composer, HomeKit, Apple model) come from the app shell.
    public static func current(
        canComposeMessages: Bool = false, homeKitScenesEnabled: Bool = false, onDeviceLanguageModelAvailable: Bool = false
    ) -> DeviceEnvironment {
        #if os(iOS)
        let platform = DevicePlatform.ios
        #else
        let platform = DevicePlatform.macos
        #endif
        #if canImport(HealthKit)
        let health = HKHealthStore.isHealthDataAvailable()
        #else
        let health = false
        #endif
        return DeviceEnvironment(
            platform: platform, osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            healthDataAvailable: health, canComposeMessages: canComposeMessages,
            homeKitScenesEnabled: homeKitScenesEnabled, onDeviceLanguageModelAvailable: onDeviceLanguageModelAvailable)
    }
}

/// One row of the device-side capability list.
public struct DeviceCapabilityEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var status: CapabilityStatus
    /// One honest sentence: what works, what the owner must do, or why it cannot.
    public var note: String
    /// The device-contract tool name, nil for local features and "not available" entries.
    public var tool: String?
    public var permission: PermissionKind?
    public var permissionStatus: PermissionStatus?
    public var platforms: Set<DevicePlatform>
    /// Whether the device would run this tool when asked right now (a not-yet-asked permission counts: it is asked in context).
    public var isExecutable: Bool

    public init(
        id: String, title: String, status: CapabilityStatus, note: String, tool: String? = nil, permission: PermissionKind? = nil,
        permissionStatus: PermissionStatus? = nil, platforms: Set<DevicePlatform> = [.ios, .macos], isExecutable: Bool
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.note = note
        self.tool = tool
        self.permission = permission
        self.permissionStatus = permissionStatus
        self.platforms = platforms
        self.isExecutable = isExecutable
    }

    /// The shape of `GET /v1/capabilities` rows, for the Integrations screen.
    public var capability: Capability {
        Capability(
            id: id, title: title, domain: "device", status: status, integrationLevel: Self.level(status),
            requires: permission.map { [$0.rawValue] } ?? [], note: note)
    }

    private static func level(_ status: CapabilityStatus) -> IntegrationLevel {
        switch status {
        case .workingNative, .workingLocal, .workingIntegration: .fullyIntegrated
        case .manualUserStep: .deepLinkHandoff
        case .requiresCredentials, .requiresPartnership, .restrictedByIos, .unavailable: .unavailable
        }
    }
}

/// The device-side capability list: every tool in `docs/architecture/device-contract.md`, the on-device
/// features and the "Not available" entries, computed from platform, OS version and permission status.
/// Feeds the device channel hello (`supportedTools`) and the Integrations screen. Pure and synchronous.
public struct DeviceCapabilityRegistry: Sendable {
    public var environment: DeviceEnvironment
    public init(environment: DeviceEnvironment) { self.environment = environment }

    /// Alarm and timer tools need AlarmKit (iOS 26).
    public static let alarmKitMinimumMajorVersion = 26

    // MARK: Output

    /// All entries in a stable order. `permissions` missing a kind reads as `.notDetermined`.
    public func entries(permissions: [PermissionKind: PermissionStatus]) -> [DeviceCapabilityEntry] {
        let p = Resolver(environment: environment, permissions: permissions)
        return toolEntries(p) + localEntries(p) + Self.restrictedEntries
    }

    /// Tool names the device announces in the channel hello: executable tools on this platform.
    public func supportedTools(permissions: [PermissionKind: PermissionStatus]) -> [String] {
        entries(permissions: permissions).compactMap { $0.isExecutable ? $0.tool : nil }
    }

    /// Rows for the Integrations screen (only entries that apply to this platform).
    public func capabilities(permissions: [PermissionKind: PermissionStatus]) -> [Capability] {
        entries(permissions: permissions).filter { $0.platforms.contains(environment.platform) }.map(\.capability)
    }

    // MARK: Tool entries

    private func toolEntries(_ p: Resolver) -> [DeviceCapabilityEntry] {
        let both: Set<DevicePlatform> = [.ios, .macos]
        var out: [DeviceCapabilityEntry] = []

        out.append(p.gated(
            "device.reminder.create", "Create reminders", .reminders, both,
            ok: "Adds reminders to the Reminders app."))
        out.append(p.gated(
            "device.calendar.create_event", "Add calendar events", .calendars, both,
            ok: "Adds events to your calendar.",
            limited: "Write-only calendar access: can add events."))
        out.append(p.gated(
            "device.calendar.upcoming", "Read upcoming events", .calendars, both,
            ok: "Reads your upcoming events.",
            limited: "Calendar access is write-only, so events cannot be read. Allow full access in Settings.",
            limitedBlocks: true))
        out.append(p.gated(
            "device.contacts.find", "Find contacts", .contacts, both,
            ok: "Looks up names, numbers and emails in your contacts.",
            limited: "Limited access: only the contacts you shared are found."))
        out.append(p.gated(
            "device.contacts.save", "Save contacts", .contacts, both,
            ok: "Saves a new contact.",
            limited: "Limited access: saving works, finding sees only the contacts you shared."))
        out.append(p.gated(
            "device.notification.schedule", "Schedule notifications", .notifications, both,
            ok: "Schedules a notification on this device.",
            limited: "Notifications are delivered quietly (provisional)."))
        out.append(p.gated(
            "device.location.current", "Current location", .location, both,
            ok: "Reads your location when you ask for something nearby."))
        out.append(DeviceCapabilityEntry(
            id: "device.open_url", title: "Open links", status: .workingNative,
            note: "Opens https links and allowlisted app links.", tool: "device.open_url", platforms: both, isExecutable: true))
        out.append(DeviceCapabilityEntry(
            id: "device.shortcut.run", title: "Run Shortcuts", status: .workingNative,
            note: environment.platform == .ios
                ? "Opens the Shortcuts app and runs the shortcut you name."
                : "Runs the shortcut you name with the shortcuts command.",
            tool: "device.shortcut.run", platforms: both, isExecutable: true))
        out.append(p.gated(
            "device.music.control", "Music control", .music, both,
            ok: "Plays and controls Apple Music. Spotify opens the Spotify app."))
        out.append(p.gated(
            "device.photos.search", "Photo search", .photos, both,
            ok: "Searches photos on this device. Images never leave it.",
            limited: "Limited library: only the photos you chose are searched."))
        out.append(healthEntry(p))
        out.append(DeviceCapabilityEntry(
            id: "device.whatsapp.compose", title: "Message in WhatsApp", status: .manualUserStep,
            note: "Opens WhatsApp with the text ready. You tap send.", tool: "device.whatsapp.compose", platforms: both,
            isExecutable: true))
        out.append(alarmEntry(p, id: "ios.alarm.create", title: "Set alarms", ok: "Sets an alarm with AlarmKit."))
        out.append(alarmEntry(p, id: "ios.timer.start", title: "Start timers", ok: "Starts a countdown timer with AlarmKit."))
        out.append(messageComposeEntry())
        out.append(homeEntry())
        out.append(macEntry(
            "mac.applescript.run", "Run allowlisted scripts",
            note: "Runs only scripts on the allowlist, never script text from a model. macOS asks once per app it controls."))
        out.append(macEntry(
            "mac.file.search", "Search files", note: "Searches only the folders you approved."))
        out.append(macEntry("mac.file.open", "Open files", note: "Opens a file from an approved folder."))
        return out
    }

    private func healthEntry(_ p: Resolver) -> DeviceCapabilityEntry {
        let tool = "device.health.query"
        let title = "Health data"
        if environment.platform == .macos {
            return DeviceCapabilityEntry(
                id: tool, title: title, status: .unavailable, note: "Health data is read on iPhone. Mac answers unsupported.",
                tool: tool, permission: .health, permissionStatus: p.status(.health), platforms: [.ios, .macos], isExecutable: false)
        }
        if !environment.healthDataAvailable || p.status(.health) == .unsupported {
            return DeviceCapabilityEntry(
                id: tool, title: title, status: .unavailable, note: "Health data is not available on this device.",
                tool: tool, permission: .health, permissionStatus: .unsupported, platforms: [.ios, .macos], isExecutable: false)
        }
        return p.gated(
            tool, title, .health, [.ios, .macos],
            ok: "Reads steps, workouts, sleep and heart rate. Apple Health does not say which types you allowed; a type you denied shows no data.")
    }

    private func alarmEntry(_ p: Resolver, id: String, title: String, ok: String) -> DeviceCapabilityEntry {
        let platforms: Set<DevicePlatform> = [.ios]
        let status = p.status(.alarms)
        if environment.platform != .ios {
            return DeviceCapabilityEntry(
                id: id, title: title, status: .unavailable, note: "Alarms and timers run on iPhone only.", tool: id,
                permission: .alarms, permissionStatus: status, platforms: platforms, isExecutable: false)
        }
        if environment.osMajorVersion < Self.alarmKitMinimumMajorVersion {
            return DeviceCapabilityEntry(
                id: id, title: title, status: .unavailable,
                note: "Alarms and timers need iOS 26 or later (AlarmKit). Update iOS to use them.", tool: id, permission: .alarms,
                permissionStatus: .unsupported, platforms: platforms, isExecutable: false)
        }
        return p.gated(id, title, .alarms, platforms, ok: ok)
    }

    private func messageComposeEntry() -> DeviceCapabilityEntry {
        let id = "ios.message.compose"
        let title = "Compose a text message"
        let platforms: Set<DevicePlatform> = [.ios]
        if environment.platform != .ios {
            return DeviceCapabilityEntry(
                id: id, title: title, status: .unavailable, note: "The message composer is on iPhone only.", tool: id,
                platforms: platforms, isExecutable: false)
        }
        if !environment.canComposeMessages {
            return DeviceCapabilityEntry(
                id: id, title: title, status: .unavailable, note: "This device cannot send text messages.", tool: id,
                platforms: platforms, isExecutable: false)
        }
        return DeviceCapabilityEntry(
            id: id, title: title, status: .manualUserStep, note: "Opens the message composer. You tap send.", tool: id,
            platforms: platforms, isExecutable: true)
    }

    private func homeEntry() -> DeviceCapabilityEntry {
        let id = "ios.home.run_scene"
        let title = "Run Home scenes"
        let platforms: Set<DevicePlatform> = [.ios]
        if environment.platform != .ios {
            return DeviceCapabilityEntry(
                id: id, title: title, status: .unavailable, note: "HomeKit scenes run on iPhone only.", tool: id,
                platforms: platforms, isExecutable: false)
        }
        if !environment.homeKitScenesEnabled {
            return DeviceCapabilityEntry(
                id: id, title: title, status: .unavailable,
                note: "HomeKit scenes are not set up in this app yet. Home Assistant on your server covers smart-home control.",
                tool: id, platforms: platforms, isExecutable: false)
        }
        return DeviceCapabilityEntry(
            id: id, title: title, status: .workingNative, note: "Runs a Home scene by name.", tool: id, platforms: platforms,
            isExecutable: true)
    }

    private func macEntry(_ id: String, _ title: String, note: String) -> DeviceCapabilityEntry {
        let onMac = environment.platform == .macos
        return DeviceCapabilityEntry(
            id: id, title: title, status: onMac ? .workingNative : .unavailable,
            note: onMac ? note : "Runs on Mac only.", tool: id, platforms: [.macos], isExecutable: onMac)
    }

    // MARK: Local features

    private func localEntries(_ p: Resolver) -> [DeviceCapabilityEntry] {
        var out: [DeviceCapabilityEntry] = []
        out.append(DeviceCapabilityEntry(
            id: "local.commands", title: "On-device commands", status: .workingLocal,
            note: "Alarms, timers, reminders, calendar lookups, music control and photo search are understood on this device, without the server.",
            isExecutable: true))

        let mic = p.status(.microphone)
        let speech = p.status(.speechRecognition)
        let voice: (CapabilityStatus, String, Bool)
        if mic == .unsupported || speech == .unsupported {
            voice = (.unavailable, "Speech input is not available on this device.", false)
        } else if mic == .restricted || speech == .restricted {
            voice = (.unavailable, "Speech input is blocked by Screen Time or a device management profile.", false)
        } else if mic == .denied || speech == .denied {
            voice = (.manualUserStep, "Microphone or speech recognition is off. Turn it on for ZORO in Settings.", false)
        } else if mic.allowsUse && speech.allowsUse {
            voice = (.workingNative, "Your voice is turned into text on this device while you talk to ZORO.", true)
        } else {
            voice = (.workingNative, "Asks for microphone and speech recognition access the first time you talk to ZORO.", true)
        }
        out.append(DeviceCapabilityEntry(
            id: "local.voice_input", title: "Voice input", status: voice.0, note: voice.1, permission: .microphone,
            permissionStatus: mic, isExecutable: voice.2))

        let modelOK = environment.onDeviceLanguageModelAvailable && environment.osMajorVersion >= 26
        out.append(DeviceCapabilityEntry(
            id: "local.apple_model", title: "Apple on-device model",
            status: modelOK ? .workingLocal : .unavailable,
            note: modelOK
                ? "Helps understand English commands on this device. Hindi and Hinglish use the built-in rules and your server."
                : "Needs a device with Apple Intelligence on iOS 26 or macOS 26. English commands use the built-in rules instead.",
            isExecutable: modelOK))
        return out
    }

    // MARK: Not available to any third-party app

    private static let restrictedEntries: [DeviceCapabilityEntry] = [
        restricted("restricted.wake_word", "Replace Siri's wake word",
                   "iOS has no wake-word access for apps. Start ZORO with the Action Button, the orb, or \"Ask ZORO\" to Siri."),
        restricted("restricted.background_listening", "Listen in the background",
                   "iOS does not let apps listen without an active audio session. ZORO listens only while you talk to it."),
        restricted("restricted.read_messages", "Read SMS, WhatsApp or other apps' data",
                   "iOS keeps other apps' data private. ZORO can open WhatsApp with a message ready for you."),
        restricted("restricted.silent_send", "Send messages silently",
                   "Messages always wait for you to tap send."),
        restricted("restricted.drive_other_apps", "Drive other apps' screens",
                   "iOS does not let one app tap or read another app's interface. ZORO hands off with links and Shortcuts."),
        restricted("restricted.apple_notes", "Create Apple Notes directly",
                   "Apple has no public Notes API. Make a Shortcut that creates the note and ZORO can run it."),
    ]

    private static func restricted(_ id: String, _ title: String, _ note: String) -> DeviceCapabilityEntry {
        DeviceCapabilityEntry(id: id, title: title, status: .restrictedByIos, note: note, isExecutable: false)
    }

    // MARK: Permission-gated rows

    struct Resolver {
        let environment: DeviceEnvironment
        let permissions: [PermissionKind: PermissionStatus]

        func status(_ kind: PermissionKind) -> PermissionStatus { permissions[kind] ?? .notDetermined }

        /// Maps a permission status to a capability row.
        func gated(
            _ tool: String, _ title: String, _ kind: PermissionKind, _ platforms: Set<DevicePlatform>, ok: String,
            limited: String? = nil, limitedBlocks: Bool = false
        ) -> DeviceCapabilityEntry {
            let s = status(kind)
            var entry = DeviceCapabilityEntry(
                id: tool, title: title, status: .workingNative, note: ok, tool: tool, permission: kind, permissionStatus: s,
                platforms: platforms, isExecutable: true)
            switch s {
            case .granted:
                break
            case .limited:
                entry.note = limited ?? ok
                if limitedBlocks {
                    entry.status = .manualUserStep
                    entry.isExecutable = false
                }
            case .notDetermined:
                entry.note = "\(ok) Asks for \(kind.title) access the first time it is used."
            case .denied:
                entry.status = .manualUserStep
                entry.isExecutable = false
                entry.note = "\(kind.title) access is off. Turn it on for ZORO in Settings."
            case .restricted:
                entry.status = .unavailable
                entry.isExecutable = false
                entry.note = "\(kind.title) is blocked by Screen Time or a device management profile."
            case .unsupported:
                entry.status = .unavailable
                entry.isExecutable = false
                entry.note = "\(kind.title) is not available on this device."
            }
            return entry
        }
    }
}
