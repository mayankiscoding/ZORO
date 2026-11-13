import Foundation
import ZoroCore

// The contract types (`PhotoQuery`, `PhotoHit`, `PhotoSearchResult`) live in ZoroCore; this package
// adds only the errors its own search path throws.

public enum PhotoSearchError: Error, Sendable, Equatable, LocalizedError {
    case permissionDenied(MediaAuthorization)
    case unsupportedMedia(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Photos access is not allowed. Allow it in Settings to search photos."
        case .unsupportedMedia(let reason): "Unsupported media: \(reason)."
        }
    }
}
