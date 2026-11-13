import Foundation
import AppKit
import SwiftUI
import Testing
import ZoroCore
@testable import MusicFeature

@MainActor
func render<V: View>(_ view: V, name: String, width: CGFloat = 720, height: CGFloat = 1400, dark: Bool = false) -> Bool {
    let content = view.frame(width: width, height: height).environment(\.colorScheme, dark ? .dark : .light)
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    if let dir = ProcessInfo.processInfo.environment["ZORO_LIFE_SNAPSHOT_DIR"] {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    return rep.pixelsWide > 0
}

@Suite("Music screens render")
@MainActor
struct MusicViewSmokeTests {
    @Test func connectedAndPlaying() async throws {
        let music = FakeMusic()
        music.playing = NowPlaying(item: song, isPlaying: true, positionSeconds: 65, durationSeconds: 200, deviceName: "Mac", observedAt: fixedNow)
        music.devices = [MusicOutputDevice(id: "p", name: "iPhone", isActive: false), MusicOutputDevice(id: "m", name: "Mac", isActive: true)]
        music.searchResults = [song, appleSong]
        let model = makeModel(api: try connectedServer(), music: music)
        await model.load()
        model.searchText = "focus"
        await model.search()
        #expect(render(MusicHomeContent(model: model), name: "music-connected", height: 2200))
        #expect(render(MusicHomeContent(model: model), name: "music-connected-dark", height: 2200, dark: true))
    }

    @Test func nothingSetUpAndServerDown() async throws {
        let api = FakeAPI()
        api.fail(.get, "/v1/music/status", with: ZoroError.transport("offline"))
        let music = FakeMusic()
        music.auth = .notDetermined
        let model = makeModel(api: api, music: music)
        #expect(render(MusicHomeContent(model: model), name: "music-loading", height: 500))
        await model.load()
        #expect(render(MusicHomeContent(model: model), name: "music-not-set-up", height: 2000))
    }

    @Test func cards() throws {
        for name in ["card_songs", "card_now_playing"] {
            #expect(render(MusicCardView(card: try Fixtures.card(name)), name: "music-\(name)", height: 260))
        }
        #expect(render(MusicCardView(card: UICard(kind: "fitness_summary")), name: "music-card-bad", height: 200))
    }
}
