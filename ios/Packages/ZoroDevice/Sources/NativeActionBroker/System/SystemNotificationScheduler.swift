#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// `NotificationScheduling` over `UNUserNotificationCenter`. Only touch it inside an app bundle.
public struct SystemNotificationScheduler: NotificationScheduling {
    public init() {}

    private var center: UNUserNotificationCenter { .current() }

    public func permission() async -> DevicePermission {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .limited
        default: return .limited  // ephemeral (App Clips)
        }
    }

    public func requestAccess() async throws -> DevicePermission {
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        return granted ? .authorized : .denied
    }

    public func schedule(_ draft: LocalNotificationDraft) async throws {
        let content = UNMutableNotificationContent()
        content.title = draft.title
        content.body = draft.body
        content.sound = .default
        let trigger: UNNotificationTrigger
        if let at = draft.at {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }
        try await center.add(UNNotificationRequest(identifier: draft.id, content: content, trigger: trigger))
    }
}
#endif
