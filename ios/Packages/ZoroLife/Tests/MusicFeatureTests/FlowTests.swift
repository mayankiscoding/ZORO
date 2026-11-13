import Foundation
import LifeSupport
import Testing
import ZoroCore
@testable import MusicFeature

// MARK: Fakes

final class FakeMusic: MusicControlling, @unchecked Sendable {
    var auth: MediaAuthorization = .authorized
    var playing: NowPlaying?
    var devices: [MusicOutputDevice] = []
    var searchResults: [MusicItem] = []
    var failure: [String: Error] = [:]
    private(set) var calls: [String] = []
    private(set) var lastSearch: MusicSearchQuery?

    private func record(_ name: String) throws {
        calls.append(name)
        if let error = failure[name] { throw error }
    }

    func authorization() async -> MediaAuthorization { auth }
    func search(_ query: MusicSearchQuery) async throws -> [MusicItem] { lastSearch = query; try record("search"); return searchResults }
    func play(_ item: MusicItem?) async throws { try record(item.map { "play:\($0.id)" } ?? "play") }
    func pause() async throws { try record("pause") }
    func skipToNext() async throws { try record("next") }
    func skipToPrevious() async throws { try record("previous") }
    func queue(_ item: MusicItem, at position: QueuePosition) async throws { try record("queue:\(item.id):\(position.rawValue)") }
    func outputDevices() async throws -> [MusicOutputDevice] { try record("devices"); return devices }
    func transfer(toDeviceId deviceId: String) async throws { try record("transfer:\(deviceId)") }
    func nowPlaying() async throws -> NowPlaying? { try record("nowPlaying"); return playing }
}

final class FakeAuthorizer: MusicAuthorizing, @unchecked Sendable {
    var result: MediaAuthorization
    private(set) var count = 0
    init(_ result: MediaAuthorization = .authorized) { self.result = result }
    func requestAuthorization() async -> MediaAuthorization { count += 1; return result }
}

struct FakePlaylists: PlaylistCreating {
    var result: Result<PlaylistOutcome, Error>
    func createPlaylist(named name: String) async throws -> PlaylistOutcome { try result.get() }
}

let song = MusicItem(id: "spotify:track:1", kind: .song, title: "Example title", subtitle: "Example artist", service: .spotify)
let appleSong = MusicItem(id: "i.99", kind: .song, title: "Other", service: .appleMusic)

func connectedServer() throws -> FakeAPI {
    let api = FakeAPI()
    try api.reply(.get, "/v1/music/status", fixture: "status_connected")
    try api.reply(.get, "/v1/music/session", fixture: "session")
    try api.reply(.put, "/v1/music/session", fixture: "session")
    try api.reply(.post, "/v1/music/connect", fixture: "connect")
    api.reply(.post, "/v1/music/disconnect", json: "")
    return api
}

@MainActor
func makeModel(
    api: FakeAPI, music: FakeMusic = FakeMusic(), authorizer: FakeAuthorizer = FakeAuthorizer(),
    playlists: any PlaylistCreating = FakePlaylists(result: .success(.created(message: "Done."))), sleeps: Locked<Int> = Locked(0)
) -> MusicViewModel {
    MusicViewModel(
        music: music, authorizer: authorizer, server: MusicAPIClient(api: api), playlists: playlists, timeZone: kolkata,
        clock: { fixedNow }, sleep: { _ in sleeps.withLock { $0 += 1 } })
}

// MARK: Client

@Suite("Music client requests")
struct MusicClientTests {
    @Test func routes() async throws {
        let api = try connectedServer()
        let client = MusicAPIClient(api: api)
        #expect(try await client.status().spotify.state == .connected)
        #expect(try await client.session().provider == .spotify)
        _ = try await client.updateSession(MusicSessionUpdate(provider: .appleMusic))
        #expect(try await client.beginSpotifyConnection().url != nil)
        try await client.disconnectSpotify()
        #expect(api.calls.get.map { "\($0.method.rawValue) \($0.path)" } == [
            "GET /v1/music/status", "GET /v1/music/session", "PUT /v1/music/session", "POST /v1/music/connect", "POST /v1/music/disconnect",
        ])
        #expect(try bodyObject(api.calls.get[2])["provider"] as? String == "apple_music")
    }
}

