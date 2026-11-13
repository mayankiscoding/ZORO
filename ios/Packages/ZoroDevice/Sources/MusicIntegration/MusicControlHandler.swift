import Foundation
import NativeActionBroker
import ZoroCore

/// The `action` argument of `device.music.control`.
public enum MusicControlAction: String, Sendable, CaseIterable {
    case play, pause, next, previous
    case searchPlay = "search_play"
}

public struct MusicControlOutcome: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var status: CapabilityStatus
    public init(title: String? = nil, artist: String? = nil, status: CapabilityStatus) {
        self.title = title
        self.artist = artist
        self.status = status
    }
}

/// One provider's way of carrying out a control action on this device.
public protocol MusicProviderControl: Sendable {
    var provider: MusicProvider { get }
    /// `query` / `uri` are validated by the handler; `uri` is a Spotify URI and only reaches Spotify.
    func perform(_ action: MusicControlAction, query: String?, uri: String?) async throws -> MusicControlOutcome
}

/// Apple Music through any `MusicControlling` (MusicKit's `AppleMusicController` on iPhone, and on Mac
/// when no AppleScript control is wired). Uses only the ZoroCore protocol.
public struct AppleMusicKitControl: MusicProviderControl {
    let controller: any MusicControlling
    public init(controller: any MusicControlling) { self.controller = controller }
    public var provider: MusicProvider { .appleMusic }

    public func perform(_ action: MusicControlAction, query: String?, uri: String?) async throws -> MusicControlOutcome {
        switch action {
        case .play: try await controller.play(nil)
        case .pause: try await controller.pause()
        case .next: try await controller.skipToNext()
        case .previous: try await controller.skipToPrevious()
        case .searchPlay:
            let found = try await controller.search(MusicSearchQuery(text: query ?? "", kinds: [.song], service: .appleMusic, limit: 1))
            guard let item = found.first else {
                throw DeviceActionError.failed("Apple Music found nothing for that search.")
            }
            try await controller.play(item)
            return MusicControlOutcome(title: item.title, artist: item.subtitle, status: .workingNative)
        }
        let now = try? await controller.nowPlaying()
        return MusicControlOutcome(title: now?.item?.title, artist: now?.item?.subtitle, status: .workingNative)
    }
}

/// Spotify links: `spotify:` URIs and search, falling back to the open.spotify.com universal link.
public enum SpotifyLinks {
    public static func isURI(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        let kinds: Set<Substring> = ["track", "album", "playlist", "artist", "episode", "show"]
        return parts.count == 3 && parts[0] == "spotify" && kinds.contains(parts[1]) && parts[2].count == 22
            && parts[2].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    public static func appSearchURL(_ query: String) -> URL? {
        URL(string: "spotify:search:" + PercentEncoding.encode(query))
    }

    public static func webSearchURL(_ query: String) -> URL? {
        URL(string: "https://open.spotify.com/search/" + PercentEncoding.encode(query))
    }

    /// `spotify:track:<id>` → `https://open.spotify.com/track/<id>`.
    public static func webURL(forURI uri: String) -> URL? {
        guard isURI(uri) else { return nil }
        let parts = uri.split(separator: ":")
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }
}

/// iPhone: Spotify by app handoff. Playback control needs the Spotify Web API (owner credentials),
/// which this build does not have, so play / pause / next / previous answer "unsupported".
public struct SpotifyHandoffControl: MusicProviderControl {
    let opener: any URLOpening
    public init(opener: any URLOpening) { self.opener = opener }
    public var provider: MusicProvider { .spotifyApp }

    public func perform(_ action: MusicControlAction, query: String?, uri: String?) async throws -> MusicControlOutcome {
        guard action == .searchPlay else {
            throw DeviceActionError.unsupported(
                "Controlling Spotify playback on iPhone needs a Spotify account connection. ZORO can open Spotify for you.",
                status: .requiresCredentials)
        }
        let primary = uri.flatMap { URL(string: $0) } ?? query.flatMap(SpotifyLinks.appSearchURL)
        let fallback = uri.flatMap(SpotifyLinks.webURL(forURI:)) ?? query.flatMap(SpotifyLinks.webSearchURL)
        if let primary, await opener.open(primary) { return MusicControlOutcome(status: .manualUserStep) }
        if let fallback, await opener.open(fallback) { return MusicControlOutcome(status: .manualUserStep) }
        throw DeviceActionError.unsupported("Spotify could not be opened on this device.", status: .manualUserStep)
    }
}

/// `device.music.control`.
public struct MusicControlHandler: DeviceActionHandler {
    let controls: [MusicProvider: any MusicProviderControl]
    let availability: @Sendable () async -> MusicProviderAvailability
    let preferred: @Sendable () async -> MusicProvider?

    public init(
        controls: [any MusicProviderControl], availability: @escaping @Sendable () async -> MusicProviderAvailability,
        preferred: @escaping @Sendable () async -> MusicProvider? = { nil }
    ) {
        self.controls = Dictionary(controls.map { ($0.provider, $0) }, uniquingKeysWith: { first, _ in first })
        self.availability = availability
        self.preferred = preferred
    }

    public var tools: [DeviceToolName] { [.musicControl] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let requested = try args.enumValue("provider", as: MusicProvider.self)
        let action = try args.requiredEnum("action", as: MusicControlAction.self)
        let query = try args.string("query", maxLength: 200)
        let uri = try args.string("uri", maxLength: 80)
        if let uri {
            guard SpotifyLinks.isURI(uri) else { throw DeviceActionError.invalidArgument("uri", "must be a Spotify URI") }
            guard requested != .appleMusic else {
                throw DeviceActionError.invalidArgument("uri", "only applies to provider spotify_app")
            }
        }
        if action == .searchPlay, query == nil, uri == nil {
            throw DeviceActionError.invalidArgument("query", "is required for search_play")
        }
        let controls = self.controls
        let availability = self.availability
        let preferred = self.preferred
        let summary: String = switch action {
        case .searchPlay: "Play “\(query ?? "that")”."
        case .play: "Resume music."
        case .pause: "Pause music."
        case .next: "Skip to the next song."
        case .previous: "Go back a song."
        }
        return PreparedDeviceAction(summary: summary, runReportingStatus: {
            // A Spotify URI implies Spotify when no provider was named.
            let ask = requested ?? (uri != nil ? .spotifyApp : nil)
            let choice = MusicProviderSelector.select(
                requested: ask, preferred: await preferred(), availability: await availability())
            guard case .use(let provider) = choice else {
                if case .unavailable(let reason) = choice {
                    throw DeviceActionError.unsupported(reason, status: .manualUserStep)
                }
                throw DeviceActionError.unsupported("No music service is available.")
            }
            guard let control = controls[provider] else {
                throw DeviceActionError.unsupported("\(provider.displayName) is not available on this device.")
            }
            let outcome = try await control.perform(action, query: query, uri: provider == .spotifyApp ? uri : nil)
            var result: JSONObject = [:]
            if let title = outcome.title {
                var now: JSONObject = ["title": .string(title), "provider": .string(provider.rawValue)]
                now["artist"] = outcome.artist.map(JSONValue.string) ?? .null
                result["now_playing"] = .object(now)
            }
            return DeviceActionOutput(result: result, status: outcome.status)
        })
    }
}
