// UNVERIFIED-ON-HOST
// AlarmKit (iOS 26.0+). Checked against developer.apple.com/documentation/alarmkit (fetched 2026-11-13):
// AlarmManager.shared, authorizationState, requestAuthorization() async throws -> AuthorizationState,
// schedule(id:configuration:) async throws -> Alarm, AlarmConfiguration.alarm(schedule:attributes:...) and
// .timer(duration:attributes:...) with defaulted intents and sound, Alarm.Schedule.relative(Relative(time:repeats:)),
// AlarmPresentation(alert:countdown:paused:), Alert(title:stopButton:...) (26.0, deprecated in 26.1) and
// Alert(title:secondaryButton:secondaryButtonBehavior:) (26.1+), AlarmAttributes(presentation:metadata:tintColor:).
// The app's Info.plist needs NSAlarmKitUsageDescription. "AlarmKit expects a widget extension if an app
// supports a countdown presentation" (Scheduling an alarm with AlarmKit): timers below use one, so the widget
// extension needs ActivityConfiguration(for: AlarmAttributes<ZoroAlarmMetadata>.self), hence the public type.
#if os(iOS) && canImport(AlarmKit)
import AlarmKit
import Foundation
import SwiftUI

/// Metadata for ZORO's alarms; public so the widget extension can declare the alarm Live Activity.
@available(iOS 26.0, *)
public struct ZoroAlarmMetadata: AlarmMetadata {
    public init() {}
}

/// `AlarmScheduling` over AlarmKit; reports unsupported before iOS 26.
public struct AlarmKitScheduler: AlarmScheduling {
    public init() {}

    public func isSupported() async -> Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    public func permission() async -> DevicePermission {
        guard #available(iOS 26.0, *) else { return .restricted }
        switch AlarmManager.shared.authorizationState {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    public func requestAccess() async throws -> DevicePermission {
        guard #available(iOS 26.0, *) else { return .restricted }
        switch try await AlarmManager.shared.requestAuthorization() {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    @available(iOS 26.0, *)
    private func attributes(title: String, countdown: Bool) -> AlarmAttributes<ZoroAlarmMetadata> {
        let resource = LocalizedStringResource(stringLiteral: title)
        let alert: AlarmPresentation.Alert
        #if compiler(>=6.2.1)
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: resource)
        } else {
            alert = AlarmPresentation.Alert(
                title: resource, stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        }
        #else
        alert = AlarmPresentation.Alert(
            title: resource, stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        #endif
        let presentation = AlarmPresentation(
            alert: alert, countdown: countdown ? AlarmPresentation.Countdown(title: resource, pauseButton: nil) : nil,
            paused: nil)
        return AlarmAttributes(presentation: presentation, metadata: ZoroAlarmMetadata(), tintColor: .indigo)
    }

    public func scheduleAlarm(_ draft: AlarmDraft) async throws -> String {
        guard #available(iOS 26.0, *) else { throw DeviceActionError.unsupported("Alarms need iOS 26 or later.") }
        let weekdays: [Locale.Weekday] = draft.repeatDays.map {
            switch $0 {
            case .mon: .monday
            case .tue: .tuesday
            case .wed: .wednesday
            case .thu: .thursday
            case .fri: .friday
            case .sat: .saturday
            case .sun: .sunday
            }
        }
        let relative = Alarm.Schedule.Relative(
            time: Alarm.Schedule.Relative.Time(hour: draft.hour, minute: draft.minute),
            repeats: weekdays.isEmpty ? .never : .weekly(weekdays))
        let configuration = AlarmManager.AlarmConfiguration<ZoroAlarmMetadata>.alarm(
            schedule: .relative(relative), attributes: attributes(title: draft.label ?? "Alarm", countdown: false))
        let alarm = try await AlarmManager.shared.schedule(id: draft.id, configuration: configuration)
        return alarm.id.uuidString
    }

    public func startTimer(_ draft: TimerDraft) async throws -> String {
        guard #available(iOS 26.0, *) else { throw DeviceActionError.unsupported("Timers need iOS 26 or later.") }
        let configuration = AlarmManager.AlarmConfiguration<ZoroAlarmMetadata>.timer(
            duration: TimeInterval(draft.seconds), attributes: attributes(title: draft.label ?? "Timer", countdown: true))
        let alarm = try await AlarmManager.shared.schedule(id: draft.id, configuration: configuration)
        return alarm.id.uuidString
    }
}
#endif
