import Foundation
import Testing
@testable import MusicIntegration
import NativeActionBroker
import ZoroCore

let now = Date(timeIntervalSince1970: 1_794_000_000)

actor FakeAppleMusic: AppleMusicBackend {
    var auth: MediaAuthorization = .authorized
    var authAfterRequest: MediaAuthorization = .authorized
    var subscribed = true
    var played: [ZoroCore.MusicItem] = []
    var commands: [String] = []
    var current: ZoroCore.MusicItem?

    func configure(auth: MediaAuthorization = .authorized, after: MediaAuthorization = .authorized, subscribed: Bool = true) {
        self.auth = auth
        self.authAfterRequest = after
        self.subscribed = subscribed
    }

    func authorizationStatus() async -> MediaAuthorization { auth }
    func requestAuthorization() async -> MediaAuthorization {
        commands.append("request")
        auth = authAfterRequest
        return auth
    }
    func canPlayCatalogContent() async throws -> Bool { subscribed }
    func searchCatalog(_ term: String, kinds: [ZoroCore.MusicItem.Kind], limit: Int) async throws -> [ZoroCore.MusicItem] {
        term == "nothing" ? [] : [ZoroCore.MusicItem(id: "1440857781", kind: .song, title: "Kesariya", subtitle: "Arijit Singh", service: .appleMusic)]
    }
    func libraryPlaylists(limit: Int) async throws -> [ZoroCore.MusicItem] {
        [ZoroCore.MusicItem(id: "p.abc", kind: .playlist, title: "Morning run", service: .appleMusic)]
    }
    func play(_ item: ZoroCore.MusicItem) async throws {
        played.append(item)
        current = item
    }
    func resume() async throws { commands.append("resume") }
    func pause() async { commands.append("pause") }
    func skipToNext() async throws { commands.append("next") }
    func skipToPrevious() async throws { commands.append("previous") }
    func enqueue(_ item: ZoroCore.MusicItem, at position: QueuePosition) async throws { commands.append("queue-\(position.rawValue)") }
    func nowPlaying() async -> NowPlaying? {
        current.map { NowPlaying(item: $0, isPlaying: true, observedAt: now) }
    }
}

actor RecordingOpener: URLOpening {
    var opened: [URL] = []
    var refuse: Set<String> = []
    func refuseScheme(_ s: String) { refuse.insert(s) }
    func open(_ url: URL) async -> Bool {
        opened.append(url)
        return !refuse.contains(url.scheme ?? "")
    }
}

actor FakeScripts: AppleScriptRunning {
    var runs: [(String, [String: String])] = []
    var outputs: [String: String] = [:]
    func setOutput(_ id: String, _ out: String) { outputs[id] = out }
    func run(scriptId: String, params: [String: String]) async throws -> String? {
        runs.append((scriptId, params))
        return outputs[scriptId]
    }
    nonisolated func summary(scriptId: String) -> String? { AppleScriptCatalog.standard[scriptId]?.summary }
}

func avail(_ auth: MediaAuthorization = .authorized, catalog: Bool? = true, spotify: Bool = true) -> MusicProviderAvailability {
    MusicProviderAvailability(appleMusicAuthorization: auth, appleMusicCanPlayCatalog: catalog, spotifyInstalled: spotify)
}

func req(_ args: JSONObject) -> DeviceActionRequest {
    DeviceActionRequest(actionId: UUID().uuidString, tool: "device.music.control", args: args, risk: .low, expiresAt: now.addingTimeInterval(60))
}

@Suite struct ProviderSelectionTests {
    @Test func explicitRequestIsHonouredOrRefused() {
        #expect(MusicProviderSelector.select(requested: .spotifyApp, preferred: .appleMusic, availability: avail()) == .use(.spotifyApp))
        #expect(MusicProviderSelector.select(requested: .appleMusic, preferred: nil, availability: avail(.notDetermined, catalog: nil)) == .use(.appleMusic))
        guard case .unavailable(let why) = MusicProviderSelector.select(requested: .spotifyApp, preferred: nil, availability: avail(spotify: false)) else {
            Issue.record("expected unavailable")
            return
        }
        #expect(why.contains("not installed"))
        guard case .unavailable(let sub) = MusicProviderSelector.select(requested: .appleMusic, preferred: nil, availability: avail(catalog: false)) else {
            Issue.record("expected unavailable")
            return
        }
        #expect(sub.contains("subscription"))
        guard case .unavailable(let denied) = MusicProviderSelector.select(requested: .appleMusic, preferred: nil, availability: avail(.denied)) else {
            Issue.record("expected unavailable")
            return
        }
        #expect(denied.contains("Settings"))
    }

