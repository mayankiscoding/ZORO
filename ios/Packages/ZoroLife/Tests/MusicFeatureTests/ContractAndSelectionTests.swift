import Foundation
import Testing
import ZoroCore
@testable import MusicFeature

let kolkata = TimeZone(identifier: "Asia/Kolkata")!
let fixedNow = ZoroJSON.parseDate("2026-11-13T12:00:00Z")!

@Suite("Music contract: DTOs decode the server's real JSON")
struct MusicContractTests {
    @Test func statusStates() throws {
        let connected = try Fixtures.decode(MusicServerStatus.self, "status_connected")
        #expect(connected.spotify.state == .connected)
        #expect(connected.providerInUse == "spotify")
        #expect(connected.recommendations.hasPrefix("Unavailable: Spotify removed recommendations"))
        #expect(connected.appleMusic.contains("device.music.control"))
        #expect(try Fixtures.decode(MusicServerStatus.self, "status_not_configured").spotify.state == .notConfigured)
        #expect(try Fixtures.decode(MusicServerStatus.self, "status_reauth").spotify.state == .needsReauthorization)
    }

    @Test func unknownSpotifyStateDoesNotBreakDecoding() throws {
        let json = #"{"spotify":{"state":"on_fire","detail":"x"},"apple_music":"a","provider_in_use":"none","recommendations":"r"}"#
        let s = try ZoroJSON.decoder().decode(MusicServerStatus.self, from: Data(json.utf8))
        #expect(s.spotify.state == .unknown)
        #expect(MusicSelection.spotifyState(s).readiness == .unavailable)
    }

    @Test func session() throws {
        let s = try Fixtures.decode(MusicSessionInfo.self, "session")
        #expect(s.provider == .spotify)
        #expect(s.activeDevice == SessionDevice(id: "abc123", name: "Mac", type: "Computer"))
        #expect(s.lastQuery == "focus music")
        #expect(s.lastTrack?.title == "Example title")
        #expect(s.lastTrack?.artistLine == "Example artist")
        #expect(s.updatedBy == "dev-1")
        let empty = try Fixtures.decode(MusicSessionInfo.self, "session_empty")
        #expect(empty.provider == nil && empty.activeDevice == nil && empty.lastTrack == nil)
    }

    @Test func connectGrantOnlyOpensHTTPS() throws {
        let grant = try Fixtures.decode(SpotifyConnectGrant.self, "connect")
        #expect(grant.url?.host == "accounts.spotify.com")
        #expect(grant.state == "s")
        var bad = grant
        bad.authorizeUrl = "spotify://authorize"
        #expect(bad.url == nil)
        bad.authorizeUrl = "javascript:alert(1)"
        #expect(bad.url == nil)
    }

    @Test func cards() throws {
        let songs = try Fixtures.card("card_songs").decodePayload(MusicCardPayload.self)
        #expect(songs.tracks.count == 1)
        #expect(songs.tracks[0].uri == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        #expect(songs.tracks[0].album == "Example album")
        #expect(songs.nowPlaying == nil)
        #expect(songs.provider == "spotify")
        let now = try Fixtures.card("card_now_playing").decodePayload(MusicCardPayload.self)
        #expect(now.nowPlaying?.title == "Example title")
        #expect(now.tracks.isEmpty)
    }

    @Test func sessionUpdateSendsOnlyWhatChanged() throws {
        func keys(_ u: MusicSessionUpdate) throws -> Set<String> {
            let object = try #require(try JSONSerialization.jsonObject(with: ZoroJSON.encoder().encode(u)) as? [String: Any])
            return Set(object.keys)
        }
        #expect(try keys(MusicSessionUpdate(provider: .appleMusic)) == ["provider"])
        #expect(try keys(MusicSessionUpdate(activeDevice: SessionDevice(id: "1", name: "Mac"))) == ["active_device"])
        #expect(try keys(MusicSessionUpdate(provider: .spotify, lastQuery: "x")) == ["provider", "last_query"])
        let object = try #require(try JSONSerialization.jsonObject(with: ZoroJSON.encoder().encode(MusicSessionUpdate(provider: .appleMusic))) as? [String: Any])
        #expect(object["provider"] as? String == "apple_music")
    }

