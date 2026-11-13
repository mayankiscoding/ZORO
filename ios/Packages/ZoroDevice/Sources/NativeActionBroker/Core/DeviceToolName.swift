import Foundation
import ZoroCore

/// Every tool in `docs/architecture/device-contract.md`.
public enum DeviceToolName: String, CaseIterable, Sendable {
    case reminderCreate = "device.reminder.create"
    case calendarCreateEvent = "device.calendar.create_event"
    case calendarUpcoming = "device.calendar.upcoming"
    case contactsFind = "device.contacts.find"
    case contactsSave = "device.contacts.save"
    case notificationSchedule = "device.notification.schedule"
    case locationCurrent = "device.location.current"
    case openURL = "device.open_url"
    case shortcutRun = "device.shortcut.run"
    case musicControl = "device.music.control"
    case photosSearch = "device.photos.search"
    case healthQuery = "device.health.query"
    case whatsappCompose = "device.whatsapp.compose"
    case alarmCreate = "ios.alarm.create"
    case timerStart = "ios.timer.start"
    case messageCompose = "ios.message.compose"
    case homeRunScene = "ios.home.run_scene"
    case appleScriptRun = "mac.applescript.run"
    case fileSearch = "mac.file.search"
    case fileOpen = "mac.file.open"

    /// Which platforms may run the tool, from its prefix.
    public var platforms: Set<DevicePlatform> {
        if rawValue.hasPrefix("ios.") { return [.ios] }
        if rawValue.hasPrefix("mac.") { return [.macos] }
        return [.ios, .macos]
    }
}

extension DevicePlatform {
    /// The platform this binary runs on.
    public static var running: DevicePlatform {
        #if os(macOS)
        return .macos
        #else
        return .ios
        #endif
    }
}
