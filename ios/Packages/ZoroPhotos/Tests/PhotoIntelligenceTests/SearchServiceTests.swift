import Foundation
import Testing
import ZoroCore
@testable import PhotoIntelligence

@Suite("Search service and device.photos.search handler")
struct SearchServiceTests {
    /// Four photos: the blue cap from yesterday, a red cap from yesterday, a blue sky last week, a screenshot.
    func populated() async throws -> Fixture {
        let f = try Fixture()
        f.addPhoto("blue-cap", at: "2026-11-11T17:00:00+05:30", pixels: bluePatchPicture(), labels: [("baseball_hat", 0.85), ("outdoor", 0.6)])
        f.addPhoto("red-cap", at: "2026-11-11T12:00:00+05:30", pixels: solid(220, 20, 30), labels: [("hat", 0.9)])
        f.addPhoto("sky", at: "2026-11-04T08:00:00+05:30", pixels: solid(40, 90, 230), labels: [("sky", 0.9)])
        f.addPhoto("bill", at: "2026-11-11T09:00:00+05:30", kind: .screenshot, pixels: solid(255, 255, 255),
                   labels: [("document", 0.7)], text: ["Airtel invoice #4521"])
        try await f.service.indexNow()
        return f
    }

    func request(_ args: JSONObject, tool: String = PhotoSearchActionHandler.toolName, expires: Date = fixedNow.addingTimeInterval(60)) -> DeviceActionRequest {
        DeviceActionRequest(actionId: "act-1", turnId: "turn-1", tool: tool, args: args, risk: .low, expiresAt: expires)
    }

    func handler(_ f: Fixture, prompt: Bool = true) -> PhotoSearchActionHandler {
        PhotoSearchActionHandler(service: f.service, timeZone: ist, requestAuthorizationIfNeeded: prompt, now: { fixedNow })
    }

    @Test("the contract example finds the blue cap first")
    func contractExample() async throws {
        let f = try await populated()
        let response = try await f.service.search(PhotoQuery(
            text: "photo from yesterday with my blue cap", dateFrom: CalendarDate("2026-11-11"), dateTo: CalendarDate("2026-11-11"),
            colors: ["blue"], labels: ["cap", "hat"]))
        #expect(response.hits.map(\.assetId) == ["blue-cap", "red-cap"])
        #expect(response.hits[0].matched.contains("color:blue"))
        #expect(response.hits[0].matched.contains("label:baseball hat"))
        #expect(response.indexedCount == 4)
        #expect(response.limitedLibrary == false)
        #expect(response.nextCursor == nil)
    }

    @Test(arguments: ["kal ki neeli topi wali photo", "कल की नीली टोपी वाली फोटो", "yesterday blue cap"])
    func offlineParsingInThreeLanguages(_ text: String) async throws {
        let f = try await populated()
        let response = try await f.service.search(PhotoQuery(text: text))
        #expect(response.hits.first?.assetId == "blue-cap")
        #expect(!response.hits.contains { $0.assetId == "sky" }, "last week is outside 'yesterday'")
    }

    @Test func screenshotTextSearch() async throws {
        let f = try await populated()
        let response = try await f.service.search(PhotoQuery(containsText: "invoice 4521", media: .screenshot))
        #expect(response.hits.map(\.assetId) == ["bill"])
        #expect(response.hits[0].matched == ["text:invoice", "text:4521", "media:screenshot"])
    }

