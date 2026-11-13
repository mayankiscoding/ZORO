import Foundation
import Testing
import ZoroCore
@testable import PhotoIntelligence

@Suite("SQLite index store")
struct StoreTests {
    func item(
        _ id: String, captured: String = "2026-11-11T10:00:00+05:30", kind: PhotoMediaKind = .photo,
        labels: [(String, Double)] = [], text: String = "", colours: [RegionColour] = [], featurePrint: [Float]? = nil,
        embedding: [Float]? = nil, version: Int = 1, complete: Bool = true
    ) -> IndexedAsset {
        IndexedAsset(
            asset: LibraryAsset(id: id, capturedAt: date(captured), modifiedAt: date(captured), kind: kind, hasLocation: true),
            labels: labels.map { VisualLabel(name: $0.0, confidence: $0.1) }, text: text, colours: colours,
            featurePrint: featurePrint, embedding: embedding, embeddingModel: embedding == nil ? nil : "m1",
            analysisVersion: version, analysisComplete: complete, indexedAt: fixedNow)
    }

    @Test func roundTrip() async throws {
        let store = try PhotoIndexStore()
        let original = item(
            "A/L0/001", kind: .screenshot, labels: [("baseball_hat", 0.8), ("outdoor", 0.4)], text: "Hello WORLD",
            colours: [RegionColour(region: .full, colour: .blue, fraction: 0.4),
                      RegionColour(region: .cell(row: 1, column: 2), colour: .white, fraction: 0.9)],
            featurePrint: [0.1, 0.2, 0.3], embedding: [1, 0, 0])
        try await store.upsert([original])
        let loaded = try #require(try await store.asset(id: "A/L0/001"))
        #expect(loaded.asset == original.asset)
        #expect(Set(loaded.labels) == [VisualLabel(name: "baseball hat", confidence: 0.8), VisualLabel(name: "outdoor", confidence: 0.4)])
        #expect(loaded.text == "hello world")
        #expect(Set(loaded.colours) == Set(original.colours))
        #expect(loaded.featurePrint == [0.1, 0.2, 0.3])
        #expect(loaded.embedding == [1, 0, 0])
        #expect(loaded.embeddingModel == "m1")
        #expect(loaded.analysisComplete)
        #expect(try await store.count() == 1)
        #expect(try await store.asset(id: "missing") == nil)
    }

    @Test func ftsMatchesLabelsAndTextInBothScripts() async throws {
        let store = try PhotoIndexStore()
        try await store.upsert([
            item("1", labels: [("sunset_sunrise", 0.9)], text: "Airtel invoice November"),
            item("2", labels: [("dog", 0.9)], text: "शुभ दीपावली नमस्ते"),
            item("3", labels: [("hat", 0.9)], text: "sale"),
        ])
        #expect(try await store.textMatches(["sunset"], in: .labels) == ["1"])
        #expect(try await store.textMatches(["dog", "hat"], in: .labels) == ["2", "3"])
        #expect(try await store.textMatches(["invoice"], in: .body) == ["1"])
        #expect(try await store.textMatches(["दीपावली"], in: .body) == ["2"])
        #expect(try await store.textMatches(["नमस्ते"], in: .body) == ["2"])
        #expect(try await store.textMatches(["invoice"], in: .labels).isEmpty)
    }

    @Test("query syntax in user words is never interpreted")
    func ftsInjectionIsInert() async throws {
        let store = try PhotoIndexStore()
        try await store.upsert([item("1", text: "hello world")])
        for hostile in ["\"", "hello OR", "NEAR(", "*", "body:", "a\" OR \"b", "-hello", "{labels}"] {
            _ = try await store.textMatches([hostile], in: .body)
        }
        #expect(try await store.textMatches(["hello\" OR \"x"], in: .body).isEmpty)
    }

    @Test func candidatesUseFtsColourAndFilters() async throws {
        let store = try PhotoIndexStore()
        try await store.upsert([
            item("cap", captured: "2026-11-11T09:00:00+05:30", labels: [("baseball cap", 0.9)]),
            item("blue", captured: "2026-11-11T09:00:00+05:30", colours: [RegionColour(region: .full, colour: .blue, fraction: 0.5)]),
            item("old-cap", captured: "2026-10-01T09:00:00+05:30", labels: [("cap", 0.9)]),
            item("shot", captured: "2026-11-11T09:00:00+05:30", kind: .screenshot, labels: [("cap", 0.9)]),
            item("bill", captured: "2026-11-11T09:00:00+05:30", text: "airtel invoices"),
        ])
        let day = DateInterval(start: date("2026-11-11T00:00:00+05:30"), end: date("2026-11-11T23:59:59+05:30"))
        let hat = LabelGroup(display: "cap", terms: ["cap", "hat"])
        let plan = SearchPlan(dateInterval: day, media: .photo, labelGroups: [hat], colours: [.blue])
        let ids = Set(try await store.candidates(for: plan).map(\.assetId))
        #expect(ids == ["cap", "blue"])
        let prefix = SearchPlan(freeTerms: ["invoice"])
        #expect(try await store.candidates(for: prefix).map(\.assetId) == ["bill"])
        let filtersOnly = try await store.candidates(for: SearchPlan(media: .screenshot))
        #expect(filtersOnly.map(\.assetId) == ["shot"])
    }

