import Foundation
import LifeSupport
import Testing
import ZoroCore
@testable import PhotosFeature

// MARK: Fakes

final class FakePhotos: PhotoSearching, @unchecked Sendable {
    var auth: MediaAuthorization
    var grantsOnRequest: MediaAuthorization
    var status = PhotoIndexStatus(state: .ready, indexedCount: 1204, totalCount: 1204)
    var statusScript: [PhotoIndexStatus] = []
    var pages: [Result<PhotoSearchResult, Error>] = []
    var rebuildError: Error?
    var deleteError: Error?
    private(set) var queries: [PhotoQuery] = []
    private(set) var requestCount = 0
    private(set) var rebuilds = 0
    private(set) var deletes = 0
    private(set) var statusCalls = 0

    init(auth: MediaAuthorization = .authorized, grantsOnRequest: MediaAuthorization = .authorized) {
        self.auth = auth
        self.grantsOnRequest = grantsOnRequest
    }

    func authorizationStatus() async -> MediaAuthorization { auth }
    func requestAuthorization() async -> MediaAuthorization {
        requestCount += 1
        auth = grantsOnRequest
        return auth
    }
    func indexStatus() async -> PhotoIndexStatus {
        statusCalls += 1
        if !statusScript.isEmpty { status = statusScript.removeFirst() }
        return status
    }
    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        queries.append(query)
        guard !pages.isEmpty else { return PhotoSearchResult(hits: [], indexedCount: 0, limitedLibrary: false) }
        return try pages.removeFirst().get()
    }
    /// Set to make `rebuildIndex` wait until the screen has polled the status this many times.
    var waitForStatusCalls = 0
    func rebuildIndex() async throws {
        rebuilds += 1
        var waited = 0
        while statusCalls < waitForStatusCalls, waited < 2000 {  // at most about 2 seconds
            try? await Task.sleep(for: .milliseconds(1))
            waited += 1
        }
        if let rebuildError { throw rebuildError }
    }
    func deleteIndex() async throws {
        deletes += 1
        if let deleteError { throw deleteError }
        status = PhotoIndexStatus(state: .notStarted)
    }
}

struct FakeParser: PhotoQueryParsing {
    var result: Result<ParsedPhotoQuery, Error>
    func parse(_ text: String, timeZone: TimeZone) async throws -> ParsedPhotoQuery {
        var parsed = try result.get()
        parsed.query.text = text
        return parsed
    }
}

final class FakePicker: LimitedLibraryPresenting, @unchecked Sendable {
    var onPresent: @Sendable () -> Void = {}
    private(set) var count = 0
    @MainActor func presentPicker() async -> Bool {
        count += 1
        onPresent()
        return true
    }
}

func hit(_ id: String, labels: [String] = []) -> PhotoHit { PhotoHit(assetId: id, capturedAt: fixedNow, score: 0.9, labels: labels, matched: ["label:cap"]) }

@MainActor
func makeModel(
    photos: FakePhotos, parser: any PhotoQueryParsing = FakeParser(result: .success(ParsedPhotoQuery(query: PhotoQuery(text: "x")))),
    picker: FakePicker = FakePicker(), sleeps: Locked<[Duration]> = Locked([])
) -> PhotoSearchViewModel {
    PhotoSearchViewModel(
        photos: photos, parser: parser, picker: picker, timeZone: kolkata, isMac: false, clock: { fixedNow },
        sleep: { d in sleeps.withLock { $0.append(d) } })
}

// MARK: Parsers

@Suite("Photo query parsers")
struct ParserTests {
    @Test func serverParserPostsTheWordsAndTimeZone() async throws {
        let api = FakeAPI()
        try api.reply(.post, "/v1/vision/parse-query", fixture: "parsed_query")
        let parsed = try await ServerPhotoQueryParser(api: api).parse("photo from yesterday with my blue cap", timeZone: kolkata)
        #expect(parsed.query.colors == ["blue"])
        let body = try bodyObject(api.calls.get.first)
        #expect(body["text"] as? String == "photo from yesterday with my blue cap")
        #expect(body["timezone"] as? String == "Asia/Kolkata")
    }

