import Foundation
import ZoroCore

/// What the music screen needs from the server.
public protocol MusicServing: Sendable {
    func status() async throws -> MusicServerStatus
    func session() async throws -> MusicSessionInfo
    func updateSession(_ update: MusicSessionUpdate) async throws -> MusicSessionInfo
    func beginSpotifyConnection() async throws -> SpotifyConnectGrant
    func disconnectSpotify() async throws
}

/// Typed requests against `/v1/music`. Search, play and skip are device actions (see `MusicControlling`) or tools the
/// server runs inside a turn; the server has no REST route for them.
public struct MusicAPIClient: MusicServing {
    public let api: any ZoroAPI
    public init(api: any ZoroAPI) { self.api = api }

    public func status() async throws -> MusicServerStatus {
        try await api.send(.get("/v1/music/status"), as: MusicServerStatus.self)
    }

    public func session() async throws -> MusicSessionInfo {
        try await api.send(.get("/v1/music/session"), as: MusicSessionInfo.self)
    }

    public func updateSession(_ update: MusicSessionUpdate) async throws -> MusicSessionInfo {
        try await api.send(try .json(.put, "/v1/music/session", body: update), as: MusicSessionInfo.self)
    }

    public func beginSpotifyConnection() async throws -> SpotifyConnectGrant {
        try await api.send(APIRequest(method: .post, path: "/v1/music/connect", body: Data("{}".utf8)), as: SpotifyConnectGrant.self)
    }

    public func disconnectSpotify() async throws {
        try await api.send(APIRequest(method: .post, path: "/v1/music/disconnect"))
    }
}
