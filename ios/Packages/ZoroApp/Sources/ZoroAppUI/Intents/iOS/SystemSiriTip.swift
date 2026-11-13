// UNVERIFIED-ON-HOST
// Apple's own Siri tip and Shortcuts link (iOS only: SiriTipView and ShortcutsLink do not exist on macOS).
// Checked against Apple's documentation: SiriTipView.init(intent:isVisible:) (iOS 16),
// ShortcutsLink (iOS 16). Both read the phrases from the app's AppShortcutsProvider, so they show the
// phrases in the device's Siri language.
#if os(iOS)
import AppIntents
import SwiftUI

/// The system "Hey Siri, Ask ZORO" tip, plus a link to ZORO's page in the Shortcuts app.
public struct ZoroSystemSiriTip: View {
    @Binding private var isVisible: Bool

    public init(isVisible: Binding<Bool>) {
        _isVisible = isVisible
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SiriTipView(intent: AskZoroIntent(), isVisible: $isVisible)
            ShortcutsLink()
        }
    }
}
#endif
