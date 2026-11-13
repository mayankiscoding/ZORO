import Foundation
import ZoroCore

/// MusicKit, behind a protocol (system implementation: `MusicKitBackend`).
public protocol AppleMusicBackend: Sendable {
    func authorizationStatus() async -> MediaAuthorization
    func requestAuthorization() async -> MediaAuthorization
    func canPlayCatalogContent() async throws -> Bool
    func searchCatalog(_ term: String, kinds: [MusicItem.Kind], limit: Int) async throws -> [MusicItem]
    func libraryPlaylists(limit: Int) async throws -> [MusicItem]
    func play(_ item: MusicItem) async throws
    func resume() async throws
    func pause() async
    func skipToNext() async throws
    func skipToPrevious() async throws
    func enqueue(_ item: MusicItem, at position: QueuePosition) async throws
    func nowPlaying() async -> NowPlaying?
}

/// `MusicControlling` for Apple Music: authorisation in context, subscription check before catalogue
/// playback, typed "unavailable" for what MusicKit cannot do (output routing).
public struct AppleMusicController: MusicControlling {
    let backend: any AppleMusicBackend

    public init(backend: any AppleMusicBackend) { self.backend = backend }

    func ensureAuthorized() async throws {
        var status = await backend.authorizationStatus()
        if status == .notDetermined { status = await backend.requestAuthorization() }
        guard status == .authorized else {
            throw ZoroError.unavailable(capability: "Apple Music", reason: "access was not allowed; allow it in Settings")
        }
    }

    func ensureCatalogPlayback() async throws {
        guard try await backend.canPlayCatalogContent() else {
            throw ZoroError.unavailable(capability: "Apple Music", reason: "playing from the catalogue needs an Apple Music subscription")
        }
    }

    public func authorization() async -> MediaAuthorization { await backend.authorizationStatus() }

    public func search(_ query: MusicSearchQuery) async throws -> [MusicItem] {
        if let service = query.service, service != .appleMusic {
            throw ZoroError.unavailable(capability: "Spotify search", reason: "needs a Spotify Web API connection")
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        try await ensureAuthorized()
        let limit = max(1, min(query.limit, 25))
        return try await backend.searchCatalog(text, kinds: query.kinds.isEmpty ? [.song] : query.kinds, limit: limit)
    }

    public func libraryPlaylists(limit: Int = 50) async throws -> [MusicItem] {
        try await ensureAuthorized()
        return try await backend.libraryPlaylists(limit: max(1, min(limit, 200)))
    }

    public func play(_ item: MusicItem?) async throws {
        try await ensureAuthorized()
        guard let item else {
            try await backend.resume()
            return
        }
        guard item.service == .appleMusic else {
            throw ZoroError.unavailable(capability: "Apple Music", reason: "that item is from another service")
        }
        if !Self.isLibraryItem(item) { try await ensureCatalogPlayback() }
        try await backend.play(item)
    }

    /// Searches the catalogue and plays the first song.
    public func searchAndPlay(_ text: String) async throws -> MusicItem? {
        guard let first = try await search(MusicSearchQuery(text: text, kinds: [.song], limit: 1)).first else { return nil }
        try await play(first)
        return first
    }

    public func pause() async throws {
        try await ensureAuthorized()
        await backend.pause()
    }

    public func skipToNext() async throws {
        try await ensureAuthorized()
        try await backend.skipToNext()
    }

    public func skipToPrevious() async throws {
        try await ensureAuthorized()
        try await backend.skipToPrevious()
    }

    public func queue(_ item: MusicItem, at position: QueuePosition) async throws {
        try await ensureAuthorized()
        guard item.service == .appleMusic else {
            throw ZoroError.unavailable(capability: "Apple Music", reason: "that item is from another service")
        }
        if !Self.isLibraryItem(item) { try await ensureCatalogPlayback() }
        try await backend.enqueue(item, at: position)
    }

    public func outputDevices() async throws -> [MusicOutputDevice] {
        throw ZoroError.unavailable(capability: "Output devices", reason: "MusicKit does not expose audio routes; use the AirPlay button")
    }

    public func transfer(toDeviceId deviceId: String) async throws {
        throw ZoroError.unavailable(capability: "Output devices", reason: "MusicKit does not expose audio routes; use the AirPlay button")
    }

    public func nowPlaying() async throws -> NowPlaying? {
        guard await backend.authorizationStatus() == .authorized else { return nil }
        return await backend.nowPlaying()
    }

    /// Library identifiers (`i.…`, `p.…`, `l.…`) do not need a subscription to play.
    static func isLibraryItem(_ item: MusicItem) -> Bool {
        item.id.count > 2 && item.id.dropFirst().first == "." && "ipl".contains(item.id.first!)
    }
}
