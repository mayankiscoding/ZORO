import Foundation
import LifeSupport
import Observation
import ZoroCore

/// Where a sync stands.
public enum FitnessSyncState: Sendable, Equatable {
    case idle
    case syncing
    case done(FitnessSyncResult)
    case failed(ScreenFailure)

    public var isRunning: Bool { self == .syncing }
}

/// State and actions of the fitness home screen. Every figure comes from the server (which holds what the
/// iPhone synced); this model only loads, groups and words it.
@MainActor @Observable
public final class FitnessViewModel {
    public private(set) var screen: ScreenPhase = .idle
    public private(set) var freshness: FitnessFreshness?
    public private(set) var today: Loadable<DailySummary> = .idle
    public private(set) var weekly: Loadable<WeeklyComparison> = .idle
    public private(set) var trend: Loadable<TrendResult> = .idle
    public private(set) var running: Loadable<RunningProgress> = .idle
    public private(set) var records: Loadable<PersonalRecords> = .idle
    public private(set) var consistency: Loadable<Consistency> = .idle
    /// The last seven days read from Health on this device (steps per day), when Health access was requested.
    public private(set) var thisWeekOnDevice: Loadable<HealthWeeklySummary> = .idle
    public private(set) var healthAuthorization: HealthAuthorization = .notDetermined
    public private(set) var syncState: FitnessSyncState = .idle
    public private(set) var trendMetric: TrendMetric = .steps
    public private(set) var trendDays: Int = 28
    public private(set) var now: Date

    private let server: any FitnessServing
    private let health: any HealthDataProviding
    private let syncer: any FitnessSyncing
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(
        server: any FitnessServing, health: any HealthDataProviding, syncer: any FitnessSyncing,
        timeZone: TimeZone = .current, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.server = server
        self.health = health
        self.syncer = syncer
        self.timeZone = timeZone
        self.clock = clock
        self.now = clock()
    }

    /// Wires the real clients from the injected services.
    public convenience init(services: ZoroServices, timeZone: TimeZone = .current) {
        let server = FitnessAPIClient(api: services.api)
        self.init(
            server: server, health: services.health, syncer: HealthFitnessSync(health: services.health, server: server, timeZone: timeZone),
            timeZone: timeZone)
    }

    // MARK: Derived

    /// Health access can be asked for on iPhone only.
    public var canSyncFromThisDevice: Bool { healthAuthorization != .unavailable }

    /// The sentence under the Sync button.
    public var syncNote: String {
        switch healthAuthorization {
        case .unavailable: "Apple Health is only on iPhone. This screen shows what your iPhone last synced."
        case .notDetermined: "ZORO reads activity and workouts to answer your fitness questions. You choose what to allow."
        case .requested: "Sends daily totals and workouts from Health to your ZORO server. Raw samples stay on this device."
        }
    }

    public var syncButtonTitle: String {
        healthAuthorization == .notDetermined ? "Allow Health and sync" : "Sync now"
    }

    // MARK: Loading

    public func load() async {
        now = clock()
        if screen == .idle || screen.failure != nil { screen = .loading }
        healthAuthorization = await health.authorization()
        let fresh: FitnessFreshness
        do {
            fresh = try await server.freshness()
        } catch {
            screen = .failed(ScreenFailure.from(error, subject: "your fitness figures"))
            return
        }
        freshness = fresh
        if fresh.neverSynced {
            resetSections()
            screen = .empty
            return
        }
        screen = .loaded
        trend = .loading
        async let t: Void = loadToday()
        async let w: Void = loadWeekly()
        async let r: Void = loadRunning()
        async let p: Void = loadRecords()
        async let c: Void = loadConsistency()
        async let tr: Void = loadTrend()
        async let d: Void = loadOnDeviceWeek()
        _ = await (t, w, r, p, c, tr, d)
        now = clock()
    }

    public func selectTrend(metric: TrendMetric? = nil, days: Int? = nil) async {
        if let metric { trendMetric = metric }
        if let days { trendDays = min(max(days, 7), 180) }
        await loadTrend()
    }

    private func resetSections() {
        today = .idle; weekly = .idle; trend = .idle; running = .idle; records = .idle; consistency = .idle; thisWeekOnDevice = .idle
    }

    private func loadToday() async {
        today = .loading
        do { today = .loaded(try await server.summary(date: nil, timeZone: timeZone)) } catch { today = .failed(ScreenFailure.from(error, subject: "today's figures")) }
    }

    private func loadWeekly() async {
        weekly = .loading
        do { weekly = .loaded(try await server.weekly(timeZone: timeZone)) } catch { weekly = .failed(ScreenFailure.from(error, subject: "the weekly comparison")) }
    }

    private func loadTrend() async {
        trend = .loading
        do {
            trend = .loaded(try await server.trend(metric: trendMetric.rawValue, days: trendDays, timeZone: timeZone))
        } catch {
            trend = .failed(ScreenFailure.from(error, subject: "the trend"))
        }
    }

    private func loadRunning() async {
        running = .loading
        do { running = .loaded(try await server.running(days: 90, timeZone: timeZone)) } catch { running = .failed(ScreenFailure.from(error, subject: "your running progress")) }
    }

    private func loadRecords() async {
        records = .loading
        do { records = .loaded(try await server.records()) } catch { records = .failed(ScreenFailure.from(error, subject: "your personal records")) }
    }

    private func loadConsistency() async {
        consistency = .loading
        do { consistency = .loaded(try await server.consistency(weeks: 8, timeZone: timeZone)) } catch { consistency = .failed(ScreenFailure.from(error, subject: "your consistency")) }
    }

    private func loadOnDeviceWeek() async {
        guard healthAuthorization == .requested else {
            thisWeekOnDevice = .idle
            return
        }
        thisWeekOnDevice = .loading
        do {
            thisWeekOnDevice = .loaded(try await health.weeklySummary(weekContaining: clock()))
        } catch {
            thisWeekOnDevice = .failed(ScreenFailure.from(error, subject: "this week from Health"))
        }
    }

    // MARK: Health and sync

    /// Shows the system Health sheet. HealthKit never says whether read access was granted, so a successful
    /// request moves the state to `requested`, and the sync shows what it found.
    public func requestHealthAccess() async {
        do {
            try await health.requestAuthorization()
        } catch {
            syncState = .failed(ScreenFailure.from(error, subject: "Health access"))
        }
        healthAuthorization = await health.authorization()
    }

    public func syncNow() async {
        guard !syncState.isRunning, canSyncFromThisDevice else { return }
        syncState = .syncing
        if healthAuthorization == .notDetermined {
            await requestHealthAccess()
            if case .failed = syncState { return }
            guard healthAuthorization == .requested else {
                syncState = .failed(ScreenFailure(kind: .error, message: "Health access was not allowed. Turn it on in the Health app under Sharing, then tap Sync now."))
                return
            }
        }
        do {
            let result = try await syncer.syncNow()
            syncState = .done(result)
            await load()
        } catch {
            syncState = .failed(ScreenFailure.from(error, subject: "your Health data"))
        }
    }
}
