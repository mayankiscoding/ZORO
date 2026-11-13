import Foundation
import ZoroCore

public struct PhotoServiceConfiguration: Sendable, Equatable {
    /// Start background indexing the first time a search runs with access granted.
    public var autoIndexOnSearch: Bool
    /// Wait this long after a library change before re-indexing (changes come in bursts).
    public var changeDebounce: Duration
    /// Embedding neighbours considered per search.
    public var embeddingNeighbours: Int

    public init(autoIndexOnSearch: Bool = true, changeDebounce: Duration = .seconds(3), embeddingNeighbours: Int = 300) {
        self.autoIndexOnSearch = autoIndexOnSearch
        self.changeDebounce = changeDebounce
        self.embeddingNeighbours = embeddingNeighbours
    }
}

/// ZORO's private photo search. Conforms to `PhotoSearching`; everything runs on the device.
public actor PhotoIntelligenceService: PhotoSearching {
    public let store: PhotoIndexStore
    public let indexer: PhotoIndexer
    private let library: any PhotoLibraryProviding
    private let embedder: (any ImageTextEmbedder)?
    private let interpreter: QueryInterpreter
    private let ranker: PhotoRanker
    private let configuration: PhotoServiceConfiguration
    private let now: @Sendable () -> Date
    private var indexingTask: Task<Void, Never>?
    private var indexingGeneration = 0
    private let log = ZoroLog("photos.search")

    public init(
        library: any PhotoLibraryProviding, analyzer: any ImageAnalyzing, sampler: any PixelSampling,
        power: any PowerMonitoring, store: PhotoIndexStore, embedder: (any ImageTextEmbedder)? = nil,
        indexerConfiguration: IndexerConfiguration = IndexerConfiguration(),
        configuration: PhotoServiceConfiguration = PhotoServiceConfiguration(),
        ranking: RankingWeights = RankingWeights(), timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.library = library
        self.store = store
        self.embedder = embedder
        self.interpreter = QueryInterpreter(timeZone: timeZone)
        self.ranker = PhotoRanker(weights: ranking)
        self.configuration = configuration
        self.now = now
        self.indexer = PhotoIndexer(
            library: library, analyzer: analyzer, sampler: sampler, embedder: embedder, power: power, store: store,
            configuration: indexerConfiguration, now: now)
    }

    // MARK: - Search

    /// Contract search (`device.photos.search`). Results never include assets the app cannot read.
    /// Throws `PhotoSearchError.permissionDenied` without Photos access.
    public func search(_ request: PhotoQuery) async throws -> PhotoSearchResult {
        let status = await library.authorizationStatus()
        guard status == .authorized || status == .limited else { throw PhotoSearchError.permissionDenied(status) }
        if configuration.autoIndexOnSearch { startIndexing() }

        let plan = interpreter.plan(for: request, now: now())
        var similar: [String: Double] = [:]
        var useEmbedding = false
        if let embedder, plan.hasContentCriteria, let text = plan.embeddingText {
            do {
                let vector = try await embedder.embed(text: text)
                similar = try await store.embeddingNeighbours(
                    of: vector, model: embedder.modelIdentifier, plan: plan,
                    minimum: ranker.weights.embeddingFloor, limit: configuration.embeddingNeighbours)
                useEmbedding = true
            } catch {
                log.error("text embedding unavailable; searching without it", error: error)
            }
        }
        let candidates = try await store.candidates(for: plan, similar: similar)
        let ranked = ranker.rank(candidates, plan: plan, embeddingAvailable: useEmbedding)

        let offset = request.cursor.flatMap(Int.init).map { max(0, $0) } ?? 0
        var hits: [PhotoHit] = []
        var position = min(offset, ranked.count)
        var unreadable: [String] = []
        while hits.count < request.limit && position < ranked.count {
            let window = Array(ranked[position..<min(position + request.limit * 2, ranked.count)])
            let readable = await library.accessibleIdentifiers(among: window.map(\.assetId))
            for item in window {
                position += 1
                guard readable.contains(item.assetId) else {
                    unreadable.append(item.assetId)
                    continue
                }
                hits.append(PhotoHit(
                    assetId: item.assetId, capturedAt: item.capturedAt, score: item.score, labels: item.labels,
                    matched: item.matched, media: item.media))
                if hits.count == request.limit { break }
            }
        }
        if !unreadable.isEmpty {
            _ = try? await store.delete(assetIds: unreadable)  // stale entries: no longer in the granted library
        }
        return PhotoSearchResult(
            hits: hits, indexedCount: try await store.count(), limitedLibrary: status == .limited,
            nextCursor: position < ranked.count ? String(position) : nil)
    }

    /// Photos that look like `assetId` (Vision feature prints), closest first.
    public func similarPhotos(to assetId: String, limit: Int = 30) async throws -> [PhotoHit] {
        let status = await library.authorizationStatus()
        guard status == .authorized || status == .limited else { throw PhotoSearchError.permissionDenied(status) }
        let neighbours = try await store.similarByFeaturePrint(to: assetId, limit: limit * 2)
        let readable = await library.accessibleIdentifiers(among: neighbours.map(\.assetId))
        var hits: [PhotoHit] = []
        for n in neighbours where readable.contains(n.assetId) && hits.count < limit {
            guard let asset = try await store.asset(id: n.assetId) else { continue }
            hits.append(PhotoHit(
                assetId: n.assetId, capturedAt: asset.asset.capturedAt, score: (1 / (1 + n.distance) * 1000).rounded() / 1000,
                labels: asset.labels.sorted { $0.confidence > $1.confidence }.prefix(5).map(\.name),
                matched: ["similar"], media: asset.asset.kind))
        }
        return hits
    }

    // MARK: - Indexing

    /// Starts background indexing (one pass, then a re-index after each library change).
    /// Does nothing while it is already running or before access is granted.
    public func startIndexing() {
        guard indexingTask == nil else { return }
        indexingGeneration += 1
        let generation = indexingGeneration
        let indexer = self.indexer, library = self.library, debounce = configuration.changeDebounce
        indexingTask = Task(priority: .utility) { [weak self] in
            let changes = library.changes()
            _ = try? await indexer.runPass()
            for await _ in changes {
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { break }
                _ = try? await indexer.runPass()
            }
            await self?.indexingFinished(generation)
        }
    }

    private func indexingFinished(_ generation: Int) {
        if generation == indexingGeneration { indexingTask = nil }
    }

    /// Cancels background indexing and waits until it has stopped writing.
    public func stopIndexing() async {
        guard let task = indexingTask else { return }
        indexingTask = nil
        indexingGeneration += 1
        task.cancel()
        await task.value
    }

    public var isIndexing: Bool { indexingTask != nil }

    /// Runs one pass now and waits for it (BGProcessingTask handlers, tests). Cancel the calling
    /// task to stop it, for example when the background task expires.
    @discardableResult
    public func indexNow() async throws -> IndexPassReport {
        try await indexer.runPass()
    }

    public func progress() async -> IndexProgress { await indexer.progress }

    // MARK: - PhotoSearching

    public func authorizationStatus() async -> MediaAuthorization { await library.authorizationStatus() }

    public func requestAuthorization() async -> MediaAuthorization {
        let status = await library.requestAuthorization()
        if status == .authorized || status == .limited { startIndexing() }
        return status
    }

    public func indexStatus() async -> PhotoIndexStatus {
        let progress = await indexer.progress
        let indexed = (try? await store.count()) ?? progress.indexedCount
        // The store is the source of truth, so a deleted index reads as not started.
        let total = (try? await store.meta("total_count")).flatMap { $0.flatMap(Int.init) } ?? 0
        let last = (try? await store.meta("last_completed_at")).flatMap { $0.flatMap(Double.init) }
            .map(Date.init(timeIntervalSince1970:))
        switch progress.state {
        case .indexing:
            return PhotoIndexStatus(state: .indexing, indexedCount: indexed, totalCount: total, lastUpdatedAt: last)
        case .paused(let reason):
            return PhotoIndexStatus(state: .paused, indexedCount: indexed, totalCount: total, lastUpdatedAt: last, pausedReason: reason.rawValue)
        case .failed(let reason):
            return PhotoIndexStatus(state: .failed, indexedCount: indexed, totalCount: total, lastUpdatedAt: last, failureReason: reason)
        case .idle:
            return PhotoIndexStatus(state: last == nil && indexed == 0 ? .notStarted : .ready, indexedCount: indexed, totalCount: total, lastUpdatedAt: last)
        }
    }

    /// Deletes the index and indexes again in the background.
    public func rebuildIndex() async throws {
        await stopIndexing()
        try await store.deleteAll()
        startIndexing()
    }

    /// Stops indexing and deletes every indexed row.
    public func deleteIndex() async throws {
        await stopIndexing()
        try await store.deleteAll()
    }
}