    @Test("re-indexing an asset replaces its labels, colours and text")
    func incrementalUpdate() async throws {
        let store = try PhotoIndexStore()
        try await store.upsert([item("1", labels: [("dog", 0.9)], text: "first",
                                     colours: [RegionColour(region: .full, colour: .red, fraction: 0.6)])])
        try await store.upsert([item("1", labels: [("cat", 0.8)], text: "second", version: 2)])
        #expect(try await store.count() == 1)
        #expect(try await store.textMatches(["dog"], in: .labels).isEmpty)
        #expect(try await store.textMatches(["cat"], in: .labels) == ["1"])
        #expect(try await store.textMatches(["first"], in: .body).isEmpty)
        let reloaded = try await store.asset(id: "1")
        #expect(reloaded?.colours.isEmpty == true)
        #expect(try await store.fingerprints()["1"]?.analysisVersion == 2)
        let counts = try await store.rowCounts()
        #expect(counts["labels"] == 1 && counts["asset_fts"] == 1 && counts["colours"] == 0)
    }

    @Test func deleteRemovesDerivedRows() async throws {
        let store = try PhotoIndexStore()
        try await store.upsert([
            item("1", labels: [("dog", 0.9)], text: "a", colours: [RegionColour(region: .full, colour: .red, fraction: 0.6)]),
            item("2", labels: [("cat", 0.9)], text: "b"),
        ])
        #expect(try await store.delete(assetIds: ["1", "missing"]) == 1)
        let counts = try await store.rowCounts()
        #expect(counts == ["assets": 1, "labels": 1, "colours": 0, "asset_fts": 1, "meta": 0])
        #expect(try await store.textMatches(["dog"], in: .labels).isEmpty)
    }

    @Test("deleting the index leaves no rows")
    func deleteAllLeavesNothing() async throws {
        let store = try PhotoIndexStore()
        try await store.upsert((0..<50).map {
            item("id\($0)", labels: [("dog", 0.9)], text: "text \($0)",
                 colours: [RegionColour(region: .full, colour: .red, fraction: 0.6)], featurePrint: [1, 2])
        })
        try await store.setMeta("total_count", "50")
        try await store.deleteAll()
        #expect(try await store.rowCounts() == ["assets": 0, "labels": 0, "colours": 0, "asset_fts": 0, "meta": 0])
        #expect(try await store.fingerprints().isEmpty)
        // Still usable afterwards.
        try await store.upsert([item("again")])
        #expect(try await store.count() == 1)
    }

    @Test func fileStoreIsExcludedFromBackupAndReopens() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zoro-photos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        do {
            let store = try PhotoIndexStore(fileURL: url)
            try await store.upsert([item("1", labels: [("dog", 0.9)])])
        }
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let reopened = try PhotoIndexStore(fileURL: url)
        #expect(try await reopened.count() == 1)
        #expect(try await reopened.textMatches(["dog"], in: .labels) == ["1"])
    }

    @Test func embeddingNeighboursAndFeaturePrintSimilarity() async throws {
        let store = try PhotoIndexStore()
        try await store.upsert([
            item("beach", featurePrint: [0, 0, 1], embedding: [1, 0, 0]),
            item("beach2", featurePrint: [0, 0.1, 1], embedding: [0.9, 0.1, 0]),
            item("party", featurePrint: [5, 5, 5], embedding: [0, 0, 1]),
            item("none"),
        ])
        let near = try await store.embeddingNeighbours(of: [1, 0, 0], model: "m1", plan: SearchPlan(), minimum: 0.5, limit: 10)
        #expect(Set(near.keys) == ["beach", "beach2"])
        #expect(try await store.embeddingNeighbours(of: [1, 0, 0], model: "other", plan: SearchPlan(), minimum: 0, limit: 10).isEmpty)
        let similar = try await store.similarByFeaturePrint(to: "beach", limit: 5)
        #expect(similar.map(\.assetId) == ["beach2", "party"])
        #expect(try await store.similarByFeaturePrint(to: "none", limit: 5).isEmpty)
    }

    @Test func vectorMath() {
        #expect(VectorMath.cosine([1, 0], [1, 0]) == 1)
        #expect(VectorMath.cosine([1, 0], [0, 1]) == 0)
        #expect(VectorMath.cosine([1], [1, 2]) == nil)
        #expect(VectorMath.euclidean([0, 0], [3, 4]) == 5)
        #expect(VectorMath.decode(VectorMath.encode([1.5, -2])) == [1.5, -2])
    }
}
