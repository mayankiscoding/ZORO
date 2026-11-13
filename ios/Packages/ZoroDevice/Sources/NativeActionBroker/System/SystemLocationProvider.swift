#if canImport(CoreLocation)
import CoreLocation
import Foundation

/// One-shot location over Core Location. Lives on the main actor because `CLLocationManager` delivers
/// delegate callbacks on the thread that created it.
@MainActor
public final class SystemLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authWaiters: [CheckedContinuation<DevicePermission, Never>] = []
    private let timeout: Duration

    public init(timeout: Duration = .seconds(15)) {
        self.timeout = timeout
        super.init()
        manager.delegate = self
    }

    private static func map(_ status: CLAuthorizationStatus) -> DevicePermission {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .denied
        }
    }

    public func permission() async -> DevicePermission { Self.map(manager.authorizationStatus) }

    public func requestAccess() async throws -> DevicePermission {
        let current = Self.map(manager.authorizationStatus)
        guard current == .notDetermined else { return current }
        // The answer arrives on the main run loop, after this method suspends below.
        manager.requestWhenInUseAuthorization()
        return await withCheckedContinuation { continuation in
            authWaiters.append(continuation)
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let state = Self.map(self.manager.authorizationStatus)
            guard state != .notDetermined else { return }
            let waiters = authWaiters
            authWaiters.removeAll()
            waiters.forEach { $0.resume(returning: state) }
        }
    }

    public func currentLocation() async throws -> LocationFix {
        let timeout = self.timeout
        let coordinate: (Double, Double, Double)? = try await withThrowingTaskGroup(of: (Double, Double, Double)?.self) { group in
            group.addTask {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let l = update.location, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 1000 {
                        return (l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy)
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let (lat, lon, accuracy) = coordinate else {
            throw DeviceActionError.failed("Could not get a location fix in time. Try again outdoors or with Wi-Fi on.")
        }
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon))
        return LocationFix(latitude: lat, longitude: lon, accuracyMeters: accuracy, locality: placemarks?.first?.locality)
    }
}
#endif