    @Test func providerMapping() {
        #expect(MusicProvider.spotify.service == .spotify)
        #expect(MusicProvider(service: .appleMusic) == .appleMusic)
        #expect(MusicProvider.appleMusic.title == "Apple Music")
    }
}

@Suite("Music provider selection")
struct ProviderSelectionTests {
    func status(_ name: String) throws -> MusicServerStatus { try Fixtures.decode(MusicServerStatus.self, name) }

    @Test func spotifyConnectedWinsByDefault() throws {
        let c = MusicSelection.choose(preferred: nil, status: try status("status_connected"), appleAuthorization: .authorized)
        #expect(c.active == .spotify)
        #expect(c.reason == "Spotify is connected, so ZORO uses it.")
        #expect(c.spotify.isReady && c.appleMusic.isReady)
    }

    @Test func theOwnersChoiceWinsWhenReady() throws {
        let c = MusicSelection.choose(preferred: .appleMusic, status: try status("status_connected"), appleAuthorization: .authorized)
        #expect(c.active == .appleMusic)
        #expect(c.reason == "You chose Apple Music.")
    }

    @Test func aChoiceThatIsNotReadyIsSkipped() throws {
        let c = MusicSelection.choose(preferred: .spotify, status: try status("status_reauth"), appleAuthorization: .authorized)
        #expect(c.active == .appleMusic)
        let none = MusicSelection.choose(preferred: .appleMusic, status: try status("status_connected"), appleAuthorization: .denied)
        #expect(none.active == .spotify)
    }

    @Test func appleMusicWhenSpotifyIsNotSetUp() throws {
        let c = MusicSelection.choose(preferred: nil, status: try status("status_not_configured"), appleAuthorization: .authorized)
        #expect(c.active == .appleMusic)
        #expect(c.spotify.readiness == .unavailable)
        #expect(c.spotify.sentence.hasPrefix("Spotify is not set up on your ZORO server."))
    }

    @Test func nothingReadyTellsYouWhatToDo() throws {
        let c = MusicSelection.choose(preferred: nil, status: try status("status_reauth"), appleAuthorization: .notDetermined)
        #expect(c.active == nil)
        #expect(c.reason == "No music service is ready yet. Connect Spotify or allow Apple Music.")
        #expect(c.spotify.readiness == .needsSetup(.connectSpotify))
        #expect(c.spotify.sentence == "Spotify needs you to sign in again.")
        #expect(c.appleMusic.readiness == .needsSetup(.allowAppleMusic))
        #expect(ProviderState.Action.connectSpotify.title == "Connect Spotify")
        #expect(ProviderState.Action.allowAppleMusic.title == "Allow Apple Music")
    }

    @Test func serverUnreachableOnlyBlocksSpotify() {
        let c = MusicSelection.choose(preferred: .spotify, status: nil, appleAuthorization: .authorized)
        #expect(c.active == .appleMusic)
        #expect(c.spotify.sentence.contains("ZORO server, which could not be reached"))
    }

    @Test func appleMusicAuthorizationStates() {
        for auth in MediaAuthorization.allCases {
            let state = MusicSelection.appleMusicState(auth)
            switch auth {
            case .authorized, .limited: #expect(state.isReady)
            case .notDetermined: #expect(state.readiness == .needsSetup(.allowAppleMusic))
            case .denied, .restricted: #expect(state.readiness == .unavailable)
            }
            #expect(state.sentence.hasSuffix("."))
        }
        #expect(MusicSelection.appleMusicState(.restricted).sentence.contains("Screen Time"))
    }

