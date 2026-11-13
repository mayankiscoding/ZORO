import Foundation
import Testing
import ZoroCore
@testable import PhotosFeature

let kolkata = TimeZone(identifier: "Asia/Kolkata")!
let fixedNow = ZoroJSON.parseDate("2026-11-13T12:00:00Z")!

@Suite("Photos contract: DTOs decode the server's real JSON")
struct PhotoContractTests {
    @Test func parsedQuery() throws {
        let p = try Fixtures.decode(ParsedPhotoQuery.self, "parsed_query")
        #expect(p.query.text == "photo from yesterday with my blue cap")
        #expect(p.query.dateFrom?.description == "2026-11-12")
        #expect(p.query.dateTo?.description == "2026-11-12")
        #expect(p.query.colors == ["blue"])
        #expect(p.query.labels == ["cap", "hat"])
        #expect(p.query.media == .any)
        #expect(p.query.limit == 30)
        #expect(p.textSource == "original")
        #expect(p.source == .server)
        #expect(p.assumptions.isEmpty)
    }

    @Test func foundCard() throws {
        let p = try Fixtures.card("card_found").decodePayload(PhotoCardPayload.self)
        #expect(p.state == "found")
        #expect(p.assetIds.count == 2)
        #expect(p.assetIds[0] == "B84E8479-475C-4727-A4A4-B77AA9980897/L0/001", "slashes in a Photos identifier survive")
        #expect(p.hits[0].labels == ["cap", "hat"])
        #expect(p.hits[0].score == 0.91)
        #expect(p.hits[1].capturedAt == nil)
        #expect(p.indexedCount == 1204)
        #expect(p.limitedLibrary == true)
        #expect(p.chips.map(\.kind) == ["date", "color", "label", "label"])
    }

    @Test func emptyAndSearchingCards() throws {
        let empty = try Fixtures.card("card_empty").decodePayload(PhotoCardPayload.self)
        #expect(empty.state == "empty")
        #expect(empty.hits.isEmpty)
        #expect(empty.indexedCount == 1204)
        let searching = try Fixtures.card("card_searching").decodePayload(PhotoCardPayload.self)
        #expect(searching.state == "searching")
        #expect(searching.indexedCount == nil)
        #expect(searching.assetIds.isEmpty)
    }

    @Test func cardPayloadCarriesNoImageData() throws {
        let object = try #require(try Fixtures.json("card_found") as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(Set(payload.keys).isDisjoint(with: ["image", "images", "bytes", "data", "thumbnail", "url", "path"]))
    }

    @Test func parseRequestBody() throws {
        let request = try APIRequest.json(.post, "/v1/vision/parse-query", body: ParseQueryRequest(text: "red car", timezone: "Asia/Kolkata"))
        let body = try bodyObject(request)
        #expect(body["text"] as? String == "red car")
        #expect(body["timezone"] as? String == "Asia/Kolkata")
        #expect(body["refine"] as? Bool == false)
    }
}

@Suite("Query chips")
struct QueryChipTests {
    struct Case: Decodable {
        struct Chip: Decodable { var kind: String; var label: String }
        var text: String
        var query: PhotoQuery
        var chips: [Chip]
    }

    @Test func chipsFollowTheServersKindsAndOrder() throws {
        let cases = try Fixtures.decode([Case].self, "chip_cases")
        #expect(cases.count == 4)
        for c in cases {
            let mine = PhotoQueryChips.chips(for: c.query)
            #expect(mine.map(\.kind.rawValue) == c.chips.map(\.kind), "chip kinds for \"\(c.text)\"")
            for (m, s) in zip(mine, c.chips) {
                switch m.kind {
                case .color, .label: #expect(m.label == s.label)
                case .text: #expect(m.label == "\u{201C}\(s.label)\u{201D}")
                case .date, .media: break
                }
            }
        }
    }

    @Test func dateChipsAreForPeople() throws {
        let cases = try Fixtures.decode([Case].self, "chip_cases")
        let single = PhotoQueryChips.chips(for: cases[0].query)[0]
        #expect(single.kind == .date)
        #expect(single.label == "12 Nov 2026")
        let range = cases[1].query
        let chip = try #require(PhotoQueryChips.chips(for: range).first { $0.kind == .date })
        #expect(chip.label.contains(" to "))
        #expect(chip.accessibilityLabel.hasPrefix("Date: "))
    }

    @Test func mediaAndTextChips() throws {
        let cases = try Fixtures.decode([Case].self, "chip_cases")
        let chips = PhotoQueryChips.chips(for: cases[1].query)
        #expect(chips.contains { $0.kind == .media && $0.label == "Screenshots only" })
        #expect(chips.contains { $0.kind == .text && $0.label == "\u{201C}boarding pass\u{201D}" })
        #expect(chips.first { $0.kind == .text }?.accessibilityLabel == "Text in the photo: \u{201C}boarding pass\u{201D}")
    }

