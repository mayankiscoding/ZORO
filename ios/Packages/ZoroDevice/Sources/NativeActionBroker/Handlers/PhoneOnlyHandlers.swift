import Foundation
import ZoroCore

// Validation and result mapping for the `ios.*` tools. The system services live in `iOS/`.

// MARK: - Alarms and timers (AlarmKit, iOS 26+)

public enum AlarmWeekday: String, CaseIterable, Sendable {
    case mon, tue, wed, thu, fri, sat, sun
}

public struct AlarmDraft: Sendable, Equatable {
    public var id: UUID
    public var hour: Int
    public var minute: Int
    public var label: String?
    /// Empty = one time.
    public var repeatDays: [AlarmWeekday]
}

public struct TimerDraft: Sendable, Equatable {
    public var id: UUID
    public var seconds: Int
    public var label: String?
}

public protocol AlarmScheduling: Sendable {
    /// false before iOS 26 (AlarmKit missing).
    func isSupported() async -> Bool
    func permission() async -> DevicePermission
    func requestAccess() async throws -> DevicePermission
    func scheduleAlarm(_ draft: AlarmDraft) async throws -> String
    func startTimer(_ draft: TimerDraft) async throws -> String
}

/// `ios.alarm.create`, `ios.timer.start`.
public struct AlarmHandler: DeviceActionHandler {
    let scheduler: any AlarmScheduling
    let makeId: @Sendable () -> UUID
    public init(scheduler: any AlarmScheduling, makeId: @escaping @Sendable () -> UUID = { UUID() }) {
        self.scheduler = scheduler
        self.makeId = makeId
    }

    public var tools: [DeviceToolName] { [.alarmCreate, .timerStart] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let scheduler = self.scheduler
        let label = try args.string("label", maxLength: 60)
        let ready: @Sendable () async throws -> Void = {
            guard await scheduler.isSupported() else {
                throw DeviceActionError.unsupported("Alarms and timers need iOS 26 or later.")
            }
            try await PermissionGate.ensure(
                "alarms", status: { await scheduler.permission() }, request: { try await scheduler.requestAccess() })
        }
        switch tool {
        case .alarmCreate:
            let time = try args.requiredString("time", maxLength: 5)
            guard let (hour, minute) = DeviceTime.parseClock(time) else {
                throw DeviceActionError.invalidArgument("time", "must be HH:MM (24-hour)")
            }
            var days: [AlarmWeekday] = []
            for raw in try args.stringArray("repeat_days", maxCount: 7) ?? [] {
                guard let d = AlarmWeekday(rawValue: raw.lowercased()) else {
                    throw DeviceActionError.invalidArgument("repeat_days", "must use mon, tue, wed, thu, fri, sat, sun")
                }
                if !days.contains(d) { days.append(d) }
            }
            let draft = AlarmDraft(id: makeId(), hour: hour, minute: minute, label: label, repeatDays: days)
            return PreparedDeviceAction(summary: "Set an alarm for \(time).") {
                try await ready()
                return ["alarm_id": .string(try await scheduler.scheduleAlarm(draft))]
            }
        case .timerStart:
            guard let seconds = try args.int("seconds", range: 1...86_400) else {
                throw DeviceActionError.invalidArgument("seconds", "is required")
            }
            let draft = TimerDraft(id: makeId(), seconds: seconds, label: label)
            return PreparedDeviceAction(summary: "Start a \(seconds)-second timer.") {
                try await ready()
                return ["timer_id": .string(try await scheduler.startTimer(draft))]
            }
        default:
            throw DeviceActionError.unsupported("\(tool.rawValue) is not an alarm tool.")
        }
    }
}

// MARK: - Message composer (MessageUI)

public enum MessageComposeOutcome: String, Sendable { case sent, cancelled, failed }

public protocol MessageComposing: Sendable {
    func canSendText() async -> Bool
    /// Presents the system composer; the owner taps send.
    func compose(recipients: [String], body: String) async -> MessageComposeOutcome
}

/// `ios.message.compose`.
public struct MessageComposeHandler: DeviceActionHandler {
    let composer: any MessageComposing
    public init(composer: any MessageComposing) { self.composer = composer }

    public var tools: [DeviceToolName] { [.messageCompose] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        guard let raw = try args.stringArray("recipients", maxCount: 20, maxLength: 40), !raw.isEmpty else {
            throw DeviceActionError.invalidArgument("recipients", "needs at least one phone number")
        }
        let recipients = try raw.map { r -> String in
            guard let digits = PhoneNumber.digits(r) else {
                throw DeviceActionError.invalidArgument("recipients", "must be phone numbers")
            }
            return "+" + digits
        }
        let body = try args.requiredString("body", maxLength: 5000)
        let composer = self.composer
        return PreparedDeviceAction(
            summary: "Open a message to \(recipients.joined(separator: ", ")). You tap send.", successStatus: .manualUserStep
        ) {
            guard await composer.canSendText() else {
                throw DeviceActionError.unsupported("This device cannot send messages.", status: .restrictedByIos)
            }
            switch await composer.compose(recipients: recipients, body: body) {
            case .sent: return ["presented": true, "sent": true]
            case .cancelled: throw DeviceActionError.userCancelled
            case .failed: throw DeviceActionError.failed("The message was not sent.")
            }
        }
    }
}

// MARK: - HomeKit scenes

public protocol HomeSceneRunning: Sendable {
    func permission() async -> DevicePermission
    /// Loads the home manager, which shows HomeKit's own prompt the first time.
    func requestAccess() async throws -> DevicePermission
    /// false when no scene has that name.
    func runScene(named name: String) async throws -> Bool
}

/// `ios.home.run_scene`.
public struct HomeSceneHandler: DeviceActionHandler {
    let runner: any HomeSceneRunning
    public init(runner: any HomeSceneRunning) { self.runner = runner }

    public var tools: [DeviceToolName] { [.homeRunScene] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let name = try args.requiredString("scene_name", maxLength: 100)
        let runner = self.runner
        return PreparedDeviceAction(summary: "Run the Home scene “\(name)”.") {
            try await PermissionGate.ensure(
                "Home", status: { await runner.permission() }, request: { try await runner.requestAccess() })
            guard try await runner.runScene(named: name) else {
                throw DeviceActionError.failed("There is no Home scene named “\(name)”.")
            }
            return ["ran": true]
        }
    }
}
