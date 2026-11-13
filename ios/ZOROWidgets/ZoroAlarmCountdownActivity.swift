// UNVERIFIED-ON-HOST
// AlarmKit's countdown presentation for ZORO's timers (ios.timer.start). Apple: "AlarmKit expects a
// widget extension if an app supports a countdown presentation." The metadata type is
// NativeActionBroker's public ZoroAlarmMetadata, so the attributes match what AlarmKitScheduler schedules.
// Checked against Apple's documentation (iOS 26.0): AlarmAttributes<Metadata>, AlarmPresentationState,
// .mode (.countdown / .paused / .alert), Mode.Countdown.fireDate, Text(timerInterval:countsDown:),
// AlarmAttributes.presentation, AlarmPresentation.countdown?.title.
#if os(iOS) && canImport(AlarmKit) && compiler(>=6.2)
import ActivityKit
import AlarmKit
import NativeActionBroker
import SwiftUI
import WidgetKit

@available(iOS 26.0, *)
struct ZoroAlarmCountdownActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<ZoroAlarmMetadata>.self) { context in
            HStack {
                Image(systemName: "timer").accessibilityHidden(true)
                Text(Self.title(context.attributes)).font(.headline)
                Spacer()
                Self.remaining(context.state).font(.title2.monospacedDigit())
            }
            .padding()
            .accessibilityElement(children: .combine)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(Self.title(context.attributes)) }
                DynamicIslandExpandedRegion(.trailing) { Self.remaining(context.state).monospacedDigit() }
            } compactLeading: {
                Image(systemName: "timer").accessibilityLabel("Timer")
            } compactTrailing: {
                Self.remaining(context.state).monospacedDigit().frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "timer").accessibilityLabel("Timer")
            }
        }
    }

    static func title(_ attributes: AlarmAttributes<ZoroAlarmMetadata>) -> LocalizedStringResource {
        attributes.presentation.countdown?.title ?? "Timer"
    }

    @ViewBuilder
    static func remaining(_ state: AlarmPresentationState) -> some View {
        switch state.mode {
        case .countdown(let countdown):
            // A ClosedRange traps when lowerBound > upperBound, which happens once fireDate has passed.
            let now = Date.now
            Text(timerInterval: now...max(now, countdown.fireDate), countsDown: true)
        case .paused:
            Text("Paused")
        default:
            Text("Done")
        }
    }
}
#endif
