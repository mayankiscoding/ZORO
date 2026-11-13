import Foundation
import LifeSupport
import Observation
import ZoroCore

public enum MusicSearchPhase: Sendable, Equatable {
    case idle
    case searching
    case results
    case noResults
    case failed(ScreenFailure)
}

public enum PlaylistPhase: Sendable, Equatable {
    case idle
    case creating
    case done(String)
    case failed(String)
}

/// State and actions of the music screen. Playback goes through `MusicControlling` on this device; the Spotify connection and
/// the shared session (provider, active device) live on the server. The screen works without the server for Apple Music.
@MainActor @Observable
public final class MusicViewModel {
    public private(set) var screen: ScreenPhase = .idle
    public private(set) var serverStatus: MusicServerStatus?
    /// Why the server could not be asked (shown as a notice; Apple Music still works).
    public private(set) var serverFailure: ScreenFailure?
    public private(set) var session: MusicSessionInfo?
    public private(set) var appleAuthorization: MediaAuthorization = .notDetermined
    public private(set) var nowPlaying: NowPlaying?
    public private(set) var devices: [MusicOutputDevice] = []
    public private(set) var devicesFailure: String?
    /// The last playback problem, as a sentence with what to do.
    public private(set) var transportMessage: String?
    public private(set) var isTransportBusy = false
    public var searchText = ""
    public private(set) var searchPhase: MusicSearchPhase = .idle
    public private(set) var results: [MusicItem] = []
    public private(set) var playlist: PlaylistPhase = .idle
    public var playlistName = ""
    public private(set) var now: Date

    private let music: any MusicControlling
    private let authorizer: any MusicAuthorizing
    private let server: any MusicServing
    private let playlists: any PlaylistCreating
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone
    private let sleep: LifeSleep

    public init(
        music: any MusicControlling, authorizer: any MusicAuthorizing, server: any MusicServing, playlists: any PlaylistCreating,
        timeZone: TimeZone = .current, clock: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping LifeSleep = LifeSleeper.real
    ) {
        self.music = music
        self.authorizer = authorizer
        self.server = server
        self.playlists = playlists
        self.timeZone = timeZone
        self.clock = clock
        self.sleep = sleep
        self.now = clock()
    }

    public convenience init(services: ZoroServices, authorizer: any MusicAuthorizing, platform: DevicePlatform) {
        self.init(
            music: services.music, authorizer: authorizer, server: MusicAPIClient(api: services.api),
            playlists: TurnPlaylistCreator(api: services.api, platform: platform))
    }

    // MARK: Derived

    public var choice: MusicProviderChoice {
        MusicSelection.choose(preferred: session?.provider, status: serverStatus, appleAuthorization: appleAuthorization)
    }

    public var activeProvider: MusicProvider? { choice.active }

    public var nowPlayingPresentation: NowPlayingPresentation? { NowPlayingPresenter.presentation(nowPlaying, now: now, timeZone: timeZone) }

    public var deviceChoice: DeviceChoice {
        DeviceSelection.choice(devices: devices, session: session?.activeDevice, provider: activeProvider)
    }

    public var canControl: Bool { activeProvider != nil }

    public var canSearch: Bool { canControl && !searchText.trimmingCharacters(in: .whitespaces).isEmpty && searchPhase != .searching }

    /// Playlists are made in the owner's Spotify account, so they need Spotify to be connected.
    public var canCreatePlaylist: Bool {
        choice.spotify.isReady && !playlistName.trimmingCharacters(in: .whitespaces).isEmpty && playlist != .creating
    }

    // MARK: Loading

    public func load() async {
        now = clock()
        if screen == .idle || screen.failure != nil { screen = .loading }
        appleAuthorization = await music.authorization()
        await loadServer()
        await refreshNowPlaying()
        await refreshDevices()
        screen = .loaded
    }

    /// Reloads the Spotify connection and the shared session, for example after returning from the browser sign-in.
    public func loadServer() async {
        do {
            serverStatus = try await server.status()
            session = try await server.session()
            serverFailure = nil
        } catch {
            serverFailure = ScreenFailure.from(error, subject: "your music settings")
            serverStatus = nil
        }
    }

    public func refreshNowPlaying() async {
        do {
            nowPlaying = try await music.nowPlaying()
        } catch {
            nowPlaying = nil
            if canControl { transportMessage = ScreenFailure.from(error, subject: "what is playing").message }
        }
        now = clock()
    }

