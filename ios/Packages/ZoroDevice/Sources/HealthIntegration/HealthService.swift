import Foundation
import NativeActionBroker
import ZoroCore

/// `HealthDataProviding` over a `HealthSampleStore` (HealthKit in the app, in-memory in tests).
public struct HealthService: HealthDataProviding {
    let store: any HealthSampleStore
    let calendar: Calendar
    let now: @Sendable () -> Date

    public init(store: any HealthSampleStore, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.calendar = calendar
        self.now = now
    }

    private var aggregator: HealthAggregator { HealthAggregator(store: store, calendar: calendar) }

    private func requireAvailable() throws {
        guard store.isHealthDataAvailable() else {
            throw ZoroError.unavailable(capability: "Health", reason: "Health data is not available on this device")
        }
    }

    public func authorization() async -> HealthAuthorization {
        guard store.isHealthDataAvailable() else { return .unavailable }
        return await store.authorizationRequestStatus()
    }

    public func requestAuthorization() async throws {
        try requireAvailable()
        try await store.requestReadAuthorization()
    }

    private static let summaryMetrics: [HealthMetric] = [.steps, .activeEnergy, .exerciseTime, .restingHeartRate, .sleep]

    private func days(in interval: DateInterval) async throws -> [HealthDailySummary] {
        try requireAvailable()
        var series: [HealthMetric: HealthSeries] = [:]
        for m in Self.summaryMetrics {
            series[m] = try? await aggregator.series(m, in: interval, by: .day)
            try Task.checkCancellation()
        }
        let fetched = now()
        return aggregator.buckets(covering: interval, by: .day).enumerated().map { i, slot in
            func v(_ m: HealthMetric) -> Double? {
                guard let p = series[m]?.points, i < p.count else { return nil }
                return p[i].value
            }
            let sources = Set(Self.summaryMetrics.flatMap { m -> [String] in
                guard let p = series[m]?.points, i < p.count else { return [] }
                return p[i].sources
            }).sorted()
            return HealthDailySummary(
                date: slot.start, steps: v(.steps).map { Int($0) }, activeEnergyKcal: v(.activeEnergy),
                exerciseMinutes: v(.exerciseTime), standHours: nil, restingHeartRate: v(.restingHeartRate),
                sleepHours: v(.sleep).map { HealthMath.round1($0 / 60) },
                source: sources.isEmpty ? "Apple Health" : sources.joined(separator: ", "), fetchedAt: fetched)
        }
    }

    public func dailySummary(for day: Date) async throws -> HealthDailySummary {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        guard let summary = try await days(in: DateInterval(start: start, end: end)).first else {
            throw ZoroError.unavailable(capability: "Health", reason: "no data for that day")
        }
        return summary
    }

    public func weeklySummary(weekContaining day: Date) async throws -> HealthWeeklySummary {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: day) else {
            throw ZoroError.unavailable(capability: "Health", reason: "could not work out that week")
        }
        let daily = try await days(in: week)
        let workouts = (try? await store.workouts(in: week, limit: 200)) ?? []
        let sources = Set(daily.map(\.source)).sorted()
        return HealthWeeklySummary(
            weekStart: week.start, days: daily, workouts: workouts.count,
            source: sources.count == 1 ? sources[0] : sources.joined(separator: "; "), fetchedAt: now())
    }

    public func workouts(in interval: DateInterval, limit: Int) async throws -> [WorkoutSummary] {
        try requireAvailable()
        return try await store.workouts(in: interval, limit: max(1, min(limit, 500))).map {
            WorkoutSummary(
                id: $0.id, activityType: $0.activity.rawValue, start: $0.start, end: $0.end,
                energyKcal: $0.activeEnergy?.value(in: .kilocalorie).map(HealthMath.round1),
                distanceMeters: $0.distance?.value(in: .meter).map(HealthMath.round1), source: $0.source)
        }
    }

    public func dataFreshness() async throws -> [HealthDataFreshness] {
        try requireAvailable()
        var out: [HealthDataFreshness] = []
        for m in HealthMetric.allCases {
            out.append(HealthDataFreshness(metric: m.rawValue, lastSampleAt: try? await store.latestSample(m)?.date))
        }
        return out
    }
}

/// `device.health.query`: `metric`, `from`, `to`, `bucket` → `points[]`, `sources[]`, `latest_sample_at`.
public struct HealthQueryHandler: DeviceActionHandler {
    let store: any HealthSampleStore
    let calendar: Calendar

    public init(store: any HealthSampleStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    public var tools: [DeviceToolName] { [.healthQuery] }

    /// ISO-8601 with offset, or a local `yyyy-MM-dd` (start of that day).
    func boundary(_ args: ToolArguments, _ key: String) throws -> Date {
        let raw = try args.requiredString(key, maxLength: 40)
        if let d = ZoroJSON.parseDate(raw) { return d }
        let parts = raw.split(separator: "-")
        if raw.count == 10, parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
           let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
           DeviceTime.day(date, calendar: calendar) == raw {
            return date
        }
        throw DeviceActionError.invalidArgument(key, "must be an ISO-8601 time or a yyyy-MM-dd date")
    }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let metric = try args.requiredEnum("metric", as: HealthMetric.self)
        let from = try boundary(args, "from")
        let toBoundary = try boundary(args, "to")
        // A bare date means the whole of that day.
        let to = args.raw["to"]?.stringValue?.count == 10
            ? (calendar.date(byAdding: .day, value: 1, to: toBoundary) ?? toBoundary) : toBoundary
        guard to > from else { throw DeviceActionError.invalidArgument("to", "must be after from") }
        guard to.timeIntervalSince(from) <= 400 * 86400 else {
            throw DeviceActionError.invalidArgument("to", "must be within 400 days of from")
        }
        let bucket = try args.requiredEnum("bucket", as: HealthBucket.self)
        let store = self.store
        let aggregator = HealthAggregator(store: store, calendar: calendar)
        let tz = calendar.timeZone
        return PreparedDeviceAction(summary: "Read your \(metric.rawValue.replacingOccurrences(of: "_", with: " ")) from Health.") {
            guard store.isHealthDataAvailable() else {
                throw DeviceActionError.unsupported("Health data is not available on this device.")
            }
            if await store.authorizationRequestStatus() == .notDetermined {
                do { try await store.requestReadAuthorization() } catch { throw DeviceActionError.permissionDenied("Health") }
            }
            let series = try await aggregator.series(metric, in: DateInterval(start: from, end: to), by: bucket)
            return [
                "points": .array(series.points.map {
                    .object([
                        "start": .string(DeviceTime.iso($0.start, timeZone: tz)),
                        "value": $0.value.map(JSONValue.number) ?? .null, "unit": .string(series.unit.rawValue),
                    ])
                }),
                "sources": .array(series.sources.map(JSONValue.string)),
                "latest_sample_at": series.latestSampleAt.map { .string(DeviceTime.iso($0, timeZone: tz)) } ?? .null,
            ]
        }
    }
}