    @Test func defaultsWithoutARequest() {
        #expect(MusicProviderSelector.select(requested: nil, preferred: .spotifyApp, availability: avail()) == .use(.spotifyApp))
        #expect(MusicProviderSelector.select(requested: nil, preferred: .spotifyApp, availability: avail(spotify: false)) == .use(.appleMusic))
        #expect(MusicProviderSelector.select(requested: nil, preferred: nil, availability: avail()) == .use(.appleMusic))
        #expect(MusicProviderSelector.select(requested: nil, preferred: nil, availability: avail(catalog: false)) == .use(.spotifyApp))
        #expect(MusicProviderSelector.select(requested: nil, preferred: nil, availability: avail(.notDetermined, catalog: nil, spotify: false)) == .use(.appleMusic))
        if case .use = MusicProviderSelector.select(requested: nil, preferred: nil, availability: avail(.denied, catalog: nil, spotify: false)) {
            Issue.record("nothing should be usable")
        }
    }
}

/// A `MusicControlling` that records calls, to check the handler uses only the ZoroCore protocol.
actor RecordingMusicControl: MusicControlling {
    var calls: [String] = []
    nonisolated func authorization() async -> MediaAuthorization { .authorized }
    func search(_ query: MusicSearchQuery) async throws -> [ZoroCore.MusicItem] {
        calls.append("search:\(query.text)")
        return [ZoroCore.MusicItem(id: "1", kind: .song, title: "Tum Hi Ho", subtitle: "Arijit Singh", service: .appleMusic)]
    }
    func play(_ item: ZoroCore.MusicItem?) async throws { calls.append("play:\(item?.id ?? "resume")") }
    func pause() async throws { calls.append("pause") }
    func skipToNext() async throws { calls.append("next") }
    func skipToPrevious() async throws { calls.append("previous") }
    func queue(_ item: ZoroCore.MusicItem, at position: QueuePosition) async throws {}
    func outputDevices() async throws -> [MusicOutputDevice] { [] }
    func transfer(toDeviceId deviceId: String) async throws {}
    func nowPlaying() async throws -> NowPlaying? { nil }
}

@Suite struct MusicControllingProtocolTests {
    @Test func handlerSkipsThroughTheProtocol() async {
        let control = RecordingMusicControl()
        let handler = MusicControlHandler(controls: [AppleMusicKitControl(controller: control)], availability: { avail() })
        let broker = NativeActionBroker(platform: .ios, handlers: [handler], confirmer: nil, now: { now })
        for action in ["next", "previous", "search_play"] {
            var args: JSONObject = ["provider": "apple_music", "action": .string(action)]
            if action == "search_play" { args["query"] = "tum hi ho" }
            #expect(await broker.execute(req(args)).ok, "\(action)")
        }
        #expect(await control.calls == ["next", "previous", "search:tum hi ho", "play:1"])
    }

    @Test func appleMusicControllerSkipsAfterAuthorisation() async throws {
        let music = FakeAppleMusic()
        await music.configure(auth: .denied, after: .denied)
        let controller: any MusicControlling = AppleMusicController(backend: music)
        await #expect(throws: ZoroError.self) { try await controller.skipToNext() }
        await music.configure()
        try await controller.skipToNext()
        try await controller.skipToPrevious()
        #expect(await music.commands.suffix(2) == ["next", "previous"])
    }
}

@Suite struct MusicHandlerTests {
    func phoneBroker(_ music: FakeAppleMusic, _ opener: RecordingOpener, availability: MusicProviderAvailability = avail()) -> NativeActionBroker {
        let handler = MusicControlHandler(
            controls: [AppleMusicKitControl(controller: AppleMusicController(backend: music)), SpotifyHandoffControl(opener: opener)],
            availability: { availability })
        return NativeActionBroker(platform: .ios, handlers: [handler], confirmer: nil, now: { now })
    }

    @Test func appleMusicSearchPlayReportsNowPlaying() async {
        let music = FakeAppleMusic()
        let r = await phoneBroker(music, RecordingOpener()).execute(req(["provider": "apple_music", "action": "search_play", "query": "kesariya"]))
        #expect(r.ok)
        #expect(r.result == ["now_playing": ["title": "Kesariya", "artist": "Arijit Singh", "provider": "apple_music"]])
        #expect(r.capabilityStatus == .workingNative)
        #expect(await music.played.count == 1)
    }