    public func refreshDevices() async {
        guard canControl else {
            devices = []
            return
        }
        do {
            devices = try await music.outputDevices()
            devicesFailure = nil
        } catch {
            devices = []
            devicesFailure = ScreenFailure.from(error, subject: "your devices").message
        }
    }

    /// Polls what is playing while the screen is visible. Ends when the task is cancelled.
    public func monitorNowPlaying() async {
        while !Task.isCancelled {
            try? await sleep(.seconds(5))
            if Task.isCancelled { return }
            await refreshNowPlaying()
        }
    }

    // MARK: Access and connections

    public func perform(_ action: ProviderState.Action) async -> URL? {
        switch action {
        case .allowAppleMusic:
            appleAuthorization = await authorizer.requestAuthorization()
            await refreshDevices()
            return nil
        case .connectSpotify:
            return await beginSpotifyConnection()
        }
    }

    /// Asks the server to start the Spotify sign-in and returns the https address to open in the browser.
    public func beginSpotifyConnection() async -> URL? {
        do {
            let grant = try await server.beginSpotifyConnection()
            guard let url = grant.url else {
                transportMessage = "Spotify sent back an address that is not safe to open. Try connecting again."
                return nil
            }
            return url
        } catch {
            transportMessage = ScreenFailure.from(error, subject: "the Spotify sign-in").message
            return nil
        }
    }

    public func disconnectSpotify() async {
        do {
            try await server.disconnectSpotify()
            await loadServer()
            await refreshDevices()
        } catch {
            transportMessage = ScreenFailure.from(error, subject: "Spotify").message
        }
    }

    public func selectProvider(_ provider: MusicProvider) async {
        guard choice.state(for: provider).isReady else { return }
        await saveSession(MusicSessionUpdate(provider: provider))
        await refreshDevices()
    }

    // MARK: Transport

    public func togglePlayPause() async {
        if nowPlaying?.isPlaying == true {
            await transport { try await $0.pause() }
        } else {
            await transport { try await $0.play(nil) }
        }
    }

    public func skipNext() async { await transport { try await $0.skipToNext() } }
    public func skipPrevious() async { await transport { try await $0.skipToPrevious() } }

    public func play(_ item: MusicItem) async {
        await transport { try await $0.play(item) }
        await saveSession(MusicSessionUpdate(provider: MusicProvider(service: item.service), lastQuery: searchText.isEmpty ? nil : searchText))
    }

    public func queueNext(_ item: MusicItem) async { await transport { try await $0.queue(item, at: .next) } }

    private func transport(_ action: @Sendable (any MusicControlling) async throws -> Void) async {
        guard !isTransportBusy else { return }
        isTransportBusy = true
        transportMessage = nil
        defer { isTransportBusy = false }
        do {
            try await action(music)
            await refreshNowPlaying()
        } catch {
            transportMessage = ScreenFailure.from(error, subject: "playback").message
        }
    }

    /// Moves playback to another device, then tells the server so the iPhone and the Mac agree.
    public func move(to row: DeviceChoice.Row) async {
        guard deviceChoice.canMove else { return }
        await transport { try await $0.transfer(toDeviceId: row.id) }
        if transportMessage == nil {
            await refreshDevices()
            await saveSession(MusicSessionUpdate(activeDevice: SessionDevice(id: row.id, name: row.name)))
        }
    }

    private func saveSession(_ update: MusicSessionUpdate) async {
        do {
            session = try await server.updateSession(update)
        } catch {
            // The change worked on this device; only the shared note could not be saved.
            serverFailure = ScreenFailure.from(error, subject: "your music settings")
        }
    }

    // MARK: Search

    public func search() async {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard canSearch, let provider = activeProvider else { return }
        searchPhase = .searching
        do {
            let found = try await music.search(MusicSearchQuery(text: text, kinds: [.song, .album, .playlist], service: provider.service, limit: 20))
            results = found
            searchPhase = found.isEmpty ? .noResults : .results
        } catch {
            results = []
            searchPhase = .failed(ScreenFailure.from(error, subject: "music search"))
        }
    }

    // MARK: Playlists

    public func createPlaylist() async {
        guard canCreatePlaylist else { return }
        playlist = .creating
        do {
            switch try await playlists.createPlaylist(named: playlistName) {
            case .created(let message):
                playlist = .done(message.isEmpty ? "Your playlist was created." : message)
                playlistName = ""
            case .waitingForApproval(let title):
                playlist = .done("\(title). ZORO is waiting for your approval. Open Activity to review it.")
            }
        } catch {
            playlist = .failed(ScreenFailure.from(error, subject: "the playlist").message)
        }
    }
}
