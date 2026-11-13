import Foundation
import NativeActionBroker
import ZoroCore

/// `POST /v1/fitness/sync` body, exactly per `device-contract.md`. Every optional value is encoded as
/// JSON `null` (not omitted) when HealthKit had nothing: not granted or not recorded, never estimated.
public struct FitnessSyncPayload: Codable, Sendable, Equatable {
    public var generatedAt: String
    public var days: [Day]
    public var workouts: [Workout]

    public struct Day: Codable, Sendable, Equatable {
        public var date: String
        public var steps: Int?
        public var walkingRunningDistanceM: Double?
        public var cyclingDistanceM: Double?
        public var activeEnergyKcal: Double?
        public var exerciseMinutes: Int?
        public var restingHeartRateBpm: Int?
        public var avgHeartRateBpm: Int?
        public var sleepMinutes: Int?
        public var bodyMassKg: Double?
        public var sources: [String]

        enum CodingKeys: String, CodingKey {
            case date, steps, sources
            case walkingRunningDistanceM = "walking_running_distance_m"
            case cyclingDistanceM = "cycling_distance_m"
            case activeEnergyKcal = "active_energy_kcal"
            case exerciseMinutes = "exercise_minutes"
            case restingHeartRateBpm = "resting_heart_rate_bpm"
            case avgHeartRateBpm = "avg_heart_rate_bpm"
            case sleepMinutes = "sleep_minutes"
            case bodyMassKg = "body_mass_kg"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date)
            try c.encode(steps, forKey: .steps)
            try c.encode(walkingRunningDistanceM, forKey: .walkingRunningDistanceM)
            try c.encode(cyclingDistanceM, forKey: .cyclingDistanceM)
            try c.encode(activeEnergyKcal, forKey: .activeEnergyKcal)
            try c.encode(exerciseMinutes, forKey: .exerciseMinutes)
            try c.encode(restingHeartRateBpm, forKey: .restingHeartRateBpm)
            try c.encode(avgHeartRateBpm, forKey: .avgHeartRateBpm)
            try c.encode(sleepMinutes, forKey: .sleepMinutes)
            try c.encode(bodyMassKg, forKey: .bodyMassKg)
            try c.encode(sources, forKey: .sources)
        }
    }

    public struct Workout: Codable, Sendable, Equatable {
        public var id: String
        public var type: String
        public var startAt: String
        public var endAt: String
        public var durationS: Int
        public var distanceM: Double?
        public var activeEnergyKcal: Double?
        public var avgHeartRateBpm: Int?
        public var avgPaceSPerKm: Double?
        public var source: String

        enum CodingKeys: String, CodingKey {
            case id, type, source
            case startAt = "start_at"
            case endAt = "end_at"
            case durationS = "duration_s"
            case distanceM = "distance_m"
            case activeEnergyKcal = "active_energy_kcal"
            case avgHeartRateBpm = "avg_heart_rate_bpm"
            case avgPaceSPerKm = "avg_pace_s_per_km"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(type, forKey: .type)
            try c.encode(startAt, forKey: .startAt)
            try c.encode(endAt, forKey: .endAt)
            try c.encode(durationS, forKey: .durationS)
            try c.encode(distanceM, forKey: .distanceM)
            try c.encode(activeEnergyKcal, forKey: .activeEnergyKcal)
            try c.encode(avgHeartRateBpm, forKey: .avgHeartRateBpm)
            try c.encode(avgPaceSPerKm, forKey: .avgPaceSPerKm)
            try c.encode(source, forKey: .source)
        }
    }

    enum CodingKeys: String, CodingKey {
        case days, workouts
        case generatedAt = "generated_at"
    }
}

/// Builds the sync payload from HealthKit aggregates. Raw samples stay on the device.
public struct FitnessSyncBuilder: Sendable {
    let store: any HealthSampleStore
    let calendar: Calendar
    let now: @Sendable () -> Date

    public init(store: any HealthSampleStore, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.calendar = calendar
        self.now = now
    }

