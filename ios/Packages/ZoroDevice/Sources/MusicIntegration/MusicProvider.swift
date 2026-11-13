import Foundation
import ZoroCore

/// The `provider` argument of `device.music.control`.
public enum MusicProvider: String, Sendable, CaseIterable {
    case appleMusic = "apple_music"
    case spotifyApp = "spotify_app"

    public var displayName: String { self == .appleMusic ? "Apple Music" : "Spotify" }
}

/// What this device can use right now, gathered without prompting.
public struct MusicProviderAvailability: Sendable, Equatable {
    public var appleMusicAuthorization: MediaAuthorization
    /// nil = unknown (not checked yet, or the check failed).
    public var appleMusicCanPlayCatalog: Bool?
    public var spotifyInstalled: Bool

    public init(appleMusicAuthorization: MediaAuthorization, appleMusicCanPlayCatalog: Bool?, spotifyInstalled: Bool) {
        self.appleMusicAuthorization = appleMusicAuthorization
        self.appleMusicCanPlayCatalog = appleMusicCanPlayCatalog
        self.spotifyInstalled = spotifyInstalled
    }
}

public enum MusicProviderChoice: Sendable, Equatable {
    case use(MusicProvider)
    case unavailable(reason: String)
}

/// Picks the provider for a request. An explicit request is never silently switched to another service.
public enum MusicProviderSelector {
    public static func isUsable(_ provider: MusicProvider, _ a: MusicProviderAvailability) -> Bool {
        switch provider {
        case .appleMusic:
            // notDetermined is usable: the permission sheet appears in context on first use.
            return (a.appleMusicAuthorization == .authorized || a.appleMusicAuthorization == .notDetermined)
                && a.appleMusicCanPlayCatalog != false
        case .spotifyApp:
            return a.spotifyInstalled
        }
    }

    public static func select(
        requested: MusicProvider?, preferred: MusicProvider?, availability a: MusicProviderAvailability
    ) -> MusicProviderChoice {
        if let requested {
            if isUsable(requested, a) { return .use(requested) }
            return .unavailable(reason: reason(requested, a))
        }
        if let preferred, isUsable(preferred, a) { return .use(preferred) }
        if a.appleMusicAuthorization == .authorized, a.appleMusicCanPlayCatalog == true { return .use(.appleMusic) }
        if a.spotifyInstalled { return .use(.spotifyApp) }
        if isUsable(.appleMusic, a) { return .use(.appleMusic) }
        return .unavailable(reason: "No music service is set up. Allow Apple Music or install Spotify.")
    }

    static func reason(_ p: MusicProvider, _ a: MusicProviderAvailability) -> String {
        switch p {
        case .appleMusic:
            if a.appleMusicAuthorization == .denied || a.appleMusicAuthorization == .restricted {
                return "ZORO has no access to Apple Music. Allow it in Settings."
            }
            return "Playing from Apple Music needs an Apple Music subscription."
        case .spotifyApp:
            return "Spotify is not installed on this device."
        }
    }
}