    @Test func paginationWalksTheWholeResult() async throws {
        let f = try Fixture()
        for i in 0..<7 { f.addPhoto("p\(i)", at: "2026-11-0\(i + 1)T10:00:00Z", labels: [("dog", 0.9)]) }
        try await f.service.indexNow()
        var seen: [String] = []
        var cursor: String?
        repeat {
            let page = try await f.service.search(PhotoQuery(text: "kutta", limit: 3, cursor: cursor))
            #expect(page.hits.count <= 3)
            seen += page.hits.map(\.assetId)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(seen == ["p6", "p5", "p4", "p3", "p2", "p1", "p0"])
    }

    @Test("results never include assets outside the granted library")
    func limitedLibraryHidesUnselected() async throws {
        let f = try await populated()
        f.library.set { $0.status = .limited; $0.selection = ["red-cap", "sky", "bill"] }
        let response = try await f.service.search(PhotoQuery(text: "blue cap"))
        #expect(!response.hits.contains { $0.assetId == "blue-cap" })
        #expect(response.hits.first?.assetId == "red-cap")
        #expect(response.limitedLibrary)
        #expect(try await f.store.asset(id: "blue-cap") == nil, "stale entry pruned")
    }

    @Test func deniedAccessFailsSearch() async throws {
        let f = try await populated()
        f.library.set { $0.status = .denied }
        await #expect(throws: PhotoSearchError.permissionDenied(.denied)) {
            try await f.service.search(PhotoQuery(text: "cap"))
        }
        #expect(PhotoSearchError.permissionDenied(.denied).localizedDescription.contains("Settings"))
    }

    @Test func photoSearchingConformance() async throws {
        let f = try await populated()
        let searching: any PhotoSearching = f.service
        let result = try await searching.search(PhotoQuery(text: "neela topi", media: .photo))
        #expect(result.hits.first?.assetId == "blue-cap")
        #expect(result.hits.first?.matched.contains("color:blue") == true)
        #expect(result.indexedCount == 4 && !result.limitedLibrary)
        let screenshots = try await searching.search(PhotoQuery(media: .screenshot))
        #expect(screenshots.hits.map(\.assetId) == ["bill"])
        #expect(screenshots.hits.allSatisfy { $0.media == .screenshot })
        #expect(await searching.indexStatus().indexedCount == 4)
        try await searching.deleteIndex()
        #expect(try await f.store.rowCounts().values.allSatisfy { $0 == 0 })
        #expect(await searching.indexStatus().state == .notStarted)
    }

    @Test func similarPhotosUseFeaturePrints() async throws {
        let f = try Fixture()
        f.addPhoto("a", at: "2026-11-01T10:00:00Z", featurePrint: [0, 0, 1])
        f.addPhoto("b", at: "2026-11-02T10:00:00Z", featurePrint: [0, 0.1, 1])
        f.addPhoto("c", at: "2026-11-03T10:00:00Z", featurePrint: [9, 9, 9])
        try await f.service.indexNow()
        let hits = try await f.service.similarPhotos(to: "a", limit: 1)
        #expect(hits.map(\.assetId) == ["b"])
        #expect(hits[0].matched == ["similar"])
    }

    @Test func embedderImprovesSearchWhenPresent() async throws {
        let library = FakeLibrary()
        let analyzer = FakeAnalyzer()
        let beach = makeImage(solid(230, 210, 160)), party = makeImage(solid(60, 20, 80))
        library.add(LibraryAsset(id: "beach", capturedAt: fixedNow, modifiedAt: fixedNow, kind: .photo, hasLocation: false), image: beach)
        library.add(LibraryAsset(id: "party", capturedAt: fixedNow, modifiedAt: fixedNow, kind: .photo, hasLocation: false), image: party)
        analyzer.register(beach, VisualAnalysis(labels: [VisualLabel(name: "sand", confidence: 0.6)]))
        analyzer.register(party, VisualAnalysis(labels: [VisualLabel(name: "people", confidence: 0.6)]))
        let embedder = FakeEmbedder(imageWords: [ObjectIdentifier(beach): "beach", ObjectIdentifier(party): "party"])
        let service = PhotoIntelligenceService(
            library: library, analyzer: analyzer, sampler: CoreGraphicsPixelSampler(), power: FakePower(), store: try PhotoIndexStore(),
            embedder: embedder, configuration: PhotoServiceConfiguration(autoIndexOnSearch: false), timeZone: ist, now: { fixedNow })
        try await service.indexNow()
        let response = try await service.search(PhotoQuery(text: "goa trip beach"))
        #expect(response.hits.first?.assetId == "beach")
        #expect(response.hits.first?.matched.contains("similar") == true)
        #expect(!response.hits.contains { $0.assetId == "party" })
    }

    // MARK: Handler

