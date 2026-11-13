// UNVERIFIED-ON-HOST
// iOS-only SwiftUI modifiers, checked against Apple's documentation:
// fullScreenCover(isPresented:onDismiss:content:) iOS 14, navigationBarTitleDisplayMode(_:) iOS 14,
// keyboardType(_:) iOS 13, textInputAutocapitalization(_:) iOS 15. The macOS versions are in
// Platform/PlatformModifiersMac.swift.
#if os(iOS)
import SwiftUI

extension View {
    /// Live Voice covers the whole screen on iPhone.
    func zoroLiveVoiceCover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        fullScreenCover(isPresented: isPresented, content: content)
    }

    func zoroInlineTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }

    func zoroAddressField() -> some View {
        keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    func zoroCodeField() -> some View {
        keyboardType(.asciiCapable).textInputAutocapitalization(.characters).autocorrectionDisabled()
    }
}
#endif
