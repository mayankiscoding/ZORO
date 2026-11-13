import Foundation
import ZoroCore

/// The read-only HealthKit data ZORO uses (fitness information only).
/// Raw values are the `metric` names of `device.health.query`.
public enum HealthMetric: String, CaseIterable, Sendable {
    case steps
    case walkingRunningDistance = "walking_running_distance"
    case cyclingDistance = "cycling_distance"
    case activeEnergy = "active_energy"
    case exerciseTime = "exercise_minutes"
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case sleep
    case bodyMass = "body_mass"

    /// The unit the contract reports this metric in.
    public var contractUnit: HealthUnit {
        switch self {
        case .steps: .count
        case .walkingRunningDistance, .cyclingDistance: .meter
        case .activeEnergy: .kilocalorie
        case .exerciseTime, .sleep: .minute
        case .heartRate, .restingHeartRate: .beatsPerMinute
        case .bodyMass: .kilogram
        }
    }

    /// Summed per bucket (true) or averaged (false).
    public var isCumulative: Bool {
        switch self {
        case .steps, .walkingRunningDistance, .cyclingDistance, .activeEnergy, .exerciseTime, .sleep: true
        case .heartRate, .restingHeartRate, .bodyMass: false
        }
    }
}

public enum HealthUnit: String, Sendable, CaseIterable {
    case count
    case meter = "m", kilometer = "km", mile = "mi"
    case kilocalorie = "kcal", kilojoule = "kJ"
    case second = "s", minute = "min", hour = "h"
    case beatsPerMinute = "bpm"
    case kilogram = "kg", pound = "lb"

    private enum Dimension { case count, length, energy, time, rate, mass }

    /// (dimension, factor to the dimension's base unit).
    private var base: (Dimension, Double) {
        switch self {
        case .count: (.count, 1)
        case .meter: (.length, 1)
        case .kilometer: (.length, 1000)
        case .mile: (.length, 1609.344)
        case .kilocalorie: (.energy, 1)
        case .kilojoule: (.energy, 1 / 4.184)
        case .second: (.time, 1.0 / 60)
        case .minute: (.time, 1)
        case .hour: (.time, 60)
        case .beatsPerMinute: (.rate, 1)
        case .kilogram: (.mass, 1)
        case .pound: (.mass, 0.45359237)
        }
    }

    /// Converts between units of the same dimension; nil for incompatible units.
    public static func convert(_ value: Double, from: HealthUnit, to: HealthUnit) -> Double? {
        let (fd, ff) = from.base
        let (td, tf) = to.base
        guard fd == td else { return nil }
        return value * ff / tf
    }
}

public struct HealthQuantity: Sendable, Equatable {
    public var value: Double
    public var unit: HealthUnit
    public init(_ value: Double, _ unit: HealthUnit) {
        self.value = value
        self.unit = unit
    }
    public func value(in target: HealthUnit) -> Double? { HealthUnit.convert(value, from: unit, to: target) }
}

public enum HealthBucket: String, Sendable, CaseIterable { case day, week }

/// One statistics bucket from the store (nil quantity = no samples, never zero-filled).
public struct HealthStatisticsBucket: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var quantity: HealthQuantity?
    public var sources: [String]
    public init(start: Date, end: Date, quantity: HealthQuantity?, sources: [String]) {
        self.start = start
        self.end = end
        self.quantity = quantity
        self.sources = sources
    }
}

/// An asleep interval (any asleep stage; in-bed and awake samples are excluded by the store).
public struct HealthSleepSample: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var source: String
    public init(start: Date, end: Date, source: String) {
        self.start = start
        self.end = end
        self.source = source
    }
}

public enum WorkoutActivity: String, Sendable, CaseIterable {
    case running, walking, cycling, strength, yoga, swimming, other
}

public struct HealthWorkoutRecord: Sendable, Equatable {
    public var id: String
    public var activity: WorkoutActivity
    public var start: Date
    public var end: Date
    public var distance: HealthQuantity?
    public var activeEnergy: HealthQuantity?
    public var averageHeartRate: HealthQuantity?
    public var source: String
    public init(
        id: String, activity: WorkoutActivity, start: Date, end: Date, distance: HealthQuantity?,
        activeEnergy: HealthQuantity?, averageHeartRate: HealthQuantity?, source: String
    ) {
        self.id = id
        self.activity = activity
        self.start = start
        self.end = end
        self.distance = distance
        self.activeEnergy = activeEnergy
        self.averageHeartRate = averageHeartRate
        self.source = source
    }
}

public struct HealthLatestSample: Sendable, Equatable {
    public var date: Date
    public var source: String
    public init(date: Date, source: String) {
        self.date = date
        self.source = source
    }
}

/// HealthKit behind a protocol; everything above it is tested with an in-memory store.
public protocol HealthSampleStore: Sendable {
    func isHealthDataAvailable() -> Bool
    /// `.requested` once the read sheet has been shown (HealthKit never reveals read grants).
    func authorizationRequestStatus() async -> HealthAuthorization
    func requestReadAuthorization() async throws
    /// Buckets aligned to `calendar` (day = local midnight, week = the calendar's first weekday). Not for `.sleep`.
    func statistics(_ metric: HealthMetric, in interval: DateInterval, bucket: HealthBucket, calendar: Calendar) async throws
        -> [HealthStatisticsBucket]
    func sleepSamples(in interval: DateInterval) async throws -> [HealthSleepSample]
    /// Newest first.
    func workouts(in interval: DateInterval, limit: Int) async throws -> [HealthWorkoutRecord]
    func latestSample(_ metric: HealthMetric) async throws -> HealthLatestSample?
}

/// Arithmetic helpers with the contract's rounding.
public enum HealthMath {
    /// Seconds per kilometre, rounded to 0.1; nil without a usable distance (under 50 m) or duration.
    public static func paceSecondsPerKm(durationSeconds: Double, distanceMeters: Double?) -> Double? {
        guard let d = distanceMeters, d >= 50, durationSeconds > 0 else { return nil }
        return round1(durationSeconds / (d / 1000))
    }

    public static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    /// The value in the metric's contract unit, rounded the way the contract shows it.
    public static func contractValue(_ q: HealthQuantity, for metric: HealthMetric) -> Double? {
        guard let v = q.value(in: metric.contractUnit), v.isFinite else { return nil }
        switch metric {
        case .steps, .exerciseTime, .sleep, .heartRate, .restingHeartRate: return v.rounded()
        case .bodyMass: return (v * 100).rounded() / 100
        default: return round1(v)
        }
    }
}
