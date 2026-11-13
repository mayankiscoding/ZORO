import Foundation
import ZoroCore

public struct HealthSeriesPoint: Sendable, Equatable {
    public var start: Date
    public var end: Date
    /// In the metric's contract unit; nil when there were no samples (never estimated).
    public var value: Double?
    /// Sources that contributed to this bucket.
    public var sources: [String]
}

public struct HealthSeries: Sendable, Equatable {
    public var metric: HealthMetric
    public var points: [HealthSeriesPoint]
    public var sources: [String]
    public var latestSampleAt: Date?
    public var unit: HealthUnit { metric.contractUnit }
}

/// Turns store buckets and samples into contract-unit series.
public struct HealthAggregator: Sendable {
    let store: any HealthSampleStore
    let calendar: Calendar

    public init(store: any HealthSampleStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    /// Calendar-aligned buckets covering `interval` (days start at local midnight, weeks at the first weekday).
    public func buckets(covering interval: DateInterval, by bucket: HealthBucket) -> [DateInterval] {
        let first: Date
        switch bucket {
        case .day: first = calendar.startOfDay(for: interval.start)
        case .week: first = calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start ?? calendar.startOfDay(for: interval.start)
        }
        var out: [DateInterval] = []
        var start = first
        while start < interval.end, out.count < 1000 {
            let next = calendar.date(byAdding: bucket == .day ? .day : .weekOfYear, value: 1, to: start) ?? start.addingTimeInterval(86400)
            out.append(DateInterval(start: start, end: next))
            start = next
        }
        return out
    }

    public func series(_ metric: HealthMetric, in interval: DateInterval, by bucket: HealthBucket) async throws -> HealthSeries {
        let slots = buckets(covering: interval, by: bucket)
        guard let first = slots.first, let last = slots.last else {
            return HealthSeries(metric: metric, points: [], sources: [], latestSampleAt: nil)
        }
        let span = DateInterval(start: first.start, end: last.end)
        var points: [HealthSeriesPoint] = []
        var sources = Set<String>()
        if metric == .sleep {
            // Nights started up to 12 h before the first bucket still count towards the day they end.
            let samples = try await store.sleepSamples(in: DateInterval(start: span.start.addingTimeInterval(-12 * 3600), end: span.end))
            let minutes = SleepAggregator.minutes(samples, buckets: slots)
            points = zip(slots, minutes).map { slot, value in
                let contributing = value == nil ? [] : samples.filter { $0.start < slot.end && $0.end > slot.start }.map(\.source)
                sources.formUnion(contributing)
                return HealthSeriesPoint(start: slot.start, end: slot.end, value: value, sources: Set(contributing).sorted())
            }
        } else {
            let stats = try await store.statistics(metric, in: span, bucket: bucket, calendar: calendar)
            for slot in slots {
                let match = stats.first { abs($0.start.timeIntervalSince(slot.start)) < 1 }
                let value = match?.quantity.flatMap { HealthMath.contractValue($0, for: metric) }
                let pointSources = value == nil ? [] : (match?.sources ?? [])
                sources.formUnion(pointSources)
                points.append(HealthSeriesPoint(start: slot.start, end: slot.end, value: value, sources: pointSources.sorted()))
            }
        }
        let latest = try await store.latestSample(metric)
        return HealthSeries(metric: metric, points: points, sources: sources.sorted(), latestSampleAt: latest?.date)
    }
}

/// Sleep minutes per bucket from possibly overlapping samples of several sources.
public enum SleepAggregator {
    /// Gaps shorter than this join two asleep stretches into one night.
    static let sessionGap: TimeInterval = 2 * 3600

    /// Overlaps between sources are counted once; each night (asleep stretches separated by less than
    /// 2 h) is credited to the bucket in which it ends. nil = no sleep recorded in that bucket.
    public static func minutes(_ samples: [HealthSleepSample], buckets: [DateInterval]) -> [Double?] {
        let sorted = samples.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for s in sorted {
            if let last = merged.last, s.start <= last.end {
                merged[merged.count - 1].end = max(last.end, s.end)
            } else {
                merged.append((s.start, s.end))
            }
        }
        var sessions: [(end: Date, seconds: TimeInterval)] = []
        var previousEnd: Date?
        for m in merged {
            let seconds = m.end.timeIntervalSince(m.start)
            if let p = previousEnd, m.start.timeIntervalSince(p) < sessionGap, !sessions.isEmpty {
                sessions[sessions.count - 1].end = m.end
                sessions[sessions.count - 1].seconds += seconds
            } else {
                sessions.append((m.end, seconds))
            }
            previousEnd = m.end
        }
        var totals = [Double?](repeating: nil, count: buckets.count)
        for session in sessions {
            guard let i = buckets.firstIndex(where: { $0.start <= session.end && session.end < $0.end }) else { continue }
            totals[i] = (totals[i] ?? 0) + session.seconds / 60
        }
        return totals.map { $0.map { $0.rounded() } }
    }
}