    @Test func deviceParserAgreesWithTheServerOnDatesAndColours() async throws {
        let server = try Fixtures.decode(ParsedPhotoQuery.self, "parsed_query")
        let device = try await DevicePhotoQueryParser(clock: { fixedNow }).parse("photo from yesterday with my blue cap", timeZone: kolkata)
        #expect(device.query.dateFrom == server.query.dateFrom)
        #expect(device.query.dateTo == server.query.dateTo)
        #expect(device.query.colors == server.query.colors)
        #expect(device.query.labels.contains("cap"))
        guard case .device = device.source else { Issue.record("expected a device parse"); return }
    }

    @Test func fallbackUsesTheServerWhenItAnswers() async throws {
        let api = FakeAPI()
        try api.reply(.post, "/v1/vision/parse-query", fixture: "parsed_query")
        let parser = FallbackPhotoQueryParser(api: api, clock: { fixedNow })
        #expect(try await parser.parse("red car", timeZone: kolkata).source == .server)
    }

    @Test func fallbackUsesTheDeviceWhenTheServerIsDown() async throws {
        let api = FakeAPI()
        api.fail(.post, "/v1/vision/parse-query", with: ZoroError.transport("offline"))
        let parsed = try await FallbackPhotoQueryParser(api: api, clock: { fixedNow }).parse("photos from yesterday", timeZone: kolkata)
        #expect(parsed.source == .device(reason: "Understood on this device, because your ZORO server could not be reached."))
        #expect(parsed.query.dateFrom?.description == "2026-11-12")
    }

    @Test func fallbackExplainsAMissingPermission() async throws {
        let api = FakeAPI()
        api.fail(.post, "/v1/vision/parse-query", with: ZoroError.http(status: 403, body: ErrorBody(code: "permission_not_granted:vision.search", message: "no")))
        let parsed = try await FallbackPhotoQueryParser(api: api, clock: { fixedNow }).parse("red car", timeZone: kolkata)
        guard case .device(let reason) = parsed.source else { Issue.record("expected fallback"); return }
        #expect(reason.contains("Allow photo search in Security and privacy"))
    }
}

// MARK: View model

@Suite("Photo search view model")
@MainActor
struct SearchViewModelTests {
    @Test func searchShowsRealHitsAndChips() async throws {
        let photos = FakePhotos()
        photos.pages = [.success(PhotoSearchResult(hits: [hit("A/L0/001", labels: ["cap"]), hit("B/L0/001")], indexedCount: 1204, limitedLibrary: false))]
        let parsed = try Fixtures.decode(ParsedPhotoQuery.self, "parsed_query")
        let model = makeModel(photos: photos, parser: FakeParser(result: .success(parsed)))
        model.queryText = "  photo from yesterday with my blue cap  "
        #expect(model.canSearch)
        await model.search()
        #expect(model.phase == .results)
        #expect(model.hits.map(\.assetId) == ["A/L0/001", "B/L0/001"])
        #expect(model.indexedCount == 1204)
        #expect(model.chips.map(\.kind) == [.date, .color, .label, .label])
        #expect(model.understoodNote == nil)
        #expect(photos.queries.count == 1)
        #expect(photos.queries[0].colors == ["blue"])
        #expect(photos.queries[0].text == "photo from yesterday with my blue cap")
    }

    @Test func emptyTextDoesNothing() async {
        let photos = FakePhotos()
        let model = makeModel(photos: photos)
        model.queryText = "   "
        #expect(!model.canSearch)
        await model.search()
        #expect(model.phase == .idle)
        #expect(photos.queries.isEmpty)
    }

    @Test func noResultsSaysWhetherTheIndexIsEmpty() async {
        let photos = FakePhotos()
        photos.pages = [.success(PhotoSearchResult(hits: [], indexedCount: 0, limitedLibrary: false)), .success(PhotoSearchResult(hits: [], indexedCount: 900, limitedLibrary: false))]
        let model = makeModel(photos: photos)
        model.queryText = "purple elephant"
        await model.search()
        #expect(model.phase == .noResults)
        #expect(model.emptyMessage == "No photos are indexed yet. Build the index below, then search again.")
        await model.search()
        #expect(model.emptyMessage == "No photos matched. Try fewer words or a different date.")
    }

    @Test func firstSearchAsksForAccessInContext() async {
        let photos = FakePhotos(auth: .notDetermined, grantsOnRequest: .authorized)
        photos.pages = [.success(PhotoSearchResult(hits: [hit("A")], indexedCount: 1, limitedLibrary: false))]
        let model = makeModel(photos: photos)
        model.queryText = "cap"
        await model.search()
        #expect(photos.requestCount == 1)
        #expect(model.authorization == .authorized)
        #expect(model.phase == .results)
    }

