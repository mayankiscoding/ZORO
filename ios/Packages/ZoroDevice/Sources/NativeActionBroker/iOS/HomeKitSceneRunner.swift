// UNVERIFIED-ON-HOST
// HomeKit: HMHomeManager.authorizationStatus (iOS 13+, HMHomeManagerAuthorizationStatus option set),
// HMHomeManagerDelegate.homeManagerDidUpdateHomes(_:), HMHome.actionSets, HMHome.executeActionSet(_:) async throws.
// The app needs the HomeKit capability and NSHomeKitUsageDescription.
#if os(iOS) && canImport(HomeKit)
import Foundation
import HomeKit

/// Runs a HomeKit scene (action set) by name.
@MainActor
public final class HomeKitSceneRunner: NSObject, HomeSceneRunning, HMHomeManagerDelegate {
    private var manager: HMHomeManager?
    private var loaded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public override init() { super.init() }

    private static func map(_ status: HMHomeManagerAuthorizationStatus) -> DevicePermission {
        if status.contains(.authorized) { return .authorized }
        if status.contains(.restricted) { return .restricted }
        return status.contains(.determined) ? .denied : .notDetermined
    }

    public func permission() async -> DevicePermission {
        guard let manager else { return .notDetermined }
        return Self.map(manager.authorizationStatus)
    }

    public func requestAccess() async throws -> DevicePermission {
        await loadHomes()
        return await permission()
    }

    private func loadHomes() async {
        if manager == nil {
            let m = HMHomeManager()
            m.delegate = self
            manager = m
        }
        guard !loaded, let manager else { return }
        let status = manager.authorizationStatus
        if status.contains(.determined), !status.contains(.authorized) { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Denial also ends the wait (homes never load without access).
    nonisolated public func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        guard status.contains(.determined), !status.contains(.authorized) else { return }
        homeManagerDidUpdateHomes(manager)
    }

    /// HomeKit does not document the queue it calls the delegate on, so hop to the main actor instead of
    /// asserting it (`MainActor.assumeIsolated` would trap off the main thread).
    nonisolated public func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.finishLoading() }
    }

    private func finishLoading() {
        loaded = true
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume() }
    }

    public func runScene(named name: String) async throws -> Bool {
        await loadHomes()
        guard let manager else { return false }
        for home in manager.homes {
            if let scene = home.actionSets.first(where: {
                $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                try await home.executeActionSet(scene)
                return true
            }
        }
        return false
    }
}
#endif
