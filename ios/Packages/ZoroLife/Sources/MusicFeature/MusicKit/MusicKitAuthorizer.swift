#if canImport(MusicKit)
import MusicKit
import ZoroCore

/// Shows the system Apple Music access sheet (`MusicAuthorization.request()`). The sheet appears only when the owner taps
/// "Allow Apple Music"; the Info.plist needs `NSAppleMusicUsageDescription`.
public struct MusicKitAuthorizer: MusicAuthorizing {
    public init() {}

    public func requestAuthorization() async -> MediaAuthorization {
        switch await MusicAuthorization.request() {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
}
#endif
