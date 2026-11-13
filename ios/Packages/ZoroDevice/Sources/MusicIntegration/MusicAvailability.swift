import Foundation
import NativeActionBroker
import ZoroCore

/// Gathers `MusicProviderAvailability` without prompting.
public struct MusicAvailabilityProbe: Sendable {
    let appleMusic: (any AppleMusicBackend)?
    let spotifyInstalled: @Sendable () async -> Bool

    /// `appleMusic` nil means Apple Music is driven through the Music app (Mac AppleScript), which needs no
    /// MusicKit authorisation.
    public init(appleMusic: (any AppleMusicBackend)?, spotifyInstalled: @escaping @Sendable () async -> Bool) {
        self.appleMusic = appleMusic
        self.spotifyInstalled = spotifyInstalled
    }

    public func current() async -> MusicProviderAvailability {
        let spotify = await spotifyInstalled()
        guard let appleMusic else {
            return MusicProviderAvailability(appleMusicAuthorization: .authorized, appleMusicCanPlayCatalog: nil, spotifyInstalled: spotify)
        }
        let auth = await appleMusic.authorizationStatus()
        let canPlay: Bool? = auth == .authorized ? (try? await appleMusic.canPlayCatalogContent()) : nil
        return MusicProviderAvailability(appleMusicAuthorization: auth, appleMusicCanPlayCatalog: canPlay, spotifyInstalled: spotify)
    }
}

#if os(macOS)
import AppKit

/// Mac: Music and Spotify through the broker's allowlisted AppleScript ids (never script text).
public struct ScriptedMusicControl: MusicProviderControl {
    public let provider: MusicProvider
    let runner: any AppleScriptRunning
    let opener: any URLOpening

    public init(provider: MusicProvider, runner: any AppleScriptRunning, opener: any URLOpening) {
        self.provider = provider
        self.runner = runner
        self.opener = opener
    }

    var prefix: String { provider == .appleMusic ? "music.apple" : "music.spotify" }

    /// Script ids this control may run (all present in `AppleScriptCatalog.standard`).
    public static func scriptId(_ provider: MusicProvider, _ action: MusicControlAction) -> String {
        let p = provider == .appleMusic ? "music.apple" : "music.spotify"
        switch action {
        case .play: return "\(p).play"
        case .pause: return "\(p).pause"
        case .next: return "\(p).next"
        case .previous: return "\(p).previous"
        case .searchPlay: return provider == .appleMusic ? "music.apple.search_play" : "music.spotify.play_uri"
        }
    }

    static func parse(_ output: String?) -> (String, String?)? {
        guard let output, !output.isEmpty else { return nil }
        let parts = output.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (parts[0], parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    public func perform(_ action: MusicControlAction, query: String?, uri: String?) async throws -> MusicControlOutcome {
        if action == .searchPlay {
            if provider == .appleMusic {
                guard let query else { throw DeviceActionError.invalidArgument("query", "is required for search_play") }
                guard let (title, artist) = Self.parse(try await runner.run(scriptId: Self.scriptId(.appleMusic, .searchPlay), params: ["query": query]))
                else { throw DeviceActionError.failed("Nothing in your Music library matches that.") }
                return MusicControlOutcome(title: title, artist: artist, status: .workingLocal)
            }
            if let uri {
                _ = try await runner.run(scriptId: Self.scriptId(.spotifyApp, .searchPlay), params: ["uri": uri])
            } else if let query, let url = SpotifyLinks.appSearchURL(query) {
                guard await opener.open(url) else {
                    throw DeviceActionError.unsupported("Spotify could not be opened.", status: .manualUserStep)
                }
                return MusicControlOutcome(status: .manualUserStep)
            }
        } else {
            _ = try await runner.run(scriptId: Self.scriptId(provider, action), params: [:])
        }
        let now = Self.parse(try? await runner.run(scriptId: "\(prefix).now_playing", params: [:]))
        return MusicControlOutcome(title: now?.0, artist: now?.1, status: .workingLocal)
    }
}

public enum SpotifyAppPresence {
    public static let bundleIdentifier = "com.spotify.client"

    @MainActor
    public static func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}
#endif