// MARK: View model

@Suite("Music view model")
@MainActor
struct MusicViewModelTests {
    @Test func loadsStatusSessionNowPlayingAndDevices() async throws {
        let music = FakeMusic()
        music.playing = NowPlaying(item: song, isPlaying: true, positionSeconds: 10, durationSeconds: 100, deviceName: "iPhone", observedAt: fixedNow)
        music.devices = [MusicOutputDevice(id: "p", name: "iPhone", isActive: true), MusicOutputDevice(id: "m", name: "Mac", isActive: false)]
        let model = makeModel(api: try connectedServer(), music: music)
        #expect(model.screen == .idle)
        await model.load()
        #expect(model.screen == .loaded)
        #expect(model.activeProvider == .spotify)
        #expect(model.nowPlayingPresentation?.title == "Example title")
        #expect(model.deviceChoice.canMove)
        #expect(model.serverFailure == nil)
        #expect(model.canControl)
    }

    @Test func serverDownStillWorksForAppleMusic() async throws {
        let api = FakeAPI()
        api.fail(.get, "/v1/music/status", with: ZoroError.transport("offline"))
        let music = FakeMusic()
        music.auth = .authorized
        let model = makeModel(api: api, music: music)
        await model.load()
        #expect(model.screen == .loaded)
        #expect(model.serverFailure?.kind == .disconnected)
        #expect(model.activeProvider == .appleMusic)
        #expect(model.choice.spotify.sentence.contains("could not be reached"))
        await model.skipNext()
        #expect(music.calls.contains("next"))
        #expect(!model.canCreatePlaylist, "playlists need Spotify")
    }

    @Test func nothingReadyDisablesControlsAndInvitesSetup() async throws {
        let api = FakeAPI()
        try api.reply(.get, "/v1/music/status", fixture: "status_not_configured")
        try api.reply(.get, "/v1/music/session", fixture: "session_empty")
        let music = FakeMusic()
        music.auth = .notDetermined
        let model = makeModel(api: api, music: music)
        await model.load()
        #expect(model.activeProvider == nil)
        #expect(!model.canControl)
        model.searchText = "focus"
        #expect(!model.canSearch)
        #expect(model.choice.appleMusic.readiness == .needsSetup(.allowAppleMusic))
        #expect(!music.calls.contains("devices"), "no device query without a ready provider")
    }

    @Test func allowAppleMusicAsksOnlyWhenTapped() async throws {
        let api = FakeAPI()
        try api.reply(.get, "/v1/music/status", fixture: "status_not_configured")
        try api.reply(.get, "/v1/music/session", fixture: "session_empty")
        let music = FakeMusic()
        music.auth = .notDetermined
        let authorizer = FakeAuthorizer(.authorized)
        let model = makeModel(api: api, music: music, authorizer: authorizer)
        await model.load()
        #expect(authorizer.count == 0)
        let url = await model.perform(.allowAppleMusic)
        #expect(url == nil)
        #expect(authorizer.count == 1)
        #expect(model.appleAuthorization == .authorized)
        #expect(model.activeProvider == .appleMusic)
    }

    @Test func transportCommandsReachThePlayer() async throws {
        let music = FakeMusic()
        music.playing = NowPlaying(item: song, isPlaying: true, observedAt: fixedNow)
        let model = makeModel(api: try connectedServer(), music: music)
        await model.load()
        await model.togglePlayPause()
        music.playing = NowPlaying(item: song, isPlaying: false, observedAt: fixedNow)
        await model.refreshNowPlaying()
        await model.togglePlayPause()
        await model.skipNext()
        await model.skipPrevious()
        #expect(music.calls.filter { ["pause", "play", "next", "previous"].contains($0) } == ["pause", "play", "next", "previous"])
        #expect(model.transportMessage == nil)
    }

