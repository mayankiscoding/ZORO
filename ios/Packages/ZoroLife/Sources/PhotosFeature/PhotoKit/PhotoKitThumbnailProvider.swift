#if canImport(Photos)
import CoreGraphics
import Foundation
import Photos

#if canImport(UIKit)
import UIKit
typealias PlatformPhotoImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformPhotoImage = NSImage
#endif

/// Loads thumbnails of the owner's real photos through `PHImageManager`, by Photos local identifier. Reads from this device only:
/// network access to iCloud is off, so a photo that is not on the device shows as unavailable instead of being downloaded.
public struct PhotoKitThumbnailProvider: PhotoThumbnailProviding {
    public init() {}

    public func thumbnail(for assetId: String, targetSize: CGSize) async -> PhotoThumbnail? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat  // one callback, no degraded first image
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image.flatMap(Self.cgImage(from:)).map(PhotoThumbnail.init))
            }
        }
    }

    static func cgImage(from image: PlatformPhotoImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}
#endif
