// UNVERIFIED-ON-HOST
// Ready file for the iOS widget extension (ios/ZOROWidgets). Not compiled in this package.
// A Lock Screen / Control Center control that runs StartVoiceIntent, which opens the app into Live
// Voice (openAppWhenRun). The Action Button can run the same intent through its Shortcut setting.
//
// Checked against Apple's documentation: StaticControlConfiguration.init(kind:content:) (iOS 18),
// ControlWidgetButton.init(action:label:) (iOS 18). The widget extension must link ZoroAppUI so the
// intent type is shared with the app.
#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit
import ZoroAppUI

struct ZOROVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.zoro.control.voice") {
            ControlWidgetButton(action: StartVoiceIntent()) {
                Label("Talk to ZORO", systemImage: "waveform")
            }
        }
        .displayName("Talk to ZORO")
        .description("Opens ZORO's live voice screen.")
    }
}
#endif
