import Foundation
import Testing
import ZoroCore
@testable import PhotoIntelligence

@Suite("Indexing pipeline")
struct IndexerTests {
    @Test func planFindsNewChangedRemovedAndRetries() {
        let t1 = date("2026-11-01T10:00:00Z"), t2 = date("2026-11-02T10:00:00Z")
        let library = [
            LibraryAsset(id: "same", capturedAt: t1, modifiedAt: t1, kind: .photo, hasLocation: false),
            LibraryAsset(id: "edited", capturedAt: t1, modifiedAt: t2, kind: .photo, hasLocation: false),
            LibraryAsset(id: "new-old", capturedAt: t1, modifiedAt: t1, kind: .photo, hasLocation: false),
            LibraryAsset(id: "new-recent", capturedAt: t2, modifiedAt: t2, kind: .photo, hasLocation: false),
            LibraryAsset(id: "cloud-only", capturedAt: t2, modifiedAt: t2, kind: .photo, hasLocation: false),
            LibraryAsset(id: "same", capturedAt: t1, modifiedAt: t1, kind: .photo, hasLocation: false),
        ]
        let indexed: [String: IndexFingerprint] = [
            "same": IndexFingerprint(modifiedAt: t1, analysisVersion: 1, analysisComplete: true),
            "edited": IndexFingerprint(modifiedAt: t1, analysisVersion: 1, analysisComplete: true),
            "cloud-only": IndexFingerprint(modifiedAt: t2, analysisVersion: 1, analysisComplete: false),
            "deleted": IndexFingerprint(modifiedAt: t1, analysisVersion: 1, analysisComplete: true),
        ]
        let plan = IndexPlan.make(library: library, indexed: indexed, analysisVersion: 1)
        #expect(plan.toIndex.map(\.id) == ["new-recent", "edited", "new-old", "cloud-only"])
        #expect(plan.toDelete == ["deleted"])
        #expect(plan.unchanged == 1)
        let upgraded = IndexPlan.make(library: library, indexed: indexed, analysisVersion: 2)
        #expect(upgraded.toIndex.count == 5)
    }

    @Test func powerPolicy() {
        #expect(IndexingPolicy.pauseReason(PowerCondition(lowPowerMode: true)) == .lowPowerMode)
        #expect(IndexingPolicy.pauseReason(PowerCondition(thermal: .serious)) == .thermalPressure)
        #expect(IndexingPolicy.pauseReason(PowerCondition(thermal: .critical)) == .thermalPressure)
        #expect(IndexingPolicy.pauseReason(PowerCondition(thermal: .fair)) == nil)
        #expect(IndexingPolicy.concurrency(PowerCondition(thermal: .fair), maximum: 4) == 1)
        #expect(IndexingPolicy.concurrency(PowerCondition(), maximum: 4) == 4)
    }

    @Test func fullPassIndexesEverySignal() async throws {
        let f = try Fixture()
        f.addPhoto("p1", at: "2026-11-11T18:00:00+05:30", pixels: bluePatchPicture(), labels: [("baseball_hat", 0.9)],
                   text: ["Goa 2026"], featurePrint: [1, 2, 3])
        f.addPhoto("p2", at: "2026-11-10T18:00:00+05:30", kind: .screenshot, text: ["Airtel invoice"])
        let report = try await f.service.indexNow()
        #expect(report == IndexPassReport(indexed: 2, metadataOnly: 0, deleted: 0, unchanged: 0, total: 2))
        let p1 = try #require(try await f.store.asset(id: "p1"))
        #expect(p1.labels.map(\.name) == ["baseball hat"])
        #expect(p1.text == "goa 2026")
        #expect(p1.featurePrint == [1, 2, 3])
        #expect(p1.colours.contains { $0.region == .cell(row: 0, column: 0) && $0.colour == .blue })
        #expect(p1.colours.contains { $0.region == .full && $0.colour == .white })
        let status = await f.service.indexStatus()
        #expect(status.state == .ready && status.indexedCount == 2 && status.totalCount == 2)
    }

    @Test("second pass touches only new and changed assets; removed ones are deleted")
    func incrementalPass() async throws {
        let f = try Fixture()
        f.addPhoto("a", at: "2026-11-01T10:00:00Z", labels: [("dog", 0.9)])
        f.addPhoto("b", at: "2026-11-02T10:00:00Z", labels: [("cat", 0.9)])
        f.addPhoto("c", at: "2026-11-03T10:00:00Z", labels: [("tree", 0.9)])
        try await f.service.indexNow()
        let callsAfterFirst = f.analyzer.calls.withLock { $0 }
        #expect(callsAfterFirst == 3)

        f.addPhoto("b", at: "2026-11-02T10:00:00Z", labels: [("bird", 0.9)], modified: date("2026-11-12T00:00:00Z"))
        f.addPhoto("d", at: "2026-11-04T10:00:00Z", labels: [("car", 0.9)])
        f.library.set { $0.assets.removeAll { $0.id == "c" } }
        let report = try await f.service.indexNow()
        #expect(report.indexed == 2 && report.deleted == 1 && report.unchanged == 1 && report.total == 3)
        #expect(f.analyzer.calls.withLock { $0 } == 5)
        #expect(try await f.store.asset(id: "b")?.labels.map(\.name) == ["bird"])
        #expect(try await f.store.asset(id: "c") == nil)
    }