    /// The last `days` local days including today, and the workouts that started in them.
    public func build(days: Int = 7, workoutLimit: Int = 100) async throws -> FitnessSyncPayload {
        guard store.isHealthDataAvailable() else {
            throw ZoroError.unavailable(capability: "Health", reason: "Health data is not available on this device")
        }
        let generated = now()
        let today = calendar.startOfDay(for: generated)
        let first = calendar.date(byAdding: .day, value: -(max(1, min(days, 90)) - 1), to: today) ?? today
        let interval = DateInterval(start: first, end: max(generated, first.addingTimeInterval(1)))
        let aggregator = HealthAggregator(store: store, calendar: calendar)

        var series: [HealthMetric: HealthSeries] = [:]
        for metric in HealthMetric.allCases {
            try Task.checkCancellation()
            // A metric the owner did not grant reads as no data; it must not fail the whole sync.
            do { series[metric] = try await aggregator.series(metric, in: interval, by: .day) } catch is CancellationError {
                throw CancellationError()
            } catch {
                series[metric] = nil
            }
        }
        let slots = aggregator.buckets(covering: interval, by: .day)
        let tz = calendar.timeZone
        let dayRows: [FitnessSyncPayload.Day] = slots.enumerated().map { index, slot in
            func value(_ m: HealthMetric) -> Double? {
                guard let points = series[m]?.points, index < points.count else { return nil }
                return points[index].value
            }
            func int(_ m: HealthMetric) -> Int? { value(m).map { Int($0.rounded()) } }
            let sources = Set(HealthMetric.allCases.flatMap { m -> [String] in
                guard let points = series[m]?.points, index < points.count else { return [] }
                return points[index].sources
            })
            return FitnessSyncPayload.Day(
                date: DeviceTime.day(slot.start, calendar: calendar), steps: int(.steps),
                walkingRunningDistanceM: value(.walkingRunningDistance), cyclingDistanceM: value(.cyclingDistance),
                activeEnergyKcal: value(.activeEnergy), exerciseMinutes: int(.exerciseTime),
                restingHeartRateBpm: int(.restingHeartRate), avgHeartRateBpm: int(.heartRate), sleepMinutes: int(.sleep),
                bodyMassKg: value(.bodyMass), sources: sources.sorted())
        }

        let records: [HealthWorkoutRecord]
        do { records = try await store.workouts(in: interval, limit: workoutLimit) } catch is CancellationError {
            throw CancellationError()
        } catch {
            records = []
        }
        let workouts = records.map { Self.workout($0, timeZone: tz) }
        return FitnessSyncPayload(generatedAt: DeviceTime.iso(generated, timeZone: tz), days: dayRows, workouts: workouts)
    }

    public static func workout(_ r: HealthWorkoutRecord, timeZone: TimeZone) -> FitnessSyncPayload.Workout {
        let duration = max(0, r.end.timeIntervalSince(r.start))
        let distance = r.distance?.value(in: .meter)
        return FitnessSyncPayload.Workout(
            id: r.id.hasPrefix("hk-") ? r.id : "hk-" + r.id, type: r.activity.rawValue,
            startAt: DeviceTime.iso(r.start, timeZone: timeZone), endAt: DeviceTime.iso(r.end, timeZone: timeZone),
            durationS: Int(duration.rounded()), distanceM: distance.map(HealthMath.round1),
            activeEnergyKcal: r.activeEnergy?.value(in: .kilocalorie).map(HealthMath.round1),
            avgHeartRateBpm: r.averageHeartRate?.value(in: .beatsPerMinute).map { Int($0.rounded()) },
            avgPaceSPerKm: HealthMath.paceSecondsPerKm(durationSeconds: duration, distanceMeters: distance),
            source: r.source)
    }
}

/// Posts the payload to the owner's server.
public struct FitnessSyncUploader: Sendable {
    let api: any ZoroAPI
    let builder: FitnessSyncBuilder
    public init(api: any ZoroAPI, builder: FitnessSyncBuilder) {
        self.api = api
        self.builder = builder
    }

    @discardableResult
    public func sync(days: Int = 7) async throws -> FitnessSyncPayload {
        let payload = try await builder.build(days: days)
        try await api.send(try APIRequest.json(.post, "/v1/fitness/sync", body: payload))
        return payload
    }
}
