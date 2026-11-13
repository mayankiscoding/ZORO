import CoreGraphics
import Foundation

/// A decoded thumbnail for one photo, produced on this device. Nothing here is ever sent anywhere.
public struct PhotoThumbnail: @unchecked Sendable {
    public let image: CGImage
    public init(image: CGImage) { self.image = image }
}

/// Shows the real photos by their Photos local identifier. The PhotoKit implementation is `PhotoKitThumbnailProvider`;
/// tests use an in-memory fake. Returns nil when the photo is gone, not shared with ZORO, or cannot be read.
public protocol PhotoThumbnailProviding: Sendable {
    func thumbnail(for assetId: String, targetSize: CGSize) async -> PhotoThumbnail?
}

/// The not-wired provider: every photo shows as unavailable instead of crashing or inventing an image.
public struct UnavailableThumbnailProvider: PhotoThumbnailProviding {
    public init() {}
    public func thumbnail(for assetId: String, targetSize: CGSize) async -> PhotoThumbnail? { nil }
}

/// Shows the system picker that adds photos to a limited library. iPhone only; the Mac has no such picker.
public protocol LimitedLibraryPresenting: Sendable {
    /// True when a picker could be shown.
    @MainActor func presentPicker() async -> Bool
}

public struct UnavailableLimitedLibraryPresenter: LimitedLibraryPresenting {
    public init() {}
    @MainActor public func presentPicker() async -> Bool { false }
}

#if canImport(SwiftUI)
import SwiftUI

private struct ThumbnailProviderKey: EnvironmentKey {
    static let defaultValue: any PhotoThumbnailProviding = UnavailableThumbnailProvider()
}

private struct LimitedLibraryKey: EnvironmentKey {
    static let defaultValue: any LimitedLibraryPresenting = UnavailableLimitedLibraryPresenter()
}

extension EnvironmentValues {
    /// Set by `ZoroApp` to `PhotoKitThumbnailProvider()`.
    public var photoThumbnailProvider: any PhotoThumbnailProviding {
        get { self[ThumbnailProviderKey.self] }
        set { self[ThumbnailProviderKey.self] = newValue }
    }

    /// Set by `ZoroApp` to `PhotoKitLimitedLibraryPresenter()` on iPhone.
    public var limitedLibraryPresenter: any LimitedLibraryPresenting {
        get { self[LimitedLibraryKey.self] }
        set { self[LimitedLibraryKey.self] = newValue }
    }
}
#endif
