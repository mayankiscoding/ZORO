// UNVERIFIED-ON-HOST
// Compiled only for iOS (UIKit). APIs checked against Apple's documentation:
// UIImpactFeedbackGenerator(style:).impactOccurred(), UINotificationFeedbackGenerator().notificationOccurred(_:),
// UISelectionFeedbackGenerator().selectionChanged() — all iOS 10+, main actor.
#if canImport(UIKit) && !os(watchOS)
import UIKit

@MainActor
enum ZoroHapticsPlatform {
    static func play(_ haptic: ZoroHaptic) {
        switch haptic {
        case .listenStart: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .attention: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .failure: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .approved: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}
#endif