    @Test("an image that cannot be analysed stays searchable by date and kind, and is retried later")
    func metadataOnlyFallback() async throws {
        let f = try Fixture()
        f.addPhoto("broken", at: "2026-11-01T10:00:00Z", analysable: false)
        f.library.add(LibraryAsset(id: "cloud", capturedAt: date("2026-11-02T10:00:00Z"), modifiedAt: nil, kind: .photo, hasLocation: true))
        let report = try await f.service.indexNow()
        #expect(report.metadataOnly == 2 && report.indexed == 0)
        #expect(try await f.store.asset(id: "cloud")?.analysisComplete == false)
        let second = try await f.service.indexNow()
        #expect(second.metadataOnly == 2, "incomplete entries are retried")
    }

    @Test("limited library: assets removed from the selection leave the index")
    func limitedSelectionShrinks() async throws {
        let f = try Fixture()
        f.addPhoto("keep", at: "2026-11-01T10:00:00Z", labels: [("dog", 0.9)])
        f.addPhoto("drop", at: "2026-11-02T10:00:00Z", labels: [("dog", 0.9)])
        try await f.service.indexNow()
        f.library.set { $0.status = .limited; $0.selection = ["keep"] }
        let report = try await f.service.indexNow()
        #expect(report.deleted == 1)
        #expect(Set(try await f.store.fingerprints().keys) == ["keep"])
    }

    @Test("losing photo access deletes the derived index")
    func deniedDeletesIndex() async throws {
        let f = try Fixture()
        f.addPhoto("a", at: "2026-11-01T10:00:00Z", labels: [("dog", 0.9)], text: ["secret"])
        try await f.service.indexNow()
        f.library.set { $0.status = .denied }
        await #expect(throws: PhotoSearchError.permissionDenied(.denied)) { try await f.service.indexNow() }
        #expect(try await f.store.rowCounts()["assets"] == 0)
        #expect(try await f.store.rowCounts()["asset_fts"] == 0)
    }

    @Test func notDeterminedNeverPromptsDuringIndexing() async throws {
        let f = try Fixture()
        f.library.set { $0.status = .notDetermined }
        await #expect(throws: PhotoSearchError.self) { try await f.service.indexNow() }
        #expect(f.library.authorizationRequests == 0)
    }

    @Test("Low Power Mode pauses indexing; it resumes when the mode ends")
    func pausesInLowPowerMode() async throws {
        let power = FakePower(PowerCondition(lowPowerMode: true))
        let f = try Fixture(power: power)
        f.addPhoto("a", at: "2026-11-01T10:00:00Z", labels: [("dog", 0.9)])
        let pass = Task { try await f.service.indexNow() }
        try await waitUntil { await f.service.progress().state == .paused(.lowPowerMode) }
        #expect(f.analyzer.calls.withLock { $0 } == 0)
        let status = await f.service.indexStatus()
        #expect(status.state == .paused && status.pausedReason == "low_power_mode" && status.failureReason == nil)
        try await waitUntil { power.observerCount > 0 }
        power.set(PowerCondition())
        let report = try await pass.value
        #expect(report.indexed == 1)
    }

    @Test func thermalPressurePausesToo() async throws {
        let power = FakePower(PowerCondition(thermal: .serious))
        let f = try Fixture(power: power)
        f.addPhoto("a", at: "2026-11-01T10:00:00Z")
        let pass = Task { try await f.service.indexNow() }
        try await waitUntil { await f.service.progress().state == .paused(.thermalPressure) }
        pass.cancel()
        await #expect(throws: CancellationError.self) { try await pass.value }
        #expect(try await f.store.count() == 0)
    }

    @Test("cancelling stops after the current batch; the next pass resumes where it stopped")
    func cancellationAndResume() async throws {
        let f = try Fixture(analyzerDelay: .milliseconds(30), batchSize: 2)
        for i in 0..<8 { f.addPhoto("p\(i)", at: "2026-11-0\(i + 1)T10:00:00Z", labels: [("dog", 0.9)]) }
        let pass = Task { try await f.service.indexNow() }
        try await waitUntil { (try? await f.store.count()) ?? 0 >= 2 }
        pass.cancel()
        _ = try? await pass.value
        let partial = try await f.store.count()
        #expect(partial >= 2 && partial < 8)
        let report = try await f.service.indexNow()
        #expect(report.unchanged == partial)
        #expect(report.indexed == 8 - partial)
        #expect(try await f.store.count() == 8)
    }

    @Test func embeddingsAreStoredWhenAnEmbedderExists() async throws {
        let library = FakeLibrary()
        let analyzer = FakeAnalyzer()
        let image = makeImage(solid(200, 200, 100))
        library.add(LibraryAsset(id: "b", capturedAt: fixedNow, modifiedAt: fixedNow, kind: .photo, hasLocation: false), image: image)
        analyzer.register(image, VisualAnalysis(labels: [VisualLabel(name: "sand", confidence: 0.7)]))
        let store = try PhotoIndexStore()
        let indexer = PhotoIndexer(
            library: library, analyzer: analyzer, sampler: CoreGraphicsPixelSampler(),
            embedder: FakeEmbedder(imageWords: [ObjectIdentifier(image): "beach"]), power: FakePower(), store: store)
        try await indexer.runPass()
        let stored = try await store.asset(id: "b")
        #expect(stored?.embeddingModel == "fake-clip-v1")
        #expect(stored?.embedding?.count == 3)
    }
}

/// Polls a condition (bounded) without blocking a thread.
func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await !condition() {
        guard clock.now < deadline else { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct WaitTimeout: Error {}
