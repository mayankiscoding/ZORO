// UNVERIFIED-ON-HOST
// AlarmKit exists only in the iOS 26 SDK (AlarmManager: iOS 26.0+, iPadOS 26.0+, Mac Catalyst 26.0+; not native
// macOS). Checked against developer.apple.com/documentation/alarmkit/alarmmanager:
//   AlarmManager.shared, authorizationState, requestAuthorization() async throws -> AuthorizationState,
//   AuthorizationState = .notDetermined | .authorized | .denied.
// Info.plist needs NSAlarmKitUsageDescription (the app shell owns Info.plist).
#if os(iOS)
import Foundation

#if canImport(AlarmKit) && compiler(>=6.2)
import AlarmKit

@available(iOS 26.0, *)
struct AlarmKitPermissionProvider: PermissionProviding {
    var kind: PermissionKind { .alarms }

    func status() async -> PermissionStatus { Self.map(AlarmManager.shared.authorizationState) }

    func request() async -> PermissionStatus {
        guard await status() == .notDetermined else { return await status() }
        if let state = try? await AlarmManager.shared.requestAuthorization() { return Self.map(state) }
        return await status()
    }

    static func map(_ state: AlarmManager.AuthorizationState) -> PermissionStatus {
        switch state {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        @unknown default: .denied
        }
    }
}

func makeAlarmPermissionProvider() -> any PermissionProviding {
    if #available(iOS 26.0, *) { return AlarmKitPermissionProvider() }
    return UnsupportedPermissionProvider(.alarms)
}
#else
func makeAlarmPermissionProvider() -> any PermissionProviding { UnsupportedPermissionProvider(.alarms) }
#endif
#endif