    @Test func appleMusicTransportCommands() async {
        let music = FakeAppleMusic()
        let broker = phoneBroker(music, RecordingOpener())
        for action in ["play", "pause", "next", "previous"] {
            #expect(await broker.execute(req(["provider": "apple_music", "action": .string(action)])).ok)
        }
        #expect(await music.commands == ["resume", "pause", "next", "previous"])
    }

    @Test func noSearchResultFails() async {
        let r = await phoneBroker(FakeAppleMusic(), RecordingOpener()).execute(
            req(["provider": "apple_music", "action": "search_play", "query": "nothing"]))
        #expect(r.errorCode == "failed")
    }

    @Test func noSubscriptionIsUnsupported() async {
        let music = FakeAppleMusic()
        await music.configure(subscribed: false)
        let r = await phoneBroker(music, RecordingOpener(), availability: avail(catalog: nil)).execute(
            req(["provider": "apple_music", "action": "search_play", "query": "kesariya"]))
        #expect(r.errorCode == "unsupported")
        #expect(await music.played.isEmpty)
    }

    @Test func requestedProviderMissingIsNotSwitched() async {
        let opener = RecordingOpener()
        let music = FakeAppleMusic()
        let r = await phoneBroker(music, opener, availability: avail(spotify: false)).execute(
            req(["provider": "spotify_app", "action": "search_play", "query": "lofi"]))
        #expect(r.errorCode == "unsupported" && r.capabilityStatus == .manualUserStep)
        #expect(await opener.opened.isEmpty)
        #expect(await music.played.isEmpty)
    }

    @Test func spotifyOnPhoneIsHandoff() async {
        let opener = RecordingOpener()
        let broker = phoneBroker(FakeAppleMusic(), opener)
        let search = await broker.execute(req(["provider": "spotify_app", "action": "search_play", "query": "lo-fi beats हिंदी"]))
        #expect(search.ok && search.capabilityStatus == .manualUserStep)
        #expect(search.result == [:])
        #expect(await opener.opened.first?.absoluteString == "spotify:search:lo-fi%20beats%20%E0%A4%B9%E0%A4%BF%E0%A4%82%E0%A4%A6%E0%A5%80")

        let uri = await broker.execute(req(["action": "search_play", "uri": "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"]))
        #expect(uri.ok)
        #expect(await opener.opened.last?.absoluteString == "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")

        let pause = await broker.execute(req(["provider": "spotify_app", "action": "pause"]))
        #expect(pause.errorCode == "unsupported" && pause.capabilityStatus == .requiresCredentials)
    }

    @Test func spotifyFallsBackToWebLink() async {
        let opener = RecordingOpener()
        await opener.refuseScheme("spotify")
        let r = await phoneBroker(FakeAppleMusic(), opener).execute(
            req(["provider": "spotify_app", "action": "search_play", "uri": "spotify:track:4uLU6hMCjMI75M1A2tKUQC"]))
        #expect(r.ok)
        #expect(await opener.opened.last?.absoluteString == "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
    }

    @Test func argumentValidation() async {
        let broker = phoneBroker(FakeAppleMusic(), RecordingOpener())
        let cases: [(JSONObject, String)] = [
            (["provider": "youtube", "action": "play"], "provider"),
            (["provider": "apple_music"], "action"),
            (["provider": "apple_music", "action": "shuffle"], "action"),
            (["provider": "apple_music", "action": "search_play"], "query"),
            (["provider": "spotify_app", "action": "search_play", "uri": "spotify:track:short"], "uri"),
            (["provider": "spotify_app", "action": "search_play", "uri": "https://open.spotify.com/x"], "uri"),
            (["provider": "apple_music", "action": "search_play", "uri": "spotify:track:4uLU6hMCjMI75M1A2tKUQC"], "uri"),
        ]
        for (args, field) in cases {
            let r = await broker.execute(req(args))
            #expect(r.errorMessage?.hasPrefix("`\(field)`") == true, "\(args): \(r.errorMessage ?? "")")
        }
    }
}

@Suite struct AppleMusicControllerTests {
    @Test func authorisationIsAskedInContextThenRespected() async throws {
        let music = FakeAppleMusic()
        await music.configure(auth: .notDetermined, after: .denied)
        let c = AppleMusicController(backend: music)
        await #expect(throws: ZoroError.self) { try await c.search(MusicSearchQuery(text: "x")) }
        #expect(await music.commands == ["request"])
        #expect(try await c.nowPlaying() == nil)
    }

