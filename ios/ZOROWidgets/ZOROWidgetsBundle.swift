// UNVERIFIED-ON-HOST
// The widget extension: the "Talk to ZORO" control (Lock Screen, Control Center, Action Button), the
// Live Activity for a long-running agent task, and the AlarmKit countdown presentation that iOS
// requires from a widget extension when the app schedules countdown timers (ios.timer.start).
// Checked against Apple's documentation: WidgetBundle, @WidgetBundleBuilder, ControlWidget (iOS 18),
// ActivityConfiguration(for:content:dynamicIsland:), DynamicIsland, DynamicIslandExpandedRegion.
#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit
import ZoroAppUI

/// The control runs StartVoiceIntent, which is declared in the ZoroAppUI package. Apple's
/// AppIntentsPackage documentation: a target that uses intents from a framework or package declares
/// its own package type that includes the framework's one (iOS 17+).
struct ZOROWidgetsAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [ZoroAppIntentsPackage.self] }
}

@main
struct ZOROWidgetsBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        ZOROVoiceControl()
        AgentTaskLiveActivity()
        #if canImport(AlarmKit) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            ZoroAlarmCountdownActivity()
        }
        #endif
    }
}
#endif
