#if canImport(Photos)
import CoreGraphics
import Foundation
import Photos
import Synchronization
import ZoroCore

/// The owner's photo library through PhotoKit (read-only).
///
/// - Authorisation uses the read-write access level (the only level that can read assets); a limited
///   library reports `.limited` and fetches return only the selected assets.
/// - The change observer is registered only once access is granted, so it never triggers a prompt.
/// - Thumbnails are never downloaded from iCloud (`isNetworkAccessAllowed = false`).
///
/// App requirements: `NSPhotoLibraryUsageDescription` in Info.plist; optionally
/// `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` when the app offers its own "select more" button.
public final class PhotoKitLibrary: NSObject, PhotoLibraryProviding, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let observers = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])
    private let registered = Mutex(false)

    public override init() {
        super.init()
    }

    deinit {
        if registered.withLock({ $0 }) {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    // MARK: Authorisation

    public func authorizationStatus() async -> MediaAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> MediaAuthorization {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status = current == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : current
        registerIfAllowed()
        return Self.map(status)
    }

    static func map(_ status: PHAuthorizationStatus) -> MediaAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .denied
        }
    }

    private var isAllowed: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    // MARK: Fetching

    public func fetchAssets() async throws -> [LibraryAsset] {
        guard isAllowed else { throw PhotoSearchError.permissionDenied(await authorizationStatus()) }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        let result = PHAsset.fetchAssets(with: options)
        var assets: [LibraryAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(Self.describe(asset))
        }
        return assets
    }

    static func describe(_ asset: PHAsset) -> LibraryAsset {
        let kind: PhotoMediaKind
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            kind = .screenshot
        } else if asset.mediaSubtypes.contains(.photoLive) {
            kind = .livePhoto
        } else {
            kind = .photo
        }
        return LibraryAsset(
            id: asset.localIdentifier, capturedAt: asset.creationDate, modifiedAt: asset.modificationDate,
            kind: kind, hasLocation: asset.location != nil)
    }

    public func accessibleIdentifiers(among ids: [String]) async -> Set<String> {
        guard isAllowed, !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var found = Set<String>()
        result.enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
        return found
    }

    public func thumbnail(for assetId: String, maxPixelSize: Int) async throws -> AnalysisImage? {
        guard isAllowed,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject
        else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat  // one callback
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.version = .current
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        let manager = PHImageManager.default()
        // Only used to cancel this one request from the cancellation handler.
        let cancelHandle = ImageManagerHandle(manager: manager)
        let requestID = Mutex<PHImageRequestID?>(nil)
        let resumed = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AnalysisImage?, Error>) in
                let id = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                    guard !resumed.withLock({ let was = $0; $0 = true; return was }) else { return }
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: image.flatMap(platformCGImage).map(AnalysisImage.init))
                }
                requestID.withLock { $0 = id }
            }
        } onCancel: {
            if let id = requestID.withLock({ $0 }) { cancelHandle.manager.cancelImageRequest(id) }
        }
    }

    // MARK: Change observation

    public func changes() -> AsyncStream<Void> {
        registerIfAllowed()
        let key = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers.withLock { $0[key] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.observers.withLock { $0.removeValue(forKey: key) }
            }
        }
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        let all = observers.withLock { Array($0.values) }
        for continuation in all { continuation.yield(()) }
    }

    private func registerIfAllowed() {
        guard isAllowed else { return }
        let shouldRegister = registered.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        if shouldRegister { PHPhotoLibrary.shared().register(self) }
    }
}

private struct ImageManagerHandle: @unchecked Sendable {
    let manager: PHImageManager
}
#endif