    @Test func plainWordsMakeNoChips() throws {
        let cases = try Fixtures.decode([Case].self, "chip_cases")
        #expect(PhotoQueryChips.chips(for: cases[3].query).isEmpty)
        #expect(PhotoQueryChips.chips(for: PhotoQuery(text: "anything")).isEmpty)
    }

    @Test func halfOpenDateRanges() throws {
        let q = PhotoQuery(text: "x", dateFrom: CalendarDate("2026-10-01"))
        #expect(PhotoQueryChips.chips(for: q).map(\.label) == ["From 1 Oct 2026"])
        let r = PhotoQuery(text: "x", dateTo: CalendarDate("2026-10-31"), media: .photo)
        #expect(PhotoQueryChips.chips(for: r).map(\.label) == ["Until 31 Oct 2026", "Photos only"])
    }

    @Test func everyChipHasASymbolAndIsSentenceCase() throws {
        let q = PhotoQuery(text: "x", dateFrom: CalendarDate("2026-10-01"), dateTo: CalendarDate("2026-10-02"), colors: ["red"], labels: ["car"], containsText: "hi", media: .screenshot)
        let chips = PhotoQueryChips.chips(for: q)
        #expect(chips.count == 5)
        for chip in chips {
            #expect(!chip.symbol.isEmpty)
            #expect(chip.label != chip.label.uppercased() || chip.label.count < 3)
        }
    }

    @Test func cardChipsFallBackToTheServersOwn() throws {
        let p = try Fixtures.card("card_found").decodePayload(PhotoCardPayload.self)
        let chips = PhotoQueryChips.chips(from: p.chips, query: p.query)
        #expect(chips.map(\.kind) == [.date, .color, .label, .label])
        let bare = PhotoQueryChips.chips(from: [PhotoCardChip(kind: "text", label: "hello"), PhotoCardChip(kind: "mystery", label: "x")], query: PhotoQuery(text: ""))
        #expect(bare.map(\.label) == ["hello"])
    }
}

@Suite("Index status presentation")
struct IndexPresentationTests {
    let last = ZoroJSON.parseDate("2026-11-13T10:42:00+05:30")!
    let now = ZoroJSON.parseDate("2026-11-13T18:00:00+05:30")!

    func present(_ s: PhotoIndexStatus) -> IndexPresentation { IndexPresenter.presentation(s, now: now, timeZone: kolkata) }

    @Test func notStartedInvitesYouToBuild() {
        let p = present(PhotoIndexStatus(state: .notStarted))
        #expect(p.headline == "Your photos are not indexed yet")
        #expect(p.rebuildTitle == "Build index")
        #expect(p.canRebuild && !p.canDelete && !p.isBusy)
        #expect(p.detail.contains("nothing leaves it"))
        #expect(p.progress == nil && p.lastRun == nil)
    }

    @Test func indexingShowsCountAndProgress() {
        let p = present(PhotoIndexStatus(state: .indexing, indexedCount: 1204, totalCount: 5000, lastUpdatedAt: last))
        #expect(p.headline == "Indexing: 1,204 of 5,000 photos")
        let progress = p.progress ?? -1
        #expect(abs(progress - 0.2408) < 0.0001)
        #expect(p.isBusy && !p.canRebuild && !p.canDelete)
        #expect(p.lastRun?.hasPrefix("Last updated ") == true)
        #expect(p.accessibilityLabel.contains("24 percent"))
    }

    @Test func indexingWithoutATotalHasNoProgressBar() {
        let p = present(PhotoIndexStatus(state: .indexing, indexedCount: 10, totalCount: 0))
        #expect(p.headline == "Indexing your photos")
        #expect(p.progress == nil)
    }

    @Test func progressIsClamped() {
        let p = present(PhotoIndexStatus(state: .indexing, indexedCount: 120, totalCount: 100))
        #expect(p.progress == 1)
    }

    @Test func readyAllAndPartial() {
        let all = present(PhotoIndexStatus(state: .ready, indexedCount: 5000, totalCount: 5000, lastUpdatedAt: last))
        #expect(all.headline == "5,000 photos indexed")
        #expect(all.detail == "Search covers all of them.")
        #expect(all.canRebuild && all.canDelete && !all.isBusy)
        #expect(all.lastRun?.hasPrefix("Last updated 10:42") == true)
        let partial = present(PhotoIndexStatus(state: .ready, indexedCount: 300, totalCount: 5000))
        #expect(partial.headline == "300 of 5,000 photos indexed")
        #expect(partial.detail.contains("Rebuild to pick up the rest"))
    }

