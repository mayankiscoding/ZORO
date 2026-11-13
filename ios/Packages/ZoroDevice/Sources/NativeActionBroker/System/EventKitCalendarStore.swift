#if canImport(EventKit)
import EventKit
import Foundation

/// `CalendarStoring` over EventKit. The store object lives inside this actor.
public actor EventKitCalendarStore: CalendarStoring {
    private let store = EKEventStore()

    public init() {}

    nonisolated private func entityType(_ e: CalendarEntity) -> EKEntityType { e == .event ? .event : .reminder }

    public func permission(for entity: CalendarEntity) async -> DevicePermission {
        switch EKEventStore.authorizationStatus(for: entityType(entity)) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .authorized
        case .writeOnly: return .limited
        @unknown default: return .denied
        }
    }

    public func requestAccess(to entity: CalendarEntity) async throws -> DevicePermission {
        // Access is per app, so a fresh store can ask without sending the actor's store elsewhere.
        let asker = EKEventStore()
        let granted = entity == .event
            ? try await asker.requestFullAccessToEvents()
            : try await asker.requestFullAccessToReminders()
        return granted ? .authorized : .denied
    }

    public func createReminder(_ draft: ReminderDraft) async throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = try calendar(named: draft.listName, entity: .reminder) ?? store.defaultCalendarForNewReminders()
        guard reminder.calendar != nil else { throw DeviceActionError.failed("There is no reminders list to add to.") }
        if let due = draft.dueAt {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .timeZone], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    public func createEvent(_ draft: EventDraft) async throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.startAt
        event.endDate = draft.endAt
        event.location = draft.location
        event.notes = draft.notes
        event.calendar = try calendar(named: draft.calendarName, entity: .event) ?? store.defaultCalendarForNewEvents
        guard event.calendar != nil else { throw DeviceActionError.failed("There is no calendar to add to.") }
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? event.calendarItemIdentifier
    }

    public func events(from: Date, to: Date, limit: Int) async throws -> [CalendarEventInfo] {
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map {
                CalendarEventInfo(
                    id: $0.eventIdentifier ?? $0.calendarItemIdentifier, title: $0.title ?? "",
                    startAt: $0.startDate, endAt: $0.endDate, location: $0.location, calendar: $0.calendar?.title ?? "")
            }
    }

    private func calendar(named name: String?, entity: CalendarEntity) throws -> EKCalendar? {
        guard let name else { return nil }
        let match = store.calendars(for: entityType(entity))
            .first { $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard let match else {
            throw DeviceActionError.failed("There is no \(entity == .event ? "calendar" : "reminders list") named “\(name)”.")
        }
        return match
    }
}
#endif
