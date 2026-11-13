// UNVERIFIED-ON-HOST
// Compiled only for iOS (UIKit). APIs checked against Apple's documentation:
// Color(uiColor:) (iOS 15+); UIColor.systemBackground, .secondarySystemBackground,
// .tertiarySystemFill, .separator (iOS 13+).
#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

enum PlatformNeutrals {
    static var background: Color { Color(uiColor: .systemBackground) }
    static var raised: Color { Color(uiColor: .secondarySystemBackground) }
    static var inset: Color { Color(uiColor: .tertiarySystemFill) }
    static var hairline: Color { Color(uiColor: .separator) }
}
#endif