    @Test("handler result shape matches the device contract")
    func handlerResultShape() async throws {
        let f = try await populated()
        let result = await handler(f).execute(request([
            "query": ["text": "photo from yesterday with my blue cap", "date_from": "2026-11-11", "date_to": "2026-11-11",
                      "colors": ["blue"], "labels": ["cap", "hat"], "contains_text": nil, "media": "any", "limit": 30],
        ]))
        #expect(result.ok)
        #expect(result.actionId == "act-1")
        #expect(result.errorCode == nil)
        let body = try #require(result.result)
        #expect(Set(body.keys) == ["hits", "indexed_count", "limited_library", "next_cursor"])
        #expect(body["indexed_count"]?.intValue == 4)
        #expect(body["limited_library"]?.boolValue == false)
        #expect(body["next_cursor"] == .null)
        let hits = try #require(body["hits"]?.arrayValue)
        #expect(hits.count == 2)
        let first = try #require(hits.first?.objectValue)
        #expect(Set(["asset_id", "captured_at", "score", "labels", "matched"]).isSubset(of: Set(first.keys)))
        #expect(first["asset_id"]?.stringValue == "blue-cap")
        #expect(first["captured_at"]?.stringValue == "2026-11-11T17:00:00+05:30")
        #expect(first["score"]?.doubleValue.map { (0...1).contains($0) } == true)
        #expect(first["labels"]?.arrayValue?.compactMap(\.stringValue) == ["baseball hat", "outdoor"])
        #expect(first["matched"]?.arrayValue?.compactMap(\.stringValue).contains("color:blue") == true)
        // No image bytes anywhere in the payload.
        let encoded = try ZoroJSON.encoder().encode(JSONValue.object(body))
        #expect(encoded.count < 2_000)
        // The whole result round-trips through the contract type.
        let decoded = try ZoroJSON.decoder().decode(DeviceActionResult.self, from: ZoroJSON.encoder().encode(result))
        #expect(decoded == result)
    }

    @Test func handlerReportsLimitedLibrary() async throws {
        let f = try await populated()
        f.library.set { $0.status = .limited; $0.selection = ["sky"] }
        let result = await handler(f).execute(request(["query": ["text": "sky"]]))
        #expect(result.result?["limited_library"]?.boolValue == true)
        #expect(result.result?["hits"]?.arrayValue?.count == 1)
    }

    @Test func handlerPermissionDenied() async throws {
        let f = try await populated()
        f.library.set { $0.status = .denied }
        let result = await handler(f).execute(request(["query": ["text": "cap"]]))
        #expect(!result.ok)
        #expect(result.errorCode == "permission_denied")
        #expect(result.result == nil)
    }

    @Test("not determined: asks in context, then searches")
    func handlerAsksForPermission() async throws {
        let f = try await populated()
        f.library.set { $0.status = .notDetermined; $0.statusAfterRequest = .limited; $0.selection = ["red-cap"] }
        let result = await handler(f).execute(request(["query": ["text": "topi"]]))
        #expect(f.library.authorizationRequests == 1)
        #expect(result.ok)
        #expect(result.result?["limited_library"]?.boolValue == true)

        let g = try await populated()
        g.library.set { $0.status = .notDetermined }
        let silent = await handler(g, prompt: false).execute(request(["query": ["text": "topi"]]))
        #expect(silent.errorCode == "permission_denied")
        #expect(g.library.authorizationRequests == 0)
    }

    @Test func handlerRejectsWrongToolExpiredAndMalformed() async throws {
        let f = try await populated()
        let h = handler(f)
        #expect(h.supportedTools == ["device.photos.search"])
        #expect(await h.execute(request(["query": ["text": "x"]], tool: "device.music.control")).errorCode == "unsupported")
        #expect(await h.execute(request(["query": ["text": "x"]], expires: fixedNow.addingTimeInterval(-1))).errorCode == "expired")
        #expect(await h.execute(request([:])).errorCode == "invalid_arguments")
        let bad = await h.execute(request(["query": ["media": "video"]]))
        #expect(bad.errorCode == "invalid_arguments")
        #expect(bad.errorMessage?.contains("media") == true)
        let plain = await h.execute(request(["query": "blue cap"]))
        #expect(plain.ok)
    }
}
