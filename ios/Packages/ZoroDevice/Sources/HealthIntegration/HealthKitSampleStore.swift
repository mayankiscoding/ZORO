#if canImport(HealthKit)
import Foundation
import HealthKit
import ZoroCore

/// `HealthSampleStore` over HealthKit, read-only. Compiles on macOS, where
/// `HKHealthStore.isHealthDataAvailable()` is false and every caller answers "unavailable".
public struct HealthKitSampleStore: HealthSampleStore {
    private let store: HKHealthStore

    public init() { store = HKHealthStore() }

    static func quantityType(_ metric: HealthMetric) -> (HKQuantityType, HKUnit)? {
        switch metric {
        case .steps: (HKQuantityType(.stepCount), .count())
        case .walkingRunningDistance: (HKQuantityType(.distanceWalkingRunning), .meter())
        case .cyclingDistance: (HKQuantityType(.distanceCycling), .meter())
        case .activeEnergy: (HKQuantityType(.activeEnergyBurned), .kilocalorie())
        case .exerciseTime: (HKQuantityType(.appleExerciseTime), .minute())
        case .heartRate: (HKQuantityType(.heartRate), HKUnit.count().unitDivided(by: .minute()))
        case .restingHeartRate: (HKQuantityType(.restingHeartRate), HKUnit.count().unitDivided(by: .minute()))
        case .bodyMass: (HKQuantityType(.bodyMass), .gramUnit(with: .kilo))
        case .sleep: nil
        }
    }

    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis), HKObjectType.workoutType()]
        for m in HealthMetric.allCases { if let (t, _) = quantityType(m) { types.insert(t) } }
        types.insert(HKQuantityType(.distanceSwimming))
        return types
    }

    /// Sort descriptors built from HealthKit's sort keys (avoids non-Sendable key-path literals).
    private static func sort<T: NSObject>(_ key: String, ascending: Bool, _ type: T.Type) -> [SortDescriptor<T>] {
        SortDescriptor(NSSortDescriptor(key: key, ascending: ascending), comparing: type).map { [$0] } ?? []
    }

    public func isHealthDataAvailable() -> Bool { HKHealthStore.isHealthDataAvailable() }

    public func authorizationRequestStatus() async -> HealthAuthorization {
        guard isHealthDataAvailable() else { return .unavailable }
        do {
            switch try await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes) {
            case .unnecessary: return .requested
            default: return .notDetermined
            }
        } catch {
            return .notDetermined
        }
    }

    public func requestReadAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    public func statistics(_ metric: HealthMetric, in interval: DateInterval, bucket: HealthBucket, calendar: Calendar) async throws
        -> [HealthStatisticsBucket]
    {
        guard let (type, unit) = Self.quantityType(metric) else { return [] }
        var components = DateComponents()
        if bucket == .day { components.day = 1 } else { components.weekOfYear = 1 }
        let anchor = bucket == .day
            ? calendar.startOfDay(for: interval.start)
            : (calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start ?? interval.start)
        let options: HKStatisticsOptions = metric.isCumulative ? [.cumulativeSum, .separateBySource] : [.discreteAverage, .separateBySource]
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate), options: options, anchorDate: anchor,
            intervalComponents: components)
        let collection = try await descriptor.result(for: store)
        var out: [HealthStatisticsBucket] = []
        collection.enumerateStatistics(from: interval.start, to: interval.end) { stats, _ in
            let q = metric.isCumulative ? stats.sumQuantity() : stats.averageQuantity()
            out.append(
                HealthStatisticsBucket(
                    start: stats.startDate, end: stats.endDate,
                    quantity: q.map { HealthQuantity($0.doubleValue(for: unit), metric.contractUnit) },
                    sources: (stats.sources ?? []).map(\.name)))
        }
        return out
    }

    public func sleepSamples(in interval: DateInterval) async throws -> [HealthSleepSample] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: Self.sort(HKSampleSortIdentifierStartDate, ascending: true, HKCategorySample.self), limit: 5000)
        let asleep = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        return try await descriptor.result(for: store)
            .filter { asleep.contains($0.value) }
            .map { HealthSleepSample(start: $0.startDate, end: $0.endDate, source: $0.sourceRevision.source.name) }
    }

    static func activity(_ type: HKWorkoutActivityType) -> WorkoutActivity {
        switch type {
        case .running: .running
        case .walking, .hiking: .walking
        case .cycling, .handCycling: .cycling
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining: .strength
        case .yoga: .yoga
        case .swimming: .swimming
        default: .other
        }
    }

    public func workouts(in interval: DateInterval, limit: Int) async throws -> [HealthWorkoutRecord] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)], sortDescriptors: Self.sort(HKSampleSortIdentifierStartDate, ascending: false, HKWorkout.self), limit: limit)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return try await descriptor.result(for: store).map { w in
            let activity = Self.activity(w.workoutActivityType)
            let distanceType: HKQuantityType? = switch activity {
            case .running, .walking: HKQuantityType(.distanceWalkingRunning)
            case .cycling: HKQuantityType(.distanceCycling)
            case .swimming: HKQuantityType(.distanceSwimming)
            default: nil
            }
            let distance = distanceType.flatMap { w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
            let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            let hr = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: bpm)
            return HealthWorkoutRecord(
                id: w.uuid.uuidString.lowercased(), activity: activity, start: w.startDate, end: w.endDate,
                distance: distance.map { HealthQuantity($0, .meter) }, activeEnergy: energy.map { HealthQuantity($0, .kilocalorie) },
                averageHeartRate: hr.map { HealthQuantity($0, .beatsPerMinute) }, source: w.sourceRevision.source.name)
        }
    }

    public func latestSample(_ metric: HealthMetric) async throws -> HealthLatestSample? {
        if let (type, _) = Self.quantityType(metric) {
            let d = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: type)], sortDescriptors: Self.sort(HKSampleSortIdentifierEndDate, ascending: false, HKQuantitySample.self),
                limit: 1)
            return try await d.result(for: store).first.map { HealthLatestSample(date: $0.endDate, source: $0.sourceRevision.source.name) }
        }
        let d = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis))],
            sortDescriptors: Self.sort(HKSampleSortIdentifierEndDate, ascending: false, HKCategorySample.self), limit: 1)
        return try await d.result(for: store).first.map { HealthLatestSample(date: $0.endDate, source: $0.sourceRevision.source.name) }
    }
}
#endif
