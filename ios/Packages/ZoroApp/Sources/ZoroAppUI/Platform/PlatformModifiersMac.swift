#if os(macOS)
import SwiftUI

extension View {
    /// On the Mac Live Voice is a sheet over the window.
    func zoroLiveVoiceCover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented) {
            content().frame(minWidth: 480, minHeight: 640)
        }
    }

    func zoroInlineTitle() -> some View { self }

    func zoroAddressField() -> some View { autocorrectionDisabled() }

    func zoroCodeField() -> some View { autocorrectionDisabled() }
}
#endif
