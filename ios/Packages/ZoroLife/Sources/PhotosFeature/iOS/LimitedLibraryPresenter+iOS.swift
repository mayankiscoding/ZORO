// UNVERIFIED-ON-HOST
#if os(iOS)
import Photos
import PhotosUI
import UIKit

/// Shows the system picker that adds more photos to a limited library
/// (`PHPhotoLibrary.presentLimitedLibraryPicker(from:)`, iOS 14 and later).
public struct PhotoKitLimitedLibraryPresenter: LimitedLibraryPresenting {
    public init() {}

    @MainActor public func presentPicker() async -> Bool {
        guard let top = Self.topViewController() else { return false }
        // Async form (iOS 15+): returns once the owner closes the picker.
        _ = await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
        return true
    }

    @MainActor private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
#endif
