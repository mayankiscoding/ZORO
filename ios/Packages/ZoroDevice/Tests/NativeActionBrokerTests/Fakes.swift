import Foundation
@testable import NativeActionBroker
import ZoroCore

let fixedNow = Date(timeIntervalSince1970: 1_794_000_000)  // 2026-11-06T21:20Z

func request(
    _ tool: String, _ args: JSONObject = [:], id: String = UUID().uuidString, confirm: Bool = false,
    expiresIn: TimeInterval = 300
) -> DeviceActionRequest {
    DeviceActionRequest(
        actionId: id, tool: tool, args: args, risk: .medium, requiresUserConfirmation: confirm,
        expiresAt: fixedNow.addingTimeInterval(expiresIn))
}

actor FakeCalendarStore: CalendarStoring {
    var states: [CalendarEntity: DevicePermission] = [.event: .authorized, .reminder: .authorized]
    var grantOnRequest = true
    var requests = 0
    var reminders: [ReminderDraft] = []
    var events: [EventDraft] = []
    var stored: [CalendarEventInfo] = []

    func set(_ entity: CalendarEntity, _ state: DevicePermission, grant: Bool = true) {
        states[entity] = state
        grantOnRequest = grant
    }
    func setStored(_ e: [CalendarEventInfo]) { stored = e }

    func permission(for entity: CalendarEntity) async -> DevicePermission { states[entity] ?? .denied }
    func requestAccess(to entity: CalendarEntity) async throws -> DevicePermission {
        requests += 1
        states[entity] = grantOnRequest ? .authorized : .denied
        return states[entity]!
    }
    func createReminder(_ draft: ReminderDraft) async throws -> String {
        reminders.append(draft)
        return "rem-\(reminders.count)"
    }
    func createEvent(_ draft: EventDraft) async throws -> String {
        events.append(draft)
        return "evt-\(events.count)"
    }
    func events(from: Date, to: Date, limit: Int) async throws -> [CalendarEventInfo] {
        stored.filter { $0.startAt >= from && $0.startAt < to }
    }
}

actor FakeContactsStore: ContactsStoring {
    var state: DevicePermission = .authorized
    var saved: [ContactDraft] = []
    func setState(_ s: DevicePermission) { state = s }
    func permission() async -> DevicePermission { state }
    func requestAccess() async throws -> DevicePermission { state }
    func find(_ query: String, limit: Int) async throws -> [ContactMatch] {
        [ContactMatch(contactRef: "c1", name: "Asha Rao", phones: ["+91 98765 43210"], emails: ["asha@example.com"])]
    }
    func save(_ draft: ContactDraft) async throws -> String {
        saved.append(draft)
        return "c-new"
    }
}

actor FakeNotifications: NotificationScheduling {
    var scheduled: [LocalNotificationDraft] = []
    func permission() async -> DevicePermission { .authorized }
    func requestAccess() async throws -> DevicePermission { .authorized }
    func schedule(_ draft: LocalNotificationDraft) async throws { scheduled.append(draft) }
}

struct FakeLocation: LocationProviding {
    var state: DevicePermission = .authorized
    func permission() async -> DevicePermission { state }
    func requestAccess() async throws -> DevicePermission { state }
    func currentLocation() async throws -> LocationFix {
        LocationFix(latitude: 12.97159, longitude: 77.59456, accuracyMeters: 35.4, locality: "Bengaluru")
    }
}

actor RecordingOpener: URLOpening {
    var opened: [URL] = []
    var succeeds = true
    func setSucceeds(_ s: Bool) { succeeds = s }
    func open(_ url: URL) async -> Bool {
        opened.append(url)
        return succeeds
    }
}

actor FakeShortcuts: ShortcutRunning {
    var runs: [(String, String?)] = []
    func run(name: String, input: String?) async throws { runs.append((name, input)) }
}

actor FakeProcessRunner: ProcessRunning {
    var calls: [(URL, [String])] = []
    var output = ProcessOutput(status: 0, stdout: "")
    func setOutput(_ o: ProcessOutput) { output = o }
    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessOutput {
        calls.append((executable, arguments))
        return output
    }
}

actor FakeAlarms: AlarmScheduling {
    var supported = true
    var alarms: [AlarmDraft] = []
    var timers: [TimerDraft] = []
    func setSupported(_ s: Bool) { supported = s }
    func isSupported() async -> Bool { supported }
    func permission() async -> DevicePermission { .authorized }
    func requestAccess() async throws -> DevicePermission { .authorized }
    func scheduleAlarm(_ draft: AlarmDraft) async throws -> String {
        alarms.append(draft)
        return draft.id.uuidString
    }
    func startTimer(_ draft: TimerDraft) async throws -> String {
        timers.append(draft)
        return draft.id.uuidString
    }
}

actor FakeComposer: MessageComposing {
    var outcome: MessageComposeOutcome = .sent
    var composed: [([String], String)] = []
    func setOutcome(_ o: MessageComposeOutcome) { outcome = o }
    func canSendText() async -> Bool { true }
    func compose(recipients: [String], body: String) async -> MessageComposeOutcome {
        composed.append((recipients, body))
        return outcome
    }
}

struct FakeHome: HomeSceneRunning {
    func permission() async -> DevicePermission { .authorized }
    func requestAccess() async throws -> DevicePermission { .authorized }
    func runScene(named name: String) async throws -> Bool { name.lowercased() == "good night" }
}

actor FakeConfirmer: DeviceActionConfirming {
    var answer: Bool
    var asked: [DeviceActionConfirmation] = []
    init(_ answer: Bool) { self.answer = answer }
    func confirm(_ confirmation: DeviceActionConfirmation) async -> Bool {
        asked.append(confirmation)
        return answer
    }
}

/// Counts runs and can block until released (duplicate-delivery tests).
actor CountingHandlerState {
    var runs = 0
    func increment() -> Int {
        runs += 1
        return runs
    }
}

struct CountingHandler: DeviceActionHandler {
    let state: CountingHandlerState
    var tools: [DeviceToolName] { [.openURL] }
    func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        PreparedDeviceAction(summary: "count") {
            try await Task.sleep(for: .milliseconds(50))
            return ["opened": .number(Double(await state.increment()))]
        }
    }
}
