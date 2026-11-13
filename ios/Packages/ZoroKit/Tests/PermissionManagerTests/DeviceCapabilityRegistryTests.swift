import Testing
import ZoroCore
@testable import PermissionManager

@Suite struct DeviceCapabilityRegistryTests {
    static let contractTools = [
        "device.reminder.create", "device.calendar.create_event", "device.calendar.upcoming", "device.contacts.find",
        "device.contacts.save", "device.notification.schedule", "device.location.current", "device.open_url",
        "device.shortcut.run", "device.music.control", "device.photos.search", "device.health.query",
        "device.whatsapp.compose", "ios.alarm.create", "ios.timer.start", "ios.message.compose", "ios.home.run_scene",
        "mac.applescript.run", "mac.file.search", "mac.file.open",
    ]

    static func iPhone(os: Int = 26, health: Bool = true, text: Bool = true, home: Bool = false, model: Bool = false) -> DeviceCapabilityRegistry {
        DeviceCapabilityRegistry(environment: DeviceEnvironment(
            platform: .ios, osMajorVersion: os, healthDataAvailable: health, canComposeMessages: text,
            homeKitScenesEnabled: home, onDeviceLanguageModelAvailable: model))
    }
    static func mac(os: Int = 26) -> DeviceCapabilityRegistry {
        DeviceCapabilityRegistry(environment: DeviceEnvironment(platform: .macos, osMajorVersion: os))
    }
    static func allGranted() -> [PermissionKind: PermissionStatus] {
        Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, PermissionStatus.granted) })
    }
    static func entry(_ id: String, _ list: [DeviceCapabilityEntry]) -> DeviceCapabilityEntry {
        list.first { $0.id == id }!
    }

    @Test func listsEveryContractToolExactlyOnce() {
        for registry in [Self.iPhone(), Self.mac()] {
            let tools = registry.entries(permissions: [:]).compactMap(\.tool)
            #expect(Set(tools) == Set(Self.contractTools))
            #expect(tools.count == Self.contractTools.count)
        }
    }

    @Test func idsAreUniqueAndEveryRowHasATitleAndNote() {
        let rows = Self.iPhone().entries(permissions: [:])
        #expect(Set(rows.map(\.id)).count == rows.count)
        for row in rows {
            #expect(!row.title.isEmpty)
            #expect(!row.note.isEmpty)
        }
    }

    @Test func notAvailableEntriesAreRestrictedByIos() {
        let rows = Self.iPhone().entries(permissions: [:]).filter { $0.id.hasPrefix("restricted.") }
        #expect(rows.count == 6)
        #expect(rows.allSatisfy { $0.status == .restrictedByIos && !$0.isExecutable && $0.tool == nil })
    }

    // MARK: Permission status on iPhone

    @Test(arguments: [
        (PermissionStatus.granted, CapabilityStatus.workingNative, true),
        (.limited, .workingNative, true),
        (.notDetermined, .workingNative, true),
        (.denied, .manualUserStep, false),
        (.restricted, .unavailable, false),
        (.unsupported, .unavailable, false),
    ])
    func photoSearchFollowsPhotoPermission(status: PermissionStatus, expected: CapabilityStatus, executable: Bool) {
        let rows = Self.iPhone().entries(permissions: [.photos: status])
        let row = Self.entry("device.photos.search", rows)
        #expect(row.status == expected)
        #expect(row.isExecutable == executable)
        #expect(row.permission == .photos)
        #expect(row.permissionStatus == status)
    }

    @Test func limitedPhotosSaysSo() {
        let row = Self.entry("device.photos.search", Self.iPhone().entries(permissions: [.photos: .limited]))
        #expect(row.note.contains("Limited library"))
    }

    @Test func deniedNoteSendsOwnerToSettings() {
        let row = Self.entry("device.reminder.create", Self.iPhone().entries(permissions: [.reminders: .denied]))
        #expect(row.note.contains("Settings"))
    }

    @Test func notDeterminedNoteSaysItAsksInContext() {
        let row = Self.entry("device.location.current", Self.iPhone().entries(permissions: [:]))
        #expect(row.status == .workingNative)
        #expect(row.note.contains("first time"))
    }

    @Test func writeOnlyCalendarCanAddButNotRead() {
        let rows = Self.iPhone().entries(permissions: [.calendars: .limited])
        #expect(Self.entry("device.calendar.create_event", rows).isExecutable)
        let read = Self.entry("device.calendar.upcoming", rows)
        #expect(!read.isExecutable)
        #expect(read.status == .manualUserStep)
    }

    @Test func eachToolFollowsItsOwnPermission() {
        var permissions = Self.allGranted()
        permissions[.contacts] = .denied
        let rows = Self.iPhone().entries(permissions: permissions)
        #expect(!Self.entry("device.contacts.find", rows).isExecutable)
        #expect(!Self.entry("device.contacts.save", rows).isExecutable)
        #expect(Self.entry("device.reminder.create", rows).isExecutable)
        #expect(Self.entry("device.music.control", rows).isExecutable)
    }

    // MARK: OS version and platform

    @Test func alarmsNeedIOS26() {
        let old = Self.iPhone(os: 18).entries(permissions: Self.allGranted())
        let alarm = Self.entry("ios.alarm.create", old)
        #expect(alarm.status == .unavailable)
        #expect(alarm.note.contains("iOS 26"))
        #expect(!Self.entry("ios.timer.start", old).isExecutable)

        let current = Self.iPhone(os: 26).entries(permissions: Self.allGranted())
        #expect(Self.entry("ios.alarm.create", current).status == .workingNative)
        #expect(Self.entry("ios.timer.start", current).isExecutable)
    }

    @Test func alarmsFollowAlarmPermissionOnIOS26() {
        let denied = Self.iPhone().entries(permissions: [.alarms: .denied])
        #expect(Self.entry("ios.alarm.create", denied).status == .manualUserStep)
        let asks = Self.iPhone().entries(permissions: [:])
        #expect(Self.entry("ios.alarm.create", asks).isExecutable)
    }

    @Test func macRunsMacToolsOnly() {
        let rows = Self.mac().entries(permissions: Self.allGranted())
        for id in ["mac.applescript.run", "mac.file.search", "mac.file.open"] {
            #expect(Self.entry(id, rows).status == .workingNative)
            #expect(Self.entry(id, rows).isExecutable)
        }
        for id in ["ios.alarm.create", "ios.timer.start", "ios.message.compose", "ios.home.run_scene", "device.health.query"] {
            #expect(Self.entry(id, rows).status == .unavailable)
            #expect(!Self.entry(id, rows).isExecutable)
        }
    }

    @Test func iPhoneDoesNotRunMacTools() {
        let rows = Self.iPhone().entries(permissions: Self.allGranted())
        for id in ["mac.applescript.run", "mac.file.search", "mac.file.open"] {
            #expect(Self.entry(id, rows).status == .unavailable)
            #expect(!Self.entry(id, rows).isExecutable)
        }
    }

    @Test func healthNeedsHealthKitAndAnIPhone() {
        let ok = Self.entry("device.health.query", Self.iPhone().entries(permissions: [.health: .granted]))
        #expect(ok.status == .workingNative)
        let noHealthKit = Self.entry("device.health.query", Self.iPhone(health: false).entries(permissions: [.health: .granted]))
        #expect(noHealthKit.status == .unavailable)
        let unsupported = Self.entry("device.health.query", Self.iPhone().entries(permissions: [.health: .unsupported]))
        #expect(!unsupported.isExecutable)
        let mac = Self.entry("device.health.query", Self.mac().entries(permissions: [.health: .granted]))
        #expect(mac.status == .unavailable)
        #expect(mac.note.contains("iPhone"))
    }

    @Test func messageComposerNeedsTextCapableDevice() {
        let yes = Self.entry("ios.message.compose", Self.iPhone(text: true).entries(permissions: [:]))
        #expect(yes.status == .manualUserStep && yes.isExecutable)
        let no = Self.entry("ios.message.compose", Self.iPhone(text: false).entries(permissions: [:]))
        #expect(no.status == .unavailable && !no.isExecutable)
    }

    @Test func homeScenesAreHonestlyUnavailableUntilWired() {
        let off = Self.entry("ios.home.run_scene", Self.iPhone(home: false).entries(permissions: [:]))
        #expect(off.status == .unavailable)
        let on = Self.entry("ios.home.run_scene", Self.iPhone(home: true).entries(permissions: [:]))
        #expect(on.status == .workingNative)
    }

    @Test func whatsappIsAHandoffNotASilentSend() {
        for registry in [Self.iPhone(), Self.mac()] {
            let row = Self.entry("device.whatsapp.compose", registry.entries(permissions: [:]))
            #expect(row.status == .manualUserStep)
            #expect(row.note.contains("tap send"))
        }
    }

    @Test func toolsWithoutPermissionAlwaysWork() {
        let rows = Self.iPhone().entries(permissions: PermissionKind.allCases.reduce(into: [:]) { $0[$1] = PermissionStatus.denied })
        #expect(Self.entry("device.open_url", rows).isExecutable)
        #expect(Self.entry("device.shortcut.run", rows).isExecutable)
    }

    // MARK: Hello and Integrations output

    @Test func supportedToolsExcludeBlockedOnes() {
        var permissions = Self.allGranted()
        permissions[.photos] = .denied
        let tools = Self.iPhone().supportedTools(permissions: permissions)
        #expect(!tools.contains("device.photos.search"))
        #expect(tools.contains("device.reminder.create"))
        #expect(tools.contains("ios.alarm.create"))
        #expect(!tools.contains { $0.hasPrefix("mac.") })
        #expect(Set(tools).count == tools.count)
    }

    @Test func macSupportedToolsHaveNoIosPrefix() {
        let tools = Self.mac().supportedTools(permissions: Self.allGranted())
        #expect(!tools.contains { $0.hasPrefix("ios.") })
        #expect(tools.contains("mac.file.open"))
        #expect(!tools.contains("device.health.query"))
    }

    @Test func capabilitiesForIntegrationsScreenFilterByPlatform() {
        let mac = Self.mac().capabilities(permissions: [:])
        #expect(!mac.contains { $0.id == "ios.alarm.create" })
        #expect(mac.contains { $0.id == "mac.file.open" })
        #expect(mac.allSatisfy { $0.domain == "device" })
        let phone = Self.iPhone().capabilities(permissions: [:])
        #expect(!phone.contains { $0.id == "mac.file.open" })
        let photos = phone.first { $0.id == "device.photos.search" }
        #expect(photos?.requires == ["photos"])
    }

    @Test func capabilityRoundTripsThroughTheContractCoding() throws {
        let capability = Self.entry("device.photos.search", Self.iPhone().entries(permissions: [.photos: .granted])).capability
        let data = try ZoroJSON.encoder().encode(capability)
        let back = try ZoroJSON.decoder().decode(Capability.self, from: data)
        #expect(back == capability)
    }

    @Test func voiceInputCombinesMicrophoneAndSpeech() {
        let granted = Self.entry("local.voice_input", Self.iPhone().entries(permissions: [.microphone: .granted, .speechRecognition: .granted]))
        #expect(granted.status == .workingNative && granted.isExecutable)
        let denied = Self.entry("local.voice_input", Self.iPhone().entries(permissions: [.microphone: .granted, .speechRecognition: .denied]))
        #expect(denied.status == .manualUserStep && !denied.isExecutable)
        let restricted = Self.entry("local.voice_input", Self.iPhone().entries(permissions: [.microphone: .restricted, .speechRecognition: .granted]))
        #expect(restricted.status == .unavailable)
    }

    @Test func appleModelEntryFollowsAvailability() {
        let yes = Self.entry("local.apple_model", Self.iPhone(model: true).entries(permissions: [:]))
        #expect(yes.status == .workingLocal && yes.note.contains("English"))
        let no = Self.entry("local.apple_model", Self.iPhone(model: false).entries(permissions: [:]))
        #expect(no.status == .unavailable)
    }

    @Test func currentEnvironmentReadsThisHost() {
        let env = DeviceEnvironment.current()
        #if os(macOS)
        #expect(env.platform == .macos)
        #endif
        #expect(env.osMajorVersion >= 15)
    }
}
