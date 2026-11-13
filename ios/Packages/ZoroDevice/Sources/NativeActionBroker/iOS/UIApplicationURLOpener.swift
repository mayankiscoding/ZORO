// UNVERIFIED-ON-HOST
#if os(iOS) && canImport(UIKit)
import UIKit

/// Opens URLs with `UIApplication.open(_:options:) async -> Bool` (iOS 10+). `UIApplication` is main-actor
/// isolated, so the call runs there (an isolated async witness satisfies the nonisolated async requirement)
/// instead of moving the non-Sendable `UIApplication` and options dictionary across actors.
public struct UIApplicationURLOpener: URLOpening {
    public init() {}
    @MainActor
    public func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url, options: [:])
    }
}
#endif
