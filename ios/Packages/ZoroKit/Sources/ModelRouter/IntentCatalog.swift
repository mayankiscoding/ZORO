import Foundation

/// The commands the device can understand and run on its own. Names are stable identifiers.
public enum LocalIntentName {
    public static let alarm = "alarm.create"
    public static let timer = "timer.start"
    public static let reminder = "reminder.create"
    public static let calendarLookup = "calendar.upcoming"
    public static let musicControl = "music.control"
    public static let photoSearch = "photos.search"
    public static let openSection = "app.open_section"

    public static let all = [alarm, timer, reminder, calendarLookup, musicControl, photoSearch, openSection]
}

/// Device tool each local intent runs (`docs/architecture/device-contract.md`); nil for UI-only intents.
public enum LocalIntentTools {
    public static func tool(for intent: String) -> String? {
        switch intent {
        case LocalIntentName.alarm: "ios.alarm.create"
        case LocalIntentName.timer: "ios.timer.start"
        case LocalIntentName.reminder: "device.reminder.create"
        case LocalIntentName.calendarLookup: "device.calendar.upcoming"
        case LocalIntentName.musicControl: "device.music.control"
        case LocalIntentName.photoSearch: "device.photos.search"
        default: nil
        }
    }

    /// Whether only the device can do this: the backend would have to send the same device action back.
    /// Photo search is also private by construction (images never leave the device).
    public static func isDeviceOnly(_ intent: String) -> Bool {
        switch intent {
        case LocalIntentName.alarm, LocalIntentName.timer, LocalIntentName.musicControl, LocalIntentName.photoSearch,
             LocalIntentName.openSection:
            true
        default:
            false
        }
    }
}

/// App sections the owner can ask to open by voice. Raw values are the ids sent in the `section` slot.
public enum AppSectionID: String, Sendable, CaseIterable {
    case shopping, finance, investments, fitness, photos, music, memory, integrations
    case deviceControl = "device_control"
    case security, settings, history, activity
}