    @Test func libraryItemsPlayWithoutSubscription() async throws {
        let music = FakeAppleMusic()
        await music.configure(subscribed: false)
        let c = AppleMusicController(backend: music)
        let playlist = try #require(try await c.libraryPlaylists().first)
        try await c.play(playlist)
        #expect(await music.played == [playlist])
        await #expect(throws: ZoroError.self) {
            try await c.play(ZoroCore.MusicItem(id: "1440857781", kind: .song, title: "x", service: .appleMusic))
        }
        await #expect(throws: ZoroError.self) {
            try await c.play(ZoroCore.MusicItem(id: "x", kind: .song, title: "x", service: .spotify))
        }
    }

    @Test func routingIsHonestlyUnavailable() async {
        let c = AppleMusicController(backend: FakeAppleMusic())
        await #expect(throws: ZoroError.self) { try await c.outputDevices() }
        await #expect(throws: ZoroError.self) { try await c.transfer(toDeviceId: "x") }
        await #expect(throws: ZoroError.self) { try await c.search(MusicSearchQuery(text: "x", service: .spotify)) }
    }

    @Test func queuePosition() async throws {
        let music = FakeAppleMusic()
        try await AppleMusicController(backend: music).queue(
            ZoroCore.MusicItem(id: "1", kind: .song, title: "x", service: .appleMusic), at: .next)
        #expect(await music.commands == ["queue-next"])
    }

    @Test func probe() async {
        let music = FakeAppleMusic()
        await music.configure(subscribed: false)
        #expect(await MusicAvailabilityProbe(appleMusic: music, spotifyInstalled: { true }).current() == avail(catalog: false, spotify: true))
        #expect(await MusicAvailabilityProbe(appleMusic: nil, spotifyInstalled: { false }).current() == avail(catalog: nil, spotify: false))
    }
}

#if os(macOS)
@Suite struct MacScriptedMusicTests {
    func broker(_ scripts: FakeScripts, _ opener: RecordingOpener) -> NativeActionBroker {
        let handler = MusicControlHandler(
            controls: [
                ScriptedMusicControl(provider: .appleMusic, runner: scripts, opener: opener),
                ScriptedMusicControl(provider: .spotifyApp, runner: scripts, opener: opener),
            ],
            availability: { avail(catalog: nil) })
        return NativeActionBroker(platform: .macos, handlers: [handler], confirmer: nil, now: { now })
    }

    @Test func usesOnlyAllowlistedScriptIds() async {
        for provider in MusicProvider.allCases {
            for action in MusicControlAction.allCases {
                #expect(AppleScriptCatalog.standard[ScriptedMusicControl.scriptId(provider, action)] != nil)
            }
        }
    }

    @Test func spotifyPauseAndNowPlaying() async {
        let scripts = FakeScripts()
        await scripts.setOutput("music.spotify.now_playing", "Tum Hi Ho\tArijit Singh")
        let r = await broker(scripts, RecordingOpener()).execute(req(["provider": "spotify_app", "action": "next"]))
        #expect(r.ok && r.capabilityStatus == .workingLocal)
        #expect(r.result == ["now_playing": ["title": "Tum Hi Ho", "artist": "Arijit Singh", "provider": "spotify_app"]])
        #expect(await scripts.runs.map(\.0) == ["music.spotify.next", "music.spotify.now_playing"])
    }

    @Test func spotifyURIGoesThroughParameterNotSource() async {
        let scripts = FakeScripts()
        let uri = "spotify:track:4uLU6hMCjMI75M1A2tKUQC"
        _ = await broker(scripts, RecordingOpener()).execute(req(["provider": "spotify_app", "action": "search_play", "uri": .string(uri)]))
        let first = await scripts.runs.first
        #expect(first?.0 == "music.spotify.play_uri")
        #expect(first?.1 == ["uri": uri])
    }

    @Test func spotifyQueryOpensSearchAndAppleMusicSearchesLibrary() async {
        let scripts = FakeScripts()
        let opener = RecordingOpener()
        let b = broker(scripts, opener)
        let s = await b.execute(req(["provider": "spotify_app", "action": "search_play", "query": "focus"]))
        #expect(s.ok && s.capabilityStatus == .manualUserStep)
        #expect(await opener.opened.first?.absoluteString == "spotify:search:focus")

        await scripts.setOutput("music.apple.search_play", "Kun Faya Kun\tA. R. Rahman")
        let a = await b.execute(req(["provider": "apple_music", "action": "search_play", "query": "kun faya"]))
        #expect(a.result?["now_playing"]?["title"] == "Kun Faya Kun")
        #expect(await scripts.runs.last?.1 == ["query": "kun faya"])

        await scripts.setOutput("music.apple.search_play", "")
        let none = await b.execute(req(["provider": "apple_music", "action": "search_play", "query": "zzz"]))
        #expect(none.errorCode == "failed")
    }
}
#endif
