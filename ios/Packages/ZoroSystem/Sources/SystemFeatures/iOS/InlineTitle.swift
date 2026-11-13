// UNVERIFIED-ON-HOST
#if os(iOS)
import SwiftUI

// Screens draw their own title in ZORO's type (`ZoroTextStyle.title`), so the navigation bar shows
// the small inline title instead of a second large one.
// `View.navigationBarTitleDisplayMode(_:)` is iOS 14+ and not available on macOS (checked against
// developer.apple.com/documentation/swiftui/view/navigationbartitledisplaymode(_:)).
extension View {
    func systemInlineTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }
}
#endif
