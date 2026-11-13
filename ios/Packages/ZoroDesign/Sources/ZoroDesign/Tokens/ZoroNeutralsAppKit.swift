#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

enum PlatformNeutrals {
    static var background: Color { Color(nsColor: .windowBackgroundColor) }
    static var raised: Color { Color(nsColor: .controlBackgroundColor) }
    static var inset: Color { Color(nsColor: .quaternaryLabelColor) }
    static var hairline: Color { Color(nsColor: .separatorColor) }
}
#endif