    @Test func lastRunOnAnotherDayIsADate() {
        let old = ZoroJSON.parseDate("2026-11-02T10:00:00+05:30")!
        #expect(present(PhotoIndexStatus(state: .ready, indexedCount: 1, totalCount: 1, lastUpdatedAt: old)).lastRun == "Last updated 2 Nov")
    }

    @Test func pausedSaysWhy() {
        let battery = present(PhotoIndexStatus(state: .paused, indexedCount: 10, totalCount: 100, pausedReason: "low_power"))
        #expect(battery.detail == "Paused to save battery. It continues when Low Power Mode is off.")
        #expect(battery.canRebuild && battery.canDelete)
        #expect(present(PhotoIndexStatus(state: .paused, pausedReason: "thermal")).detail == "Paused while the device cools down. It continues by itself.")
        #expect(present(PhotoIndexStatus(state: .paused)).detail == "Paused. It continues when conditions allow.")
        #expect(present(PhotoIndexStatus(state: .paused, pausedReason: "no_network")).detail == "Paused (no network). It continues when conditions allow.")
    }

    @Test func failedSaysWhatToDo() {
        let p = present(PhotoIndexStatus(state: .failed, failureReason: "Out of storage"))
        #expect(p.headline == "Indexing stopped")
        #expect(p.detail == "Out of storage. Tap Rebuild index to try again.")
        #expect(present(PhotoIndexStatus(state: .failed)).detail == "Something went wrong. Tap Rebuild index to try again.")
    }

    @Test func everyStateHasSymbolHeadlineAndNoAllCaps() {
        for state in PhotoIndexStatus.State.allCases {
            let p = present(PhotoIndexStatus(state: state, indexedCount: 1, totalCount: 2))
            #expect(!p.symbol.isEmpty && !p.headline.isEmpty && !p.detail.isEmpty)
            #expect(p.headline != p.headline.uppercased())
        }
    }
}

@Suite("Photo access and hits")
struct AccessAndHitTests {
    @Test func accessMessages() throws {
        #expect(PhotoAccessPresentation.presentation(.authorized, isMac: false) == nil)
        let ask = try #require(PhotoAccessPresentation.presentation(.notDetermined, isMac: false))
        #expect(ask.action == .allowAccess && ask.actionTitle == "Allow photo access")
        #expect(ask.message.contains("they don't leave it"))
        let limited = try #require(PhotoAccessPresentation.presentation(.limited, isMac: false))
        #expect(limited.action == .choosePhotos && limited.actionTitle == "Choose more photos")
        let denied = try #require(PhotoAccessPresentation.presentation(.denied, isMac: false))
        #expect(denied.message.hasPrefix("Photo access is off. Open Settings"))
        #expect(denied.action == .checkAgain)
        let restricted = try #require(PhotoAccessPresentation.presentation(.restricted, isMac: false))
        #expect(restricted.message.contains("Screen Time"))
    }

    @Test func macHasNoLimitedPicker() throws {
        let limited = try #require(PhotoAccessPresentation.presentation(.limited, isMac: true))
        #expect(limited.action == nil && limited.actionTitle == nil)
        let denied = try #require(PhotoAccessPresentation.presentation(.denied, isMac: true))
        #expect(denied.message.contains("System Settings"))
    }

    @Test func matchedPhrases() {
        #expect(PhotoHitPresenter.matchedPhrases(["label:cap", "color:blue", "text:sale", "similar", "date", "media:screenshot", "weird:x", "label"])
            == ["cap", "blue", "text \u{201C}sale\u{201D}", "similar look", "date", "screenshot"])
    }

    @Test func thumbnailLabels() {
        let taken = ZoroJSON.parseDate("2026-11-12T09:30:00+05:30")!
        let label = PhotoHitPresenter.accessibilityLabel(capturedAt: taken, labels: ["cap", "hat"], matched: ["label:cap", "color:blue"], now: fixedNow, timeZone: kolkata)
        #expect(label == "Photo from 12 Nov, matched cap and blue.")
        let byLabels = PhotoHitPresenter.accessibilityLabel(capturedAt: nil, labels: ["dog", "park", "tree", "sky"], matched: [], now: fixedNow, timeZone: kolkata)
        #expect(byLabels == "Photo, shows dog, park and tree.")
        #expect(PhotoHitPresenter.accessibilityLabel(capturedAt: nil, labels: [], matched: [], now: fixedNow, timeZone: kolkata) == "Photo.")
    }

    @Test func unavailableThumbnailProviderShowsNothingInsteadOfInventing() async {
        let thumb = await UnavailableThumbnailProvider().thumbnail(for: "x", targetSize: CGSize(width: 10, height: 10))
        #expect(thumb == nil)
        let presented = await MainActor.run { UnavailableLimitedLibraryPresenter() }
        #expect(await presented.presentPicker() == false)
    }
}
