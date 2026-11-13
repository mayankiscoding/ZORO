import Foundation
import ZoroCore

// Mirrors backend/app/music (schemas.py, api.py, speech.py). The server holds the Spotify connection and the shared session
// context; Apple Music is played by this device.

public enum MusicProvider: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
    case spotify
    case appleMusic = "apple_music"

    public var id: String { rawValue }
    public var title: String { self == .spotify ? "Spotify" : "Apple Music" }
    public var service: MusicService { self == .spotify ? .spotify : .appleMusic }

    public init(service: MusicService) { self = service == .spotify ? .spotify : .appleMusic }
}

public struct SpotifyConnection: Sendable, Equatable, Decodable {
    public enum State: String, Sendable, Equatable {
        case notConfigured = "not_configured"
        case notConnected = "not_connected"
        case connected
        case needsReauthorization = "needs_reauthorization"
        /// A state this app does not know (a newer server).
        case unknown
    }

    public var state: State
    public var detail: String

    public init(state: State, detail: String = "") {
        self.state = state
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey { case state, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = State(rawValue: try c.decode(String.self, forKey: .state)) ?? .unknown
        detail = try c.value(.detail, default: "")
    }
}

/// `GET /v1/music/status`.
public struct MusicServerStatus: Sendable, Equatable, Decodable {
    public var spotify: SpotifyConnection
    /// The server's one-line note on how Apple Music is played.
    public var appleMusic: String
    /// `spotify`, `apple_music` or `none`.
    public var providerInUse: String
    /// The server's honest note on recommendations.
    public var recommendations: String

    enum CodingKeys: String, CodingKey {
        case spotify
        case appleMusic = "apple_music"
        case providerInUse = "provider_in_use"
        case recommendations
    }
}

public struct MusicTrackInfo: Sendable, Equatable, Decodable, Identifiable {
    public var uri: String
    public var title: String
    public var artists: [String]
    public var album: String?
    public var playedAt: Date?
    public var id: String { uri }

    enum CodingKeys: String, CodingKey {
        case uri, title, artists, album
        case playedAt = "played_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uri = try c.decode(String.self, forKey: .uri)
        title = try c.decode(String.self, forKey: .title)
        artists = try c.value(.artists, default: [])
        album = try c.decodeIfPresent(String.self, forKey: .album)
        playedAt = try c.decodeIfPresent(Date.self, forKey: .playedAt)
    }

    /// "Artist one, Artist two" or nil.
    public var artistLine: String? { artists.isEmpty ? nil : artists.joined(separator: ", ") }
}

public struct SessionDevice: Sendable, Equatable, Codable {
    public var id: String?
    public var name: String
    public var type: String

    public init(id: String? = nil, name: String, type: String = "") {
        self.id = id
        self.name = name
        self.type = type
    }

    enum CodingKeys: String, CodingKey { case id, name, type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.value(.type, default: "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
    }
}

/// `GET /v1/music/session`: what each device last did, so the iPhone and the Mac agree.
public struct MusicSessionInfo: Sendable, Equatable, Decodable {
    public var provider: MusicProvider?
    public var activeDevice: SessionDevice?
    public var lastQuery: String?
    public var lastTrack: MusicTrackInfo?
    public var updatedAt: Date?
    public var updatedBy: String?

    public init(provider: MusicProvider? = nil, activeDevice: SessionDevice? = nil, lastQuery: String? = nil) {
        self.provider = provider
        self.activeDevice = activeDevice
        self.lastQuery = lastQuery
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case activeDevice = "active_device"
        case lastQuery = "last_query"
        case lastTrack = "last_track"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider).flatMap(MusicProvider.init(rawValue:))
        activeDevice = try c.decodeIfPresent(SessionDevice.self, forKey: .activeDevice)
        lastQuery = try c.decodeIfPresent(String.self, forKey: .lastQuery)
        lastTrack = try c.decodeIfPresent(MusicTrackInfo.self, forKey: .lastTrack)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy)
    }
}

/// `PUT /v1/music/session` body. Only the fields that are set are sent (the server merges `exclude_unset`).
public struct MusicSessionUpdate: Sendable, Equatable, Encodable {
    public var provider: MusicProvider?
    public var activeDevice: SessionDevice?
    public var lastQuery: String?

    public init(provider: MusicProvider? = nil, activeDevice: SessionDevice? = nil, lastQuery: String? = nil) {
        self.provider = provider
        self.activeDevice = activeDevice
        self.lastQuery = lastQuery
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case activeDevice = "active_device"
        case lastQuery = "last_query"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(provider?.rawValue, forKey: .provider)
        try c.encodeIfPresent(activeDevice, forKey: .activeDevice)
        try c.encodeIfPresent(lastQuery, forKey: .lastQuery)
    }
}

/// `POST /v1/music/connect`: open `authorizeUrl` in a browser; Spotify redirects to the server, which finishes the sign-in.
public struct SpotifyConnectGrant: Sendable, Equatable, Decodable {
    public var authorizeUrl: String
    public var state: String
    public var expiresAt: Date
    public var redirectUri: String

    enum CodingKeys: String, CodingKey {
        case authorizeUrl = "authorize_url"
        case state
        case expiresAt = "expires_at"
        case redirectUri = "redirect_uri"
    }

    /// Only an https address is opened.
    public var url: URL? {
        guard let url = URL(string: authorizeUrl), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

/// The payload of a `music` card: `tracks` (a search) or `now_playing`, with the provider that answered.
public struct MusicCardPayload: Sendable, Equatable, Decodable {
    public var tracks: [MusicTrackInfo]
    public var nowPlaying: MusicTrackInfo?
    public var provider: String

    enum CodingKeys: String, CodingKey {
        case tracks
        case nowPlaying = "now_playing"
        case provider
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try c.value(.tracks, default: [])
        nowPlaying = try c.decodeIfPresent(MusicTrackInfo.self, forKey: .nowPlaying)
        provider = try c.value(.provider, default: "none")
    }
}