    @Test func notConnectedMentionsPremium() throws {
        let json = #"{"spotify":{"state":"not_connected","detail":"x"},"apple_music":"a","provider_in_use":"apple_music","recommendations":"r"}"#
        let s = try ZoroJSON.decoder().decode(MusicServerStatus.self, from: Data(json.utf8))
        #expect(MusicSelection.spotifyState(s).sentence.contains("Spotify Premium"))
    }
}

@Suite("Device selection and now playing")
struct DeviceAndPlayingTests {
    let phone = MusicOutputDevice(id: "p", name: "iPhone", isActive: true)
    let mac = MusicOutputDevice(id: "m", name: "Mac", isActive: false)

    @Test func spotifyCanMoveToAnotherDevice() {
        let c = DeviceSelection.choice(devices: [phone, mac], session: nil, provider: .spotify)
        #expect(c.canMove)
        #expect(c.targets.map(\.name) == ["Mac"])
        #expect(c.rows[0].accessibilityLabel == "iPhone, playing here")
        #expect(c.rows[1].accessibilityLabel == "Mac, move playback here")
        #expect(c.note.contains("Spotify Premium"))
    }

    @Test func appleMusicCannotMoveAndSaysWhy() {
        let c = DeviceSelection.choice(devices: [phone, mac], session: nil, provider: .appleMusic)
        #expect(!c.canMove)
        #expect(c.note == "Apple does not let apps move Apple Music between your devices. Use the AirPlay button in Control Centre to pick where it plays.")
    }

    @Test func noProviderNoMove() {
        let c = DeviceSelection.choice(devices: [phone, mac], session: nil, provider: nil)
        #expect(!c.canMove)
        #expect(c.note.hasPrefix("Choose a music service first"))
    }

    @Test func noDevicesFoundSaysWhatToOpen() {
        let c = DeviceSelection.choice(devices: [], session: nil, provider: .spotify)
        #expect(!c.canMove && c.rows.isEmpty)
        #expect(c.note.hasPrefix("No devices found. Open Spotify on your iPhone or Mac"))
    }

    @Test func theServersSessionMarksTheActiveDeviceWhenThePlayerReportsNone() {
        let idle = [MusicOutputDevice(id: "p", name: "iPhone", isActive: false), mac]
        let c = DeviceSelection.choice(devices: idle, session: SessionDevice(id: "m", name: "Mac"), provider: .spotify)
        #expect(c.rows.first { $0.id == "m" }?.isActive == true)
        #expect(c.targets.map(\.id) == ["p"])
    }

    @Test func nowPlayingText() throws {
        let item = MusicItem(id: "1", kind: .song, title: "Example title", subtitle: "Example artist", service: .spotify)
        let n = NowPlaying(item: item, isPlaying: true, positionSeconds: 65, durationSeconds: 200, deviceName: "Mac", observedAt: fixedNow)
        let p = try #require(NowPlayingPresenter.presentation(n, now: fixedNow, timeZone: kolkata))
        #expect(p.title == "Example title" && p.subtitle == "Example artist")
        #expect(p.provider == "Spotify" && p.device == "Mac")
        #expect(p.positionText == "1:05 of 3:20")
        #expect(abs((p.progress ?? 0) - 0.325) < 0.0001)
        #expect(p.accessibilityLabel == "Playing, Example title, Example artist, on Mac")
        #expect(p.observedLine.hasPrefix("As of "))
        let paused = NowPlaying(item: item, isPlaying: false, observedAt: fixedNow)
        let q = try #require(NowPlayingPresenter.presentation(paused, now: fixedNow, timeZone: kolkata))
        #expect(q.progress == nil && q.positionText == nil)
        #expect(q.accessibilityLabel.hasPrefix("Paused, Example title"))
    }

    @Test func nothingLoadedMeansNoPresentation() {
        #expect(NowPlayingPresenter.presentation(nil, now: fixedNow) == nil)
        #expect(NowPlayingPresenter.presentation(NowPlaying(item: nil, isPlaying: false, observedAt: fixedNow), now: fixedNow) == nil)
    }
}
