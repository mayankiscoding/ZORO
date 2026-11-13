#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
enum ZoroHapticsPlatform {
    static func play(_ haptic: ZoroHaptic) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch haptic {
        case .selection, .listenStart: pattern = .alignment
        case .success, .approved: pattern = .levelChange
        case .attention, .failure: pattern = .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
#endif
