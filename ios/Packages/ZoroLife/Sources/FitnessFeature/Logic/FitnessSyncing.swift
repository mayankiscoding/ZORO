import Foundation
import ZoroCore

/// Reads Health on this device and sends daily aggregates and workouts to the server. The real one is
/// `HealthFitnessSync`; tests and previews use fakes. Never sends raw samples.
public protocol FitnessSyncing: Sendable {
    func syncNow() async throws -> FitnessSyncResult
}

/// Builds the sync payload from `HealthDataProviding` and posts it through `FitnessServing`.
/// Only readings the device returned are sent; every other field stays null (nothing is estimated).
public struct HealthFitnessSync: FitnessSyncing {
    public let health: any HealthDataProviding
    public let server: any FitnessServing
    public let days: Int
    public let timeZone: TimeZone
    public let clock: @Sendable () -> Date

    public init(
        health: any HealthDataProviding, server: any FitnessServing, days: Int = 14, timeZone: TimeZone = .current,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.health = health
        self.server = server
        self.days = max(1, min(days, 400))
        self.timeZone = timeZone
        self.clock = clock
    }

    public func syncNow() async throws -> FitnessSyncResult {
        switch await health.authorization() {
        case .unavailable:
            throw ZoroError.unavailable(capability: "Apple Health", reason: "Health data is only available on an iPhone")
        case .notDetermined:
            throw ZoroError.unavailable(capability: "Apple Health", reason: "Health access has not been allowed yet")
        case .requested:
            break
        }
        let now = clock()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        var syncDays: [SyncDay] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let summary = try await health.dailySummary(for: day)
            if let mapped = Self.syncDay(summary, on: CalendarDate(date: day, timeZone: timeZone)) { syncDays.append(mapped) }
        }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let workouts = try await health.workouts(in: DateInterval(start: start, end: max(now, start)), limit: 500)
        let payload = FitnessSyncPayload(
            generatedAt: now, days: syncDays.reversed(), workouts: workouts.map(Self.syncWorkout))
        return try await server.sync(payload)
    }

    /// nil when the device recorded nothing that day (an empty day is not sent as a row of nulls).
    static func syncDay(_ s: HealthDailySummary, on date: CalendarDate) -> SyncDay? {
        let day = SyncDay(
            date: date, steps: s.steps.map(Double.init), activeEnergyKcal: s.activeEnergyKcal, exerciseMinutes: s.exerciseMinutes,
            restingHeartRateBpm: s.restingHeartRate, sleepMinutes: s.sleepHours.map { $0 * 60 }, sources: s.source.isEmpty ? [] : [s.source])
        let hasReading = day.steps != nil || day.activeEnergyKcal != nil || day.exerciseMinutes != nil
            || day.restingHeartRateBpm != nil || day.sleepMinutes != nil
        return hasReading ? day : nil
    }

    static func syncWorkout(_ w: WorkoutSummary) -> SyncWorkout {
        let type = workoutType(w.activityType)
        let duration = w.durationSeconds
        var pace: Double?
        if (type == "running" || type == "walking"), let meters = w.distanceMeters, meters > 0, duration > 0 {
            let value = duration / (meters / 1000)
            pace = value > 0 && value <= 7200 ? value : nil
        }
        return SyncWorkout(
            id: w.id, type: type, startAt: w.start, endAt: w.end, durationS: duration, distanceM: w.distanceMeters,
            activeEnergyKcal: w.energyKcal, avgPaceSPerKm: pace, source: w.source.isEmpty ? nil : w.source)
    }

    /// Maps an activity name to the contract's seven workout types; anything else is `other`.
    static func workoutType(_ name: String) -> String {
        let n = name.lowercased().filter(\.isLetter)
        if n.contains("run") { return "running" }
        if n.contains("walk") { return "walking" }
        if n.contains("cycl") || n.contains("bik") { return "cycling" }
        if n.contains("strength") { return "strength" }
        if n.contains("yoga") { return "yoga" }
        if n.contains("swim") { return "swimming" }
        return "other"
    }
}