    @Test func aPlaybackFailureIsASentence() async throws {
        let music = FakeMusic()
        music.failure["next"] = ZoroError.unavailable(capability: "Spotify playback", reason: "Premium is required")
        let model = makeModel(api: try connectedServer(), music: music)
        await model.load()
        await model.skipNext()
        #expect(model.transportMessage == "Spotify playback is not available: Premium is required.")
        #expect(!model.isTransportBusy)
        await model.skipPrevious()
        #expect(model.transportMessage == nil, "a new command clears the old message")
    }

    @Test func playingASearchResultSavesTheSharedSession() async throws {
        let api = try connectedServer()
        let music = FakeMusic()
        music.searchResults = [song, appleSong]
        let model = makeModel(api: api, music: music)
        await model.load()
        model.searchText = "focus music"
        #expect(model.canSearch)
        await model.search()
        #expect(model.searchPhase == .results)
        #expect(music.lastSearch?.service == .spotify, "the search asks the active provider")
        #expect(music.lastSearch?.text == "focus music")
        await model.play(song)
        #expect(music.calls.contains("play:spotify:track:1"))
        let put = try #require(api.requests("/v1/music/session").last { $0.method == .put })
        let body = try bodyObject(put)
        #expect(body["provider"] as? String == "spotify")
        #expect(body["last_query"] as? String == "focus music")
        await model.queueNext(song)
        #expect(music.calls.contains("queue:spotify:track:1:next"))
    }

    @Test func searchStates() async throws {
        let music = FakeMusic()
        let model = makeModel(api: try connectedServer(), music: music)
        await model.load()
        model.searchText = "zzz"
        await model.search()
        #expect(model.searchPhase == .noResults)
        music.failure["search"] = ZoroError.transport("offline")
        await model.search()
        guard case .failed(let f) = model.searchPhase else { Issue.record("expected failure"); return }
        #expect(f.kind == .disconnected)
        #expect(model.results.isEmpty)
    }

    @Test func choosingAProviderIsSavedAndOnlyWhenReady() async throws {
        let api = try connectedServer()
        let music = FakeMusic()
        music.auth = .denied
        let model = makeModel(api: api, music: music)
        await model.load()
        let before = api.requests("/v1/music/session").count
        await model.selectProvider(.appleMusic)
        #expect(api.requests("/v1/music/session").count == before, "a provider that is not ready is not saved")
        music.auth = .authorized
        await model.load()
        await model.selectProvider(.appleMusic)
        let put = try #require(api.requests("/v1/music/session").last { $0.method == .put })
        #expect(try bodyObject(put)["provider"] as? String == "apple_music")
    }

    @Test func movingPlaybackBetweenIPhoneAndMac() async throws {
        let api = try connectedServer()
        let music = FakeMusic()
        music.devices = [MusicOutputDevice(id: "p", name: "iPhone", isActive: true), MusicOutputDevice(id: "m", name: "Mac", isActive: false)]
        let model = makeModel(api: api, music: music)
        await model.load()
        let target = try #require(model.deviceChoice.targets.first)
        await model.move(to: target)
        #expect(music.calls.contains("transfer:m"))
        let put = try #require(api.requests("/v1/music/session").last { $0.method == .put })
        let device = try #require(try bodyObject(put)["active_device"] as? [String: Any])
        #expect(device["id"] as? String == "m" && device["name"] as? String == "Mac")
    }