    @Test func deniedAccessStopsWithAnInstruction() async throws {
        let photos = FakePhotos(auth: .denied)
        let model = makeModel(photos: photos)
        await model.onAppear()
        model.queryText = "cap"
        await model.search()
        guard case .failed(let failure) = model.phase else { Issue.record("expected failure"); return }
        #expect(failure.message.hasPrefix("Photo access is off."))
        #expect(photos.queries.isEmpty)
        #expect(model.access?.action == .checkAgain)
    }

    @Test func declinedFirstPromptIsReportedNotRetried() async {
        let photos = FakePhotos(auth: .notDetermined, grantsOnRequest: .denied)
        let model = makeModel(photos: photos)
        model.queryText = "cap"
        await model.search()
        #expect(photos.requestCount == 1)
        #expect(photos.queries.isEmpty)
        if case .failed = model.phase {} else { Issue.record("expected failure") }
    }

    @Test func serverDownFallsBackToTheDeviceParserAndSaysSo() async throws {
        let api = FakeAPI()
        api.fail(.post, "/v1/vision/parse-query", with: ZoroError.timeout)
        let photos = FakePhotos()
        photos.pages = [.success(PhotoSearchResult(hits: [hit("A")], indexedCount: 5, limitedLibrary: false))]
        let model = makeModel(photos: photos, parser: FallbackPhotoQueryParser(api: api, clock: { fixedNow }))
        model.queryText = "photos from yesterday"
        await model.search()
        #expect(model.phase == .results)
        #expect(model.understoodNote == "Understood on this device, because your ZORO server could not be reached.")
        #expect(model.chips.first?.kind == .date)
    }

    @Test func searchErrorsBecomeSentences() async throws {
        let photos = FakePhotos()
        photos.pages = [.failure(ZoroError.unavailable(capability: "Photo search", reason: "the index is locked"))]
        let model = makeModel(photos: photos)
        model.queryText = "cap"
        await model.search()
        guard case .failed(let f) = model.phase else { Issue.record("expected failure"); return }
        #expect(f.message == "Photo search is not available: the index is locked.")
        #expect(model.hits.isEmpty)
    }

    @Test func invalidQueriesAreExplained() async throws {
        let photos = FakePhotos()
        photos.pages = [.failure(PhotoQuery.ValidationError("date_from is after date_to"))]
        let model = makeModel(photos: photos)
        model.queryText = "cap"
        await model.search()
        guard case .failed(let f) = model.phase else { Issue.record("expected failure"); return }
        #expect(f.message == "That search could not be read: date_from is after date_to. Change it and try again.")
    }

    @Test func morePagesAppendWithoutDuplicates() async throws {
        let photos = FakePhotos()
        photos.pages = [
            .success(PhotoSearchResult(hits: [hit("A"), hit("B")], indexedCount: 10, limitedLibrary: false, nextCursor: "c2")),
            .success(PhotoSearchResult(hits: [hit("B"), hit("C")], indexedCount: 10, limitedLibrary: false, nextCursor: nil)),
        ]
        let model = makeModel(photos: photos)
        model.queryText = "cap"
        await model.search()
        #expect(model.nextCursor == "c2")
        await model.loadMore()
        #expect(model.hits.map(\.assetId) == ["A", "B", "C"])
        #expect(model.nextCursor == nil)
        #expect(photos.queries[1].cursor == "c2")
        await model.loadMore()
        #expect(photos.queries.count == 2, "no cursor, no request")
    }

    @Test func limitedLibraryNoticeAndPicker() async throws {
        let photos = FakePhotos(auth: .limited)
        let picker = FakePicker()
        let model = makeModel(photos: photos, picker: picker)
        await model.onAppear()
        #expect(model.showsLimitedNotice)
        #expect(model.access?.actionTitle == "Choose more photos")
        picker.onPresent = { photos.auth = .authorized; photos.status = PhotoIndexStatus(state: .indexing, indexedCount: 1, totalCount: 9) }
        await model.perform(.choosePhotos)
        #expect(picker.count == 1)
        #expect(model.authorization == .authorized)
        #expect(!model.showsLimitedNotice)
        #expect(model.indexStatus.state == .indexing, "the index status is read again after the picker closes")
    }

