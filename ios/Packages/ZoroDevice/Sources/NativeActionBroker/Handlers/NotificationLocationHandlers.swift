import Foundation
import ZoroCore

// MARK: - Notifications

public struct LocalNotificationDraft: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
    /// nil = deliver now.
    public var at: Date?
}

/// UserNotifications, behind a protocol.
public protocol NotificationScheduling: Sendable {
    func permission() async -> DevicePermission
    func requestAccess() async throws -> DevicePermission
    func schedule(_ draft: LocalNotificationDraft) async throws
}

/// `device.notification.schedule`.
public struct NotificationHandler: DeviceActionHandler {
    let scheduler: any NotificationScheduling
    let now: @Sendable () -> Date
    let makeId: @Sendable () -> String

    public init(
        scheduler: any NotificationScheduling, now: @escaping @Sendable () -> Date = { Date() },
        makeId: @escaping @Sendable () -> String = { "zoro-" + UUID().uuidString.lowercased() }
    ) {
        self.scheduler = scheduler
        self.now = now
        self.makeId = makeId
    }

    public var tools: [DeviceToolName] { [.notificationSchedule] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let at = try args.date("at")
        if let at {
            guard at > now() else { throw DeviceActionError.invalidArgument("at", "is in the past") }
            guard at.timeIntervalSince(now()) <= 366 * 86400 else {
                throw DeviceActionError.invalidArgument("at", "is more than a year away")
            }
        }
        let draft = LocalNotificationDraft(
            id: makeId(), title: try args.requiredString("title", maxLength: 200),
            body: try args.requiredString("body", maxLength: 2000), at: at)
        let scheduler = self.scheduler
        return PreparedDeviceAction(summary: "Send you a notification: “\(draft.title)”.") {
            try await PermissionGate.ensure(
                "notifications", allowLimited: true, status: { await scheduler.permission() },
                request: { try await scheduler.requestAccess() })
            try await scheduler.schedule(draft)
            return ["id": .string(draft.id)]
        }
    }
}

// MARK: - Location

public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Double
    public var locality: String?
    public init(latitude: Double, longitude: Double, accuracyMeters: Double, locality: String?) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.locality = locality
    }
}

/// Core Location one-shot fix, behind a protocol.
public protocol LocationProviding: Sendable {
    func permission() async -> DevicePermission
    func requestAccess() async throws -> DevicePermission
    /// One fix; throws `DeviceActionError` on timeout.
    func currentLocation() async throws -> LocationFix
}

/// `device.location.current`.
public struct LocationHandler: DeviceActionHandler {
    let provider: any LocationProviding
    public init(provider: any LocationProviding) { self.provider = provider }

    public var tools: [DeviceToolName] { [.locationCurrent] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let provider = self.provider
        return PreparedDeviceAction(summary: "Share where you are now.") {
            try await PermissionGate.ensure(
                "your location", status: { await provider.permission() }, request: { try await provider.requestAccess() })
            let fix = try await provider.currentLocation()
            guard (-90...90).contains(fix.latitude), (-180...180).contains(fix.longitude), fix.accuracyMeters >= 0 else {
                throw DeviceActionError.failed("The location fix was not valid.")
            }
            var out: JSONObject = [
                "place_ref": .string(Self.placeRef(fix)), "latitude": .number(fix.latitude),
                "longitude": .number(fix.longitude), "accuracy_m": .number(fix.accuracyMeters.rounded()),
            ]
            if let locality = fix.locality { out["locality"] = .string(locality) }
            return out
        }
    }

    /// A `geo:` URI (RFC 5870) with 5 decimals (about 1 m) and the uncertainty in metres.
    static func placeRef(_ fix: LocationFix) -> String {
        String(format: "geo:%.5f,%.5f;u=%.0f", fix.latitude, fix.longitude, fix.accuracyMeters)
    }
}