    @Test func appleMusicNeverTriesToTransfer() async throws {
        let api = FakeAPI()
        try api.reply(.get, "/v1/music/status", fixture: "status_not_configured")
        try api.reply(.get, "/v1/music/session", fixture: "session_empty")
        let music = FakeMusic()
        music.devices = [MusicOutputDevice(id: "p", name: "iPhone", isActive: true), MusicOutputDevice(id: "m", name: "Mac", isActive: false)]
        let model = makeModel(api: api, music: music)
        await model.load()
        #expect(model.activeProvider == .appleMusic)
        #expect(!model.deviceChoice.canMove)
        await model.move(to: DeviceChoice.Row(id: "m", name: "Mac", isActive: false))
        #expect(!music.calls.contains { $0.hasPrefix("transfer") })
    }

    @Test func aFailedTransferDoesNotTellTheServer() async throws {
        let api = try connectedServer()
        let music = FakeMusic()
        music.devices = [MusicOutputDevice(id: "p", name: "iPhone", isActive: true), MusicOutputDevice(id: "m", name: "Mac", isActive: false)]
        music.failure["transfer:m"] = ZoroError.unavailable(capability: "Spotify", reason: "no active device")
        let model = makeModel(api: api, music: music)
        await model.load()
        let puts = api.requests("/v1/music/session").filter { $0.method == .put }.count
        await model.move(to: DeviceChoice.Row(id: "m", name: "Mac", isActive: false))
        #expect(model.transportMessage == "Spotify is not available: no active device.")
        #expect(api.requests("/v1/music/session").filter { $0.method == .put }.count == puts)
    }

    @Test func spotifyConnectionOpensAnHTTPSAddress() async throws {
        let api = try connectedServer()
        let model = makeModel(api: api)
        await model.load()
        let url = await model.perform(.connectSpotify)
        #expect(url?.host == "accounts.spotify.com")
        api.reply(.post, "/v1/music/connect", json: #"{"authorize_url":"spotify://x","state":"s","expires_at":"2026-11-13T12:10:00Z","redirect_uri":"https://z/v1/music/callback"}"#)
        #expect(await model.beginSpotifyConnection() == nil)
        #expect(model.transportMessage == "Spotify sent back an address that is not safe to open. Try connecting again.")
    }

    @Test func connectErrorsExplainTheNextStep() async throws {
        let api = try connectedServer()
        api.fail(.post, "/v1/music/connect", with: ZoroError.http(status: 503, body: ErrorBody(code: "requires_credentials", message: "Spotify needs SPOTIFY_CLIENT_ID on the server")))
        let model = makeModel(api: api)
        #expect(await model.beginSpotifyConnection() == nil)
        #expect(model.transportMessage == "Spotify needs SPOTIFY_CLIENT_ID on the server. Try again in a moment.")
    }

    @Test func disconnectReloadsTheStatus() async throws {
        let api = try connectedServer()
        let model = makeModel(api: api)
        await model.load()
        try api.reply(.get, "/v1/music/status", fixture: "status_not_configured")
        await model.disconnectSpotify()
        #expect(api.requests("/v1/music/disconnect").count == 1)
        #expect(model.serverStatus?.spotify.state == .notConfigured)
    }

    @Test func returningFromTheBrowserRefreshesTheConnection() async throws {
        let api = try connectedServer()
        try api.reply(.get, "/v1/music/status", fixture: "status_reauth")
        let model = makeModel(api: api)
        await model.load()
        #expect(model.choice.spotify.readiness == .needsSetup(.connectSpotify))
        try api.reply(.get, "/v1/music/status", fixture: "status_connected")
        await model.loadServer()
        #expect(model.choice.spotify.isReady)
    }

    @Test func playlistsGoThroughAnApprovedTurn() async throws {
        let model = makeModel(api: try connectedServer(), playlists: FakePlaylists(result: .success(.waitingForApproval(title: "Create the playlist “Road trip”"))))
        await model.load()
        #expect(!model.canCreatePlaylist)
        model.playlistName = "Road trip"
        #expect(model.canCreatePlaylist)
        await model.createPlaylist()
        #expect(model.playlist == .done("Create the playlist “Road trip”. ZORO is waiting for your approval. Open Activity to review it."))
        let created = makeModel(api: try connectedServer(), playlists: FakePlaylists(result: .success(.created(message: "Playlist Road Trip created with 0 songs."))))
        await created.load()
        created.playlistName = "Road Trip"
        await created.createPlaylist()
        #expect(created.playlist == .done("Playlist Road Trip created with 0 songs."))
        #expect(created.playlistName == "")
        let failing = makeModel(api: try connectedServer(), playlists: FakePlaylists(result: .failure(ZoroError.timeout)))
        await failing.load()
        failing.playlistName = "x"
        await failing.createPlaylist()
        guard case .failed(let message) = failing.playlist else { Issue.record("expected failure"); return }
        #expect(message.hasPrefix("Could not reach your ZORO server."))
    }

    @Test func nowPlayingPollingUsesTheInjectedSleep() async throws {
        let music = FakeMusic()
        let sleeps = Locked(0)
        let model = makeModel(api: try connectedServer(), music: music, sleeps: sleeps)
        let task = Task { await model.monitorNowPlaying() }
        for _ in 0..<200 where sleeps.get < 3 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(sleeps.get >= 3)
        #expect(music.calls.filter { $0 == "nowPlaying" }.count >= 2)
    }
}

// MARK: Playlist turns

@Suite("Playlist creation by turn")
struct PlaylistTurnTests {
    func approval() -> ApprovalRequest {
        ApprovalRequest(
            approvalId: "a1", tool: "music.create_playlist", risk: .medium, level: .confirm, title: "Create the playlist “Road Trip”",
            summary: "Road Trip (private, 0 songs)", actionDigest: "abc", expiresAt: fixedNow.addingTimeInterval(120))
    }

