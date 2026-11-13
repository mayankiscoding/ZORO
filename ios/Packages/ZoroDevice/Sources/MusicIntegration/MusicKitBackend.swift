#if canImport(MusicKit)
import Foundation
@preconcurrency import MusicKit
import ZoroCore

/// `AppleMusicBackend` over MusicKit and `ApplicationMusicPlayer` (iOS 15+, macOS 14+). Needs the
/// MusicKit app service for the bundle id and `NSAppleMusicUsageDescription`.
/// ZORO's model type (MusicKit has its own `MusicItem`).
public typealias ZoroMusicItem = ZoroCore.MusicItem

@MainActor
public final class MusicKitBackend: AppleMusicBackend {
    public init() {}

    private var player: ApplicationMusicPlayer { ApplicationMusicPlayer.shared }

    private static func map(_ s: MusicAuthorization.Status) -> MediaAuthorization {
        switch s {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    public func authorizationStatus() async -> MediaAuthorization { Self.map(MusicAuthorization.currentStatus) }

    public func requestAuthorization() async -> MediaAuthorization { Self.map(await MusicAuthorization.request()) }

    public func canPlayCatalogContent() async throws -> Bool {
        try await MusicSubscription.current.canPlayCatalogContent
    }

    private static func item(_ id: MusicItemID, _ kind: ZoroMusicItem.Kind, _ title: String, _ subtitle: String?, _ art: Artwork?) -> ZoroMusicItem {
        ZoroMusicItem(
            id: id.rawValue, kind: kind, title: title, subtitle: subtitle, service: .appleMusic,
            artworkURL: art?.url(width: 300, height: 300))
    }

    public func searchCatalog(_ term: String, kinds: [ZoroMusicItem.Kind], limit: Int) async throws -> [ZoroMusicItem] {
        var types: [any MusicCatalogSearchable.Type] = []
        for k in kinds {
            switch k {
            case .song: types.append(Song.self)
            case .album: types.append(Album.self)
            case .playlist: types.append(Playlist.self)
            case .artist: types.append(Artist.self)
            case .station: types.append(Station.self)
            }
        }
        var request = MusicCatalogSearchRequest(term: term, types: types)
        request.limit = limit
        let r = try await request.response()
        var out: [ZoroMusicItem] = []
        out += r.songs.map { Self.item($0.id, .song, $0.title, $0.artistName, $0.artwork) }
        out += r.albums.map { Self.item($0.id, .album, $0.title, $0.artistName, $0.artwork) }
        out += r.playlists.map { Self.item($0.id, .playlist, $0.name, $0.curatorName, $0.artwork) }
        out += r.artists.map { Self.item($0.id, .artist, $0.name, nil, $0.artwork) }
        out += r.stations.map { Self.item($0.id, .station, $0.name, nil, $0.artwork) }
        return out
    }

    public func libraryPlaylists(limit: Int) async throws -> [ZoroMusicItem] {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = limit
        return try await request.response().items.map { Self.item($0.id, .playlist, $0.name, $0.curatorName, $0.artwork) }
    }

    private func setQueue(for item: ZoroMusicItem) async throws {
        let id = MusicItemID(item.id)
        switch item.kind {
        case .song:
            guard let song = try await MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id).response().items.first
            else { throw ZoroError.unavailable(capability: "Apple Music", reason: "that song was not found") }
            player.queue = [song]
        case .album:
            guard let album = try await MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: id).response().items.first
            else { throw ZoroError.unavailable(capability: "Apple Music", reason: "that album was not found") }
            player.queue = [album]
        case .playlist:
            var library = MusicLibraryRequest<Playlist>()
            library.filter(matching: \.id, equalTo: id)
            if let playlist = try await library.response().items.first {
                player.queue = [playlist]
            } else if let playlist = try await MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id).response().items.first {
                player.queue = [playlist]
            } else {
                throw ZoroError.unavailable(capability: "Apple Music", reason: "that playlist was not found")
            }
        case .station:
            guard let station = try await MusicCatalogResourceRequest<Station>(matching: \.id, equalTo: id).response().items.first
            else { throw ZoroError.unavailable(capability: "Apple Music", reason: "that station was not found") }
            player.queue = [station]
        case .artist:
            throw ZoroError.unavailable(capability: "Apple Music", reason: "pick a song, album or playlist by that artist")
        }
    }

    public func play(_ item: ZoroMusicItem) async throws {
        try await setQueue(for: item)
        try await player.play()
    }

    public func resume() async throws { try await player.play() }
    public func pause() async { player.pause() }
    public func skipToNext() async throws { try await player.skipToNextEntry() }
    public func skipToPrevious() async throws { try await player.skipToPreviousEntry() }

    public func enqueue(_ item: ZoroMusicItem, at position: QueuePosition) async throws {
        guard item.kind == .song else {
            throw ZoroError.unavailable(capability: "Apple Music", reason: "only songs can be added to the queue")
        }
        guard let song = try await MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(item.id)).response().items.first
        else { throw ZoroError.unavailable(capability: "Apple Music", reason: "that song was not found") }
        try await player.queue.insert(song, position: position == .next ? .afterCurrentEntry : .tail)
    }

    public func nowPlaying() async -> NowPlaying? {
        guard let entry = player.queue.currentEntry else { return nil }
        let item = ZoroMusicItem(
            id: entry.id, kind: .song, title: entry.title, subtitle: entry.subtitle, service: .appleMusic,
            artworkURL: entry.artwork?.url(width: 300, height: 300))
        return NowPlaying(
            item: item, isPlaying: player.state.playbackStatus == .playing, positionSeconds: player.playbackTime,
            observedAt: Date())
    }
}
#endif
