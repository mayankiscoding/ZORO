import AVFAudio
import Foundation
import Speech
import UserNotifications

/// Reads and requests the shell's permissions from the system. Info.plist needs
/// NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription (sentences in
/// docs/design/voice-and-copy.md section 8). Never used by tests.
public struct SystemPermissionPriming: PermissionPriming {
    public init() {}

    public func status(of permission: AppPermission) async -> PermissionStatus {
        switch permission {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .notDetermined
            @unknown default: return .unavailable
            }
        case .speechRecognition:
            return Self.map(SFSpeechRecognizer.authorizationStatus())
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .authorized, .provisional: return .granted
            default: return .granted
            }
        }
    }

    public func request(_ permission: AppPermission) async -> PermissionStatus {
        guard await status(of: permission) == .notDetermined else { return await status(of: permission) }
        switch permission {
        case .microphone:
            return await AVAudioApplication.requestRecordPermission() ? .granted : .denied
        case .speechRecognition:
            let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            return Self.map(status)
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            return granted ? .granted : .denied
        }
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .unavailable
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }
}