    @Test func sendsACreatePlaylistTurnWithAPlainName() async throws {
        let api = FakeAPI()
        api.turnEvents.withLock { $0 = [.textDelta(TextDelta(text: "Playlist Road Trip created with 0 songs."))] }
        let creator = TurnPlaylistCreator(api: api, platform: .ios, timeZone: kolkata)
        let outcome = try await creator.createPlaylist(named: "  \u{201C}Road \"Trip\"\u{201D}  ")
        #expect(outcome == .created(message: "Playlist Road Trip created with 0 songs."))
        let turn = try #require(api.turns.get.first)
        #expect(turn.input.text == "Create a playlist called Road Trip")
        #expect(turn.client.platform == .ios)
        #expect(turn.client.timezone == "Asia/Kolkata")
    }

    @Test func anApprovalRequestMeansWaiting() async throws {
        let api = FakeAPI()
        api.turnEvents.withLock { $0 = [.approvalRequired(ApprovalRequired(approval: approval()))] }
        let outcome = try await TurnPlaylistCreator(api: api, platform: .macos).createPlaylist(named: "Road Trip")
        #expect(outcome == .waitingForApproval(title: "Create the playlist “Road Trip”"))
    }

    @Test func errorsAndEmptyNamesAreTyped() async throws {
        let api = FakeAPI()
        api.turnEvents.withLock { $0 = [.error(TurnError(code: "denied", message: "Spotify is not connected."))] }
        await #expect(throws: ZoroError.self) { try await TurnPlaylistCreator(api: api, platform: .ios).createPlaylist(named: "x") }
        await #expect(throws: ZoroError.self) { try await TurnPlaylistCreator(api: api, platform: .ios).createPlaylist(named: " \" ") }
        api.turnEvents.withLock { $0 = [.toolFinished(ToolFinished(callId: "c", ok: false, durationMs: 1, summary: "Spotify said no"))] }
        do {
            _ = try await TurnPlaylistCreator(api: api, platform: .ios).createPlaylist(named: "x")
            Issue.record("expected a failure")
        } catch let ZoroError.unavailable(_, reason) {
            #expect(reason == "Spotify said no")
        }
    }
}
