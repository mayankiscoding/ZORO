import Foundation
import ZoroCore

public enum CalendarEntity: String, Sendable { case event, reminder }

public struct ReminderDraft: Sendable, Equatable {
    public var title: String
    public var dueAt: Date?
    public var notes: String?
    public var listName: String?
}

public struct EventDraft: Sendable, Equatable {
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var location: String?
    public var notes: String?
    public var calendarName: String?
}

public struct CalendarEventInfo: Sendable, Equatable {
    public var id: String
    public var title: String
    public var startAt: Date
    public var endAt: Date
    public var location: String?
    public var calendar: String
    public init(id: String, title: String, startAt: Date, endAt: Date, location: String?, calendar: String) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.location = location
        self.calendar = calendar
    }
}

/// EventKit, behind a protocol.
public protocol CalendarStoring: Sendable {
    func permission(for entity: CalendarEntity) async -> DevicePermission
    func requestAccess(to entity: CalendarEntity) async throws -> DevicePermission
    /// Returns the new reminder's identifier. Throws `DeviceActionError` when `listName` does not exist.
    func createReminder(_ draft: ReminderDraft) async throws -> String
    func createEvent(_ draft: EventDraft) async throws -> String
    func events(from: Date, to: Date, limit: Int) async throws -> [CalendarEventInfo]
}

/// `device.reminder.create`, `device.calendar.create_event`, `device.calendar.upcoming`.
public struct CalendarHandler: DeviceActionHandler {
    let store: any CalendarStoring
    let timeZone: TimeZone
    let now: @Sendable () -> Date

    public init(store: any CalendarStoring, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.timeZone = timeZone
        self.now = now
    }

    public var tools: [DeviceToolName] { [.reminderCreate, .calendarCreateEvent, .calendarUpcoming] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let store = self.store
        switch tool {
        case .reminderCreate:
            let draft = ReminderDraft(
                title: try args.requiredString("title", maxLength: 500), dueAt: try args.date("due_at"),
                notes: try args.string("notes", maxLength: 4000), listName: try args.string("list_name", maxLength: 200))
            return PreparedDeviceAction(summary: "Add the reminder “\(draft.title)”.") {
                try await PermissionGate.ensure(
                    "Reminders", status: { await store.permission(for: .reminder) },
                    request: { try await store.requestAccess(to: .reminder) })
                return ["id": .string(try await store.createReminder(draft))]
            }
        case .calendarCreateEvent:
            let start = try args.requiredDate("start_at")
            let end = try args.date("end_at") ?? start.addingTimeInterval(3600)
            guard end > start else { throw DeviceActionError.invalidArgument("end_at", "must be after start_at") }
            guard end.timeIntervalSince(start) <= 31 * 86400 else {
                throw DeviceActionError.invalidArgument("end_at", "must be within 31 days of start_at")
            }
            let draft = EventDraft(
                title: try args.requiredString("title", maxLength: 500), startAt: start, endAt: end,
                location: try args.string("location", maxLength: 500), notes: try args.string("notes", maxLength: 4000),
                calendarName: try args.string("calendar_name", maxLength: 200))
            return PreparedDeviceAction(summary: "Add “\(draft.title)” to your calendar.") {
                try await PermissionGate.ensure(
                    "Calendar", allowLimited: draft.calendarName == nil, status: { await store.permission(for: .event) },
                    request: { try await store.requestAccess(to: .event) })
                return ["id": .string(try await store.createEvent(draft))]
            }
        case .calendarUpcoming:
            let from = try args.date("from") ?? now()
            let to = try args.date("to") ?? from.addingTimeInterval(7 * 86400)
            guard to > from else { throw DeviceActionError.invalidArgument("to", "must be after from") }
            guard to.timeIntervalSince(from) <= 366 * 86400 else {
                throw DeviceActionError.invalidArgument("to", "must be within a year of from")
            }
            let limit = try args.int("limit", range: 1...50) ?? 5
            let tz = timeZone
            return PreparedDeviceAction(summary: "Read your upcoming events.") {
                try await PermissionGate.ensure(
                    "Calendar", status: { await store.permission(for: .event) },
                    request: { try await store.requestAccess(to: .event) })
                let events = try await store.events(from: from, to: to, limit: limit)
                    .sorted { $0.startAt < $1.startAt }.prefix(limit)
                return [
                    "events": .array(events.map { e in
                        var o: JSONObject = [
                            "id": .string(e.id), "title": .string(e.title),
                            "start_at": .string(DeviceTime.iso(e.startAt, timeZone: tz)),
                            "end_at": .string(DeviceTime.iso(e.endAt, timeZone: tz)), "calendar": .string(e.calendar),
                        ]
                        if let l = e.location { o["location"] = .string(l) }
                        return .object(o)
                    })
                ]
            }
        default:
            throw DeviceActionError.unsupported("\(tool.rawValue) is not a calendar tool.")
        }
    }
}
