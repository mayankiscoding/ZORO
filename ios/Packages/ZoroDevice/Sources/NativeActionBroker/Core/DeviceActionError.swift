import Foundation
import ZoroCore

/// A typed failure a handler throws; the broker turns it into a `DeviceActionResult`.
public struct DeviceActionError: Error, Sendable, Equatable {
    public var code: DeviceActionErrorCode
    public var message: String
    public var capabilityStatus: CapabilityStatus?

    public init(_ code: DeviceActionErrorCode, _ message: String, capabilityStatus: CapabilityStatus? = nil) {
        self.code = code
        self.message = message
        self.capabilityStatus = capabilityStatus
    }

    /// Arguments failed validation (`invalid_arguments`); the message names the field.
    public static func invalidArgument(_ name: String, _ reason: String) -> DeviceActionError {
        DeviceActionError(.invalidArguments, "`\(name)` \(reason)")
    }

    public static func permissionDenied(_ what: String) -> DeviceActionError {
        DeviceActionError(
            .permissionDenied, "ZORO has no access to \(what). Allow it in Settings, then try again.",
            capabilityStatus: .manualUserStep)
    }

    public static func unsupported(_ message: String, status: CapabilityStatus = .unavailable) -> DeviceActionError {
        DeviceActionError(.unsupported, message, capabilityStatus: status)
    }

    public static let userCancelled = DeviceActionError(.userCancelled, "The owner cancelled.")

    public static func failed(_ message: String) -> DeviceActionError {
        DeviceActionError(.failed, message)
    }
}

/// System permission state, common to every framework the broker uses.
public enum DevicePermission: String, Sendable, Equatable, CaseIterable {
    case notDetermined = "not_determined"
    case denied, restricted
    /// Calendar write-only access, Photos limited, Contacts limited.
    case limited
    case authorized
}

public enum PermissionGate {
    /// Asks in context the first time (design spec 10), refuses when denied or restricted.
    /// `allowLimited` says whether limited / write-only access is enough for this operation.
    public static func ensure(
        _ what: String, allowLimited: Bool = false,
        status: () async -> DevicePermission, request: () async throws -> DevicePermission
    ) async throws {
        var state = await status()
        if state == .notDetermined {
            do { state = try await request() } catch { throw DeviceActionError.permissionDenied(what) }
        }
        switch state {
        case .authorized: return
        case .limited where allowLimited: return
        case .restricted: throw DeviceActionError(.permissionDenied, "\(what) is restricted on this device.", capabilityStatus: .restrictedByIos)
        default: throw DeviceActionError.permissionDenied(what)
        }
    }
}
