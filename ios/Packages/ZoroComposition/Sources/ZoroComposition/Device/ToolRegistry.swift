import Foundation
import PermissionManager
import ZoroCore

/// PermissionManager's capability registry under a name that does not clash with SystemFeatures'
/// `DeviceCapabilityRegistry` protocol (files importing both modules use this alias).
public typealias DeviceToolRegistry = DeviceCapabilityRegistry

extension DeviceCapabilityRegistry {
    /// The tools announced in the channel hello: what the registry says is executable with the current
    /// permissions, limited to the tools a handler is actually registered for on this device.
    public func helloTools(permissions: [PermissionKind: PermissionStatus], registered: [String]) -> [String] {
        let have = Set(registered)
        return supportedTools(permissions: permissions).filter { have.contains($0) }
    }
}
