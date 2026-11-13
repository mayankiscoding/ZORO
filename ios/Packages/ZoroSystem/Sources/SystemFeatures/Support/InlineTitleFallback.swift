#if !os(iOS)
import SwiftUI

extension View {
    /// macOS shows the navigation title in the window toolbar; nothing to adjust.
    func systemInlineTitle() -> some View { self }
}
#endif
