import Foundation
import ZoroCore

/// Anything that can fetch `GET /v1/models/routes` (`ZoroAPI` does).
public protocol ModelRoutesFetching: Sendable {
    func fetchModelRoutes() async throws -> [ModelRouteInfo]
}

/// Adapts any `ZoroAPI` to `ModelRoutesFetching`.
public struct APIModelRoutesSource: ModelRoutesFetching {
    private let api: any ZoroAPI
    public init(api: any ZoroAPI) { self.api = api }
    public func fetchModelRoutes() async throws -> [ModelRouteInfo] { try await api.modelRoutes() }
}

/// The routes at one moment.
public struct ModelRoutesSnapshot: Sendable, Equatable {
    public var routes: [ModelRouteInfo]
    public var fetchedAt: Date
    /// True when the server could not be reached and this is the last good copy.
    public var isStale: Bool

    public init(routes: [ModelRouteInfo], fetchedAt: Date, isStale: Bool = false) {
        self.routes = routes
        self.fetchedAt = fetchedAt
        self.isStale = isStale
    }

    public func route(for task: TaskClass) -> ModelRouteInfo? { routes.first { $0.task == task } }

    /// Tasks whose active model is outside the owner's machines (shown in privacy screens).
    public var externalTasks: [TaskClass] { routes.filter { $0.locality == .external }.map(\.task) }

    /// Tasks with no active model: ZORO answers these with deterministic behaviour only.
    public var tasksWithoutModel: [TaskClass] { routes.filter { $0.activeModel == nil }.map(\.task) }
}

/// Client for `GET /v1/models/routes`: which model serves each task class, where it runs and why.
/// Keeps the last good answer for a short time and serves it (marked stale) when the server is unreachable.
public actor ModelRoutesClient {
    private let source: any ModelRoutesFetching
    private let clock: @Sendable () -> Date
    private let maxAge: TimeInterval
    private var cached: ModelRoutesSnapshot?
    private var inFlight: Task<[ModelRouteInfo], Error>?

    public init(source: any ModelRoutesFetching, maxAge: TimeInterval = 60, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.maxAge = maxAge
        self.clock = clock
    }

    public init(api: any ZoroAPI, maxAge: TimeInterval = 60, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(source: APIModelRoutesSource(api: api), maxAge: maxAge, clock: clock)
    }

    /// The routes. Fresh when the cache is younger than `maxAge` (or `forceRefresh` is false and it is);
    /// otherwise fetched. On failure the last good copy is returned as stale; with none, the error is thrown.
    public func routes(forceRefresh: Bool = false) async throws -> ModelRoutesSnapshot {
        if !forceRefresh, let cached, clock().timeIntervalSince(cached.fetchedAt) < maxAge, !cached.isStale {
            return cached
        }
        let task: Task<[ModelRouteInfo], Error>
        if let running = inFlight {
            task = running
        } else {
            let source = self.source
            task = Task { try await source.fetchModelRoutes() }
            inFlight = task
        }
        do {
            let routes = try await task.value
            inFlight = nil
            let snapshot = ModelRoutesSnapshot(routes: routes, fetchedAt: clock())
            cached = snapshot
            return snapshot
        } catch {
            inFlight = nil
            if error is CancellationError || Task.isCancelled { throw ZoroError.cancelled }
            if var stale = cached {
                stale.isStale = true
                return stale
            }
            throw ZoroError.wrap(error)
        }
    }

    /// The route for one task, using the cache when it is fresh.
    public func route(for task: TaskClass) async throws -> ModelRouteInfo? {
        try await routes().route(for: task)
    }

    /// Forgets the cached routes (after a privacy mode change, for example).
    public func invalidate() { cached = nil }
}
