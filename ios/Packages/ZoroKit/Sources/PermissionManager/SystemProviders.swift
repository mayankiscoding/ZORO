import Foundation
import ZoroCore

#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(Contacts)
import Contacts
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(MusicKit)
import MusicKit
#endif
#if canImport(HealthKit)
import HealthKit
#endif

// Every type here is a thin wrapper over one framework call. Unit tests never construct them: the
// logic is tested through `PermissionCenter` with in-memory fakes, so no permission sheet can appear.

/// A permission this device or OS cannot have (for example alarms on Mac).
public struct UnsupportedPermissionProvider: PermissionProviding {
    public let kind: PermissionKind
    public init(_ kind: PermissionKind) { self.kind = kind }
    public func status() async -> PermissionStatus { .unsupported }
    public func request() async -> PermissionStatus { .unsupported }
}

/// The providers for the current platform: one per `PermissionKind`.
public enum SystemPermissionProviders {
    public static func all() -> [any PermissionProviding] {
        [
            MicrophonePermissionProvider(),
            SpeechRecognitionPermissionProvider(),
            PhotosPermissionProvider(),
            HealthPermissionProvider(),
            ContactsPermissionProvider(),
            CalendarPermissionProvider(),
            RemindersPermissionProvider(),
            NotificationsPermissionProvider(),
            LocationPermissionProvider(),
            MusicPermissionProvider(),
            makeAlarmPermissionProvider(),
        ]
    }
}

// MARK: - Microphone

public struct MicrophonePermissionProvider: PermissionProviding {
    public var kind: PermissionKind { .microphone }
    public init() {}

    public func status() async -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    public func request() async -> PermissionStatus {
        guard await status() == .notDetermined else { return await status() }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return await status()
    }
}

// MARK: - Speech recognition

public struct SpeechRecognitionPermissionProvider: PermissionProviding {
    public var kind: PermissionKind { .speechRecognition }
    public init() {}

    public func status() async -> PermissionStatus {
        Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    public func request() async -> PermissionStatus {
        guard await status() == .notDetermined else { return await status() }
        let result: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return Self.map(result)
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }
}

// MARK: - Photos

public struct PhotosPermissionProvider: PermissionProviding {
    public var kind: PermissionKind { .photos }
    public init() {}

    public func status() async -> PermissionStatus {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func request() async -> PermissionStatus {
        guard await status() == .notDetermined else { return await status() }
        return Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func map(_ status: PHAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .limited: .limited
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }
}

// MARK: - Contacts

public struct ContactsPermissionProvider: PermissionProviding {
    public var kind: PermissionKind { .contacts }
    public init() {}

    public func status() async -> PermissionStatus {
        Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    public func request() async -> PermissionStatus {
        guard await status() == .notDetermined else { return await status() }
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        return await status()
    }

    static func map(_ status: CNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .limited: .limited
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }
}

// MARK: - Calendar and Reminders (EventKit)

enum EventKitMapping {
    static func map(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess: .granted
        case .writeOnly: .limited
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .granted
        @unknown default: .denied
        }
    }
}

public struct CalendarPermissionProvider: PermissionProviding {
    public var kind: PermissionKind { .calendars }
    public init() {}

    public func status() async -> PermissionStatus {
        EventKitMapping.map(EKEventStore.authorizationStatus(for: .event))
    }

    public func request() async -> PermissionStatus {
        guard await status() == .notDetermined else { return await status() }
        _ = try? await EKEventStore().requestFullAccessToEvents()
        return await status()
    }
}

public struct RemindersPermissionProvider: PermissionProviding {
    public var kind: PermissionKind { .reminders }
    public init() {}

    public func status() async -> PermissionStatus {
        EventKitMapping.map(EKEventStore.authorizationStatus(for: .reminder))
    }

    public func request() async -> PermissionStatus {
        guard await status() == .notDetermined else { return await status() }
        _ = try? await EKEventStore().requestFullAccessToReminders()
        return await status()
    }
}

// MARK: - Notifications

public struct NotificationsPermissionProvider: PermissionProviding {
    public var kind: PermissionKind { .notifications }
    public init() {}

    public func status() async -> PermissionStatus {
        // `current()` is resolved lazily: it traps in a process that is not an app bundle.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    public func request() async -> PermissionStatus {
        guard await status() == .notDetermined else { return await status() }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await status()
    }

    static func map(_ status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .provisional, .ephemeral: .limited
        case .notDetermined: .notDetermined
        case .denied: .denied
        @unknown default: .denied
        }
    }
}

// MARK: - Location

public struct LocationPermissionProvider: PermissionProviding {
    public var kind: PermissionKind { .location }
    public init() {}

    public func status() async -> PermissionStatus {
        await MainActor.run { Self.map(CLLocationManager().authorizationStatus) }
    }

    public func request() async -> PermissionStatus {
        guard await status() == .notDetermined else { return await status() }
        let requester = await MainActor.run { LocationAuthorizationRequester() }
        let result = await requester.requestWhenInUse()
        return Self.map(result)
    }

    static func map(_ status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }
}

/// Owns a `CLLocationManager` for the duration of one when-in-use request and waits for the answer.
@MainActor
final class LocationAuthorizationRequester: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    func requestWhenInUse() async -> CLAuthorizationStatus {
        manager.delegate = self
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        Task { @MainActor in
            self.continuation?.resume(returning: status)
            self.continuation = nil
        }
    }
}

// MARK: - Music (MusicKit)

public struct MusicPermissionProvider: PermissionProviding {
    public var kind: PermissionKind { .music }
    public init() {}

    public func status() async -> PermissionStatus {
        Self.map(MusicAuthorization.currentStatus)
    }

    public func request() async -> PermissionStatus {
        guard await status() == .notDetermined else { return await status() }
        return Self.map(await MusicAuthorization.request())
    }

    static func map(_ status: MusicAuthorization.Status) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }
}

// MARK: - Health (HealthKit)

/// HealthKit never says whether read access was granted. `granted` here means "the sheet has been
/// answered for these types"; a denied type simply returns no samples, and ZORO reports "no data".
public struct HealthPermissionProvider: PermissionProviding {
    public var kind: PermissionKind { .health }
    public init() {}

    static func readTypes() -> Set<HKObjectType> {
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .distanceWalkingRunning, .distanceCycling, .activeEnergyBurned,
            .appleExerciseTime, .restingHeartRate, .heartRate, .bodyMass,
        ]
        var types = Set<HKObjectType>(quantities.compactMap { HKObjectType.quantityType(forIdentifier: $0) })
        for id in [HKCategoryTypeIdentifier.sleepAnalysis, .appleStandHour] {
            if let type = HKObjectType.categoryType(forIdentifier: id) { types.insert(type) }
        }
        types.insert(HKObjectType.workoutType())
        return types
    }

    public func status() async -> PermissionStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .unsupported }
        let store = HKHealthStore()
        guard let requestStatus = try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes()) else {
            return .notDetermined
        }
        switch requestStatus {
        case .shouldRequest: return .notDetermined
        case .unnecessary: return .granted
        case .unknown: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func request() async -> PermissionStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .unsupported }
        guard await status() == .notDetermined else { return await status() }
        try? await HKHealthStore().requestAuthorization(toShare: [], read: Self.readTypes())
        return await status()
    }
}

// MARK: - Alarms (AlarmKit is iOS 26+, see iOS/AlarmKitPermissionProvider.swift)

#if !os(iOS)
func makeAlarmPermissionProvider() -> any PermissionProviding { UnsupportedPermissionProvider(.alarms) }
#endif
