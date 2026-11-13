import FitnessFeature
import Foundation
import ZoroCore

/// Indexing seam: `PhotoIntelligenceService` in the app, a fake in tests.
public protocol PhotoIndexing: Sendable {
    func authorizationStatus() async -> MediaAuthorization
    func startIndexing() async
    func stopIndexing() async
}

/// Work that keeps local data fresh, run politely: only when the app comes to the foreground, at most
/// once per interval, never twice at once, and stopped when the app leaves the foreground. Nothing here
/// schedules unbounded background work (the photo index gets one system-scheduled processing task on
/// iPhone, registered by the app target).
public actor ForegroundWork {
    public struct Report: Sendable, Equatable {
        public var fitnessSynced: Bool
        public var photoIndexingStarted: Bool
    }

    public static let fitnessInterval: TimeInterval = 6 * 60 * 60

    private let fitness: (any FitnessSyncing)?
    private let health: any HealthDataProviding
    private let photos: (any PhotoIndexing)?
    private let now: @Sendable () -> Date
    private var lastFitnessSync: Date?
    private var running = false

    public init(
        fitness: (any FitnessSyncing)?, health: any HealthDataProviding, photos: (any PhotoIndexing)?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fitness = fitness
        self.health = health
        self.photos = photos
        self.now = now
    }

    /// Called when the app becomes active and the device is paired.
    @discardableResult
    public func appBecameActive() async -> Report {
        guard !running else { return Report(fitnessSynced: false, photoIndexingStarted: false) }
        running = true
        defer { running = false }
        var report = Report(fitnessSynced: false, photoIndexingStarted: false)
        if let photos {
            let status = await photos.authorizationStatus()
            if status == .authorized || status == .limited {
                await photos.startIndexing()
                report.photoIndexingStarted = true
            }
        }
        if let fitness, await health.authorization() == .requested, isFitnessDue {
            if (try? await fitness.syncNow()) != nil {
                lastFitnessSync = now()
                report.fitnessSynced = true
            }
        }
        return report
    }

    /// Called when the app leaves the foreground.
    public func appMovedToBackground() async {
        await photos?.stopIndexing()
    }

    private var isFitnessDue: Bool {
        guard let lastFitnessSync else { return true }
        return now().timeIntervalSince(lastFitnessSync) >= Self.fitnessInterval
    }
}
