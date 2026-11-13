import Foundation
import ZoroCore

public struct IndexerConfiguration: Sendable, Equatable {
    /// Assets analysed and written per transaction; progress survives an interruption after each batch.
    public var batchSize: Int
    /// Images analysed at once (lowered to 1 when the device is warm).
    public var maxConcurrency: Int
    /// Longer side of the requested rendition.
    public var thumbnailSide: Int
    /// Longer side used for colour analysis.
    public var colourSampleSide: Int
    /// Bump when the analysis changes so older entries are redone.
    public var analysisVersion: Int
    /// While paused, how often the power state is re-checked if no change notification arrives.
    public var pauseRecheck: Duration

    public init(
        batchSize: Int = 24, maxConcurrency: Int = 2, thumbnailSide: Int = 384, colourSampleSide: Int = 48,
        analysisVersion: Int = 1, pauseRecheck: Duration = .seconds(60)
    ) {
        self.batchSize = max(1, batchSize)
        self.maxConcurrency = max(1, maxConcurrency)
        self.thumbnailSide = thumbnailSide
        self.colourSampleSide = colourSampleSide
        self.analysisVersion = analysisVersion
        self.pauseRecheck = pauseRecheck
    }
}

/// Builds and maintains the index: incremental (only new or changed assets), resumable (each batch
/// is committed), battery-aware (pauses in Low Power Mode or under thermal pressure, bounded
/// concurrency) and cancellable.
public actor PhotoIndexer {
    private let library: any PhotoLibraryProviding
    private let analyzer: any ImageAnalyzing
    private let sampler: any PixelSampling
    private let embedder: (any ImageTextEmbedder)?
    private let power: any PowerMonitoring
    private let store: PhotoIndexStore
    private let configuration: IndexerConfiguration
    private let colours: DominantColourExtractor
    private let now: @Sendable () -> Date
    private let log = ZoroLog("photos.index")

    public private(set) var progress = IndexProgress()

    public init(
        library: any PhotoLibraryProviding, analyzer: any ImageAnalyzing, sampler: any PixelSampling,
        embedder: (any ImageTextEmbedder)? = nil, power: any PowerMonitoring, store: PhotoIndexStore,
        configuration: IndexerConfiguration = IndexerConfiguration(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.library = library
        self.analyzer = analyzer
        self.sampler = sampler
        self.embedder = embedder
        self.power = power
        self.store = store
        self.configuration = configuration
        self.colours = DominantColourExtractor(sampleSide: configuration.colourSampleSide)
        self.now = now
    }

    /// One pass: drop what is gone, index what is new or changed.
    /// Without photo access it deletes the whole index (derived data of photos the app may no longer
    /// read is not kept) and throws `PhotoSearchError.permissionDenied`.
    @discardableResult
    public func runPass() async throws -> IndexPassReport {
        let status = await library.authorizationStatus()
        guard status == .authorized || status == .limited else {
            if status == .denied || status == .restricted {
                try await store.deleteAll()
            }
            progress.state = .failed("permission_denied")
            throw PhotoSearchError.permissionDenied(status)
        }
        progress.state = .indexing
        do {
            let report = try await indexAll()
            progress.state = .idle
            progress.lastCompletedAt = now()
            try await store.setMeta("last_completed_at", String(now().timeIntervalSince1970))
            return report
        } catch is CancellationError {
            progress.state = .idle
            throw CancellationError()
        } catch {
            progress.state = .failed(String(describing: type(of: error)))
            log.error("indexing pass failed", error: error)
            throw error
        }
    }

    private func indexAll() async throws -> IndexPassReport {
        let assets = try await library.fetchAssets()
        let plan = IndexPlan.make(
            library: assets, indexed: try await store.fingerprints(), analysisVersion: configuration.analysisVersion)
        var report = IndexPassReport(unchanged: plan.unchanged, total: assets.count)
        report.deleted = try await store.delete(assetIds: plan.toDelete)
        try await store.setMeta("total_count", String(assets.count))
        progress.totalCount = assets.count
        progress.indexedCount = try await store.count()

        var start = 0
        while start < plan.toIndex.count {
            try Task.checkCancellation()
            let condition = try await waitUntilPowerAllows()
            progress.state = .indexing
            let width = IndexingPolicy.concurrency(condition, maximum: configuration.maxConcurrency)
            let batch = Array(plan.toIndex[start..<min(start + configuration.batchSize, plan.toIndex.count)])
            let results = try await analyze(batch, width: width)
            try Task.checkCancellation()
            try await store.upsert(results)
            report.indexed += results.filter(\.analysisComplete).count
            report.metadataOnly += results.filter { !$0.analysisComplete }.count
            progress.indexedCount = try await store.count()
            start += batch.count
        }
        return report
    }

    /// Analyses a batch with at most `width` images in flight; results keep the batch order.
    private func analyze(_ batch: [LibraryAsset], width: Int) async throws -> [IndexedAsset] {
        let library = self.library, analyzer = self.analyzer, sampler = self.sampler, embedder = self.embedder
        let colours = self.colours, configuration = self.configuration, now = self.now
        return try await withThrowingTaskGroup(of: (Int, IndexedAsset).self) { group in
            var results = [IndexedAsset?](repeating: nil, count: batch.count)
            var next = 0
            func addNext() {
                guard next < batch.count else { return }
                let index = next, asset = batch[index]
                next += 1
                group.addTask {
                    let item = await Self.analyzeOne(
                        asset, library: library, analyzer: analyzer, sampler: sampler, embedder: embedder,
                        colours: colours, configuration: configuration, now: now)
                    return (index, item)
                }
            }
            for _ in 0..<min(width, batch.count) { addNext() }
            while let (index, item) = try await group.next() {
                results[index] = item
                addNext()
            }
            try Task.checkCancellation()
            return results.compactMap { $0 }
        }
    }

    /// Never throws: a failed analysis keeps the asset searchable by date and media type.
    static func analyzeOne(
        _ asset: LibraryAsset, library: any PhotoLibraryProviding, analyzer: any ImageAnalyzing, sampler: any PixelSampling,
        embedder: (any ImageTextEmbedder)?, colours: DominantColourExtractor, configuration: IndexerConfiguration,
        now: @Sendable () -> Date
    ) async -> IndexedAsset {
        var item = IndexedAsset(asset: asset, analysisVersion: configuration.analysisVersion, analysisComplete: false, indexedAt: now())
        guard !Task.isCancelled,
              let image = try? await library.thumbnail(for: asset.id, maxPixelSize: configuration.thumbnailSide)
        else { return item }
        do {
            let analysis = try await analyzer.analyze(image)
            item.labels = analysis.labels
            item.text = analysis.textLines.joined(separator: " ")
            item.featurePrint = analysis.featurePrint
            if let pixels = sampler.pixels(of: image, maxSide: configuration.colourSampleSide) {
                item.colours = colours.extract(from: pixels)
            }
            if let embedder, let vector = try? await embedder.embed(image: image), !vector.isEmpty {
                item.embedding = vector
                item.embeddingModel = embedder.modelIdentifier
            }
            item.analysisComplete = true
        } catch {
            item.analysisComplete = false
        }
        return item
    }

    /// Returns at once when indexing may run; otherwise reports `paused` and waits for a change.
    private func waitUntilPowerAllows() async throws -> PowerCondition {
        while true {
            try Task.checkCancellation()
            let condition = await power.current()
            guard let reason = IndexingPolicy.pauseReason(condition) else { return condition }
            progress.state = .paused(reason)
            log.info("indexing paused: \(reason.rawValue)")
            let updates = power.changes()
            if IndexingPolicy.pauseReason(await power.current()) == nil { continue }
            let recheck = configuration.pauseRecheck
            // Wake on the first change notification or after the re-check interval.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in updates { return }
                }
                group.addTask { try? await Task.sleep(for: recheck) }
                await group.next()
                group.cancelAll()
            }
        }
    }
}
