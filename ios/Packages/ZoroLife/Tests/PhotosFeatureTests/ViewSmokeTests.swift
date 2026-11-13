import Foundation
import AppKit
import SwiftUI
import Testing
import ZoroCore
@testable import PhotosFeature

@MainActor
func render<V: View>(_ view: V, name: String, width: CGFloat = 720, height: CGFloat = 1200, dark: Bool = false) -> Bool {
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

@Suite("Photo screens render")
@MainActor
struct PhotoViewSmokeTests {
    @Test func screenStates() async throws {
        let photos = FakePhotos(auth: .limited)
        photos.pages = [.success(PhotoSearchResult(hits: (0..<7).map { hit("asset-\($0)/L0/001", labels: ["cap"]) }, indexedCount: 1204, limitedLibrary: true, nextCursor: "n"))]
        let parsed = try Fixtures.decode(ParsedPhotoQuery.self, "parsed_query")
        let model = makeModel(photos: photos, parser: FakeParser(result: .success(parsed)))
        await model.onAppear()
        #expect(render(PhotoSearchContent(model: model), name: "photos-idle", height: 900))
        model.queryText = "photo from yesterday with my blue cap"
        await model.search()
        #expect(render(PhotoSearchContent(model: model), name: "photos-results", height: 1500))
        #expect(render(PhotoSearchContent(model: model), name: "photos-results-dark", height: 1500, dark: true))
    }

    @Test func failureNoResultsAndIndexing() async throws {
        let photos = FakePhotos(auth: .denied)
        photos.status = PhotoIndexStatus(state: .indexing, indexedCount: 1204, totalCount: 5000, lastUpdatedAt: fixedNow)
        let model = makeModel(photos: photos)
        await model.onAppear()
        model.queryText = "cap"
        await model.search()
        #expect(render(PhotoSearchContent(model: model), name: "photos-denied", height: 900))

        let empty = FakePhotos()
        empty.pages = [.success(PhotoSearchResult(hits: [], indexedCount: 0, limitedLibrary: false))]
        empty.status = PhotoIndexStatus(state: .failed, failureReason: "Out of storage")
        let m2 = makeModel(photos: empty)
        await m2.onAppear()
        m2.queryText = "cap"
        await m2.search()
        #expect(render(PhotoSearchContent(model: m2), name: "photos-empty-failed-index", height: 900))
    }

    @Test func cards() throws {
        for name in ["card_found", "card_empty", "card_searching"] {
            #expect(render(PhotoQueryCardView(card: try Fixtures.card(name)), name: "photos-\(name)", height: 420))
        }
        #expect(render(PhotoQueryCardView(card: UICard(kind: "photo_query", payload: ["nonsense": true])), name: "photos-card-bad", height: 200))
    }
}