    @Test func aSearchThatReportsAPartialLibraryShowsTheNoticeWhenAuthorized() async {
        let photos = FakePhotos(auth: .authorized)
        photos.pages = [.success(PhotoSearchResult(hits: [hit("A")], indexedCount: 5, limitedLibrary: true))]
        let model = makeModel(photos: photos)
        model.queryText = "cap"
        await model.search()
        #expect(model.limitedLibrary)
        #expect(model.showsLimitedNotice)
    }

    @Test func allowAndCheckAgain() async {
        let photos = FakePhotos(auth: .notDetermined, grantsOnRequest: .limited)
        let model = makeModel(photos: photos)
        await model.onAppear()
        await model.perform(.allowAccess)
        #expect(model.authorization == .limited)
        photos.auth = .authorized
        await model.perform(.checkAgain)
        #expect(model.authorization == .authorized)
    }
}

@Suite("Photo index actions")
@MainActor
struct IndexActionTests {
    @Test func rebuildPollsStatusAndEndsReady() async {
        let photos = FakePhotos()
        photos.status = PhotoIndexStatus(state: .notStarted)
        let sleeps = Locked<[Duration]>([])
        let model = makeModel(photos: photos, sleeps: sleeps)
        await model.onAppear()
        #expect(model.index.rebuildTitle == "Build index")
        let before = photos.statusCalls
        photos.status = PhotoIndexStatus(state: .indexing, indexedCount: 5, totalCount: 10)
        photos.waitForStatusCalls = before + 2
        await model.rebuildIndex()
        #expect(photos.statusCalls >= before + 2, "the screen polled the status while the rebuild ran")
        #expect(sleeps.get.count >= 1)
        photos.status = PhotoIndexStatus(state: .ready, indexedCount: 10, totalCount: 10)
        await model.refreshIndexStatus()
        #expect(photos.rebuilds == 1)
        #expect(model.indexAction == .idle)
        #expect(model.indexStatus.state == .ready)
        #expect(model.index.headline == "10 photos indexed")
    }

    @Test func rebuildFailureIsShownAndRetryable() async {
        let photos = FakePhotos()
        photos.rebuildError = ZoroError.unavailable(capability: "Photo index", reason: "not enough storage")
        let model = makeModel(photos: photos)
        await model.rebuildIndex()
        #expect(model.indexAction == .failed("Photo index is not available: not enough storage."))
        photos.rebuildError = nil
        await model.rebuildIndex()
        #expect(model.indexAction == .idle)
        #expect(photos.rebuilds == 2)
    }

    @Test func deleteClearsResultsAndStatus() async {
        let photos = FakePhotos()
        photos.pages = [.success(PhotoSearchResult(hits: [hit("A")], indexedCount: 1, limitedLibrary: false, nextCursor: "n"))]
        let model = makeModel(photos: photos)
        model.queryText = "cap"
        await model.search()
        #expect(model.phase == .results)
        await model.deleteIndex()
        #expect(photos.deletes == 1)
        #expect(model.phase == .idle)
        #expect(model.hits.isEmpty && model.chips.isEmpty && model.nextCursor == nil)
        #expect(model.indexStatus.state == .notStarted)
        #expect(model.index.canRebuild)
    }

    @Test func deleteFailureKeepsTheResults() async {
        let photos = FakePhotos()
        photos.deleteError = ZoroError.storage("busy")
        let model = makeModel(photos: photos)
        await model.deleteIndex()
        if case .failed = model.indexAction {} else { Issue.record("expected failure") }
    }

    @Test func monitorStopsWhenIndexingEnds() async {
        let photos = FakePhotos()
        photos.statusScript = [
            PhotoIndexStatus(state: .indexing, indexedCount: 1, totalCount: 10),
            PhotoIndexStatus(state: .indexing, indexedCount: 5, totalCount: 10),
            PhotoIndexStatus(state: .ready, indexedCount: 10, totalCount: 10),
        ]
        let sleeps = Locked<[Duration]>([])
        let model = makeModel(photos: photos, sleeps: sleeps)
        await model.monitorIndex()
        #expect(photos.statusCalls == 3)
        #expect(sleeps.get.count == 2)
        #expect(model.indexStatus.state == .ready)
    }
}
