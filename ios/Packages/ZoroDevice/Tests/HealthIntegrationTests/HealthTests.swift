import Foundation
import Testing
@testable import HealthIntegration
import NativeActionBroker
import ZoroCore

let ist = TimeZone(identifier: "Asia/Kolkata")!
var istCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = ist
    c.firstWeekday = 2  // Monday
    return c
}

func at(_ s: String) -> Date { ZoroJSON.parseDate(s)! }

/// In-memory HealthKit stand-in. Quantities are kept in deliberately non-contract units (km, kJ, s, lb)
/// so the conversions are exercised.
actor FakeHealthStore: HealthSampleStore {
    struct Sample { var metric: HealthMetric; var date: Date; var value: Double; var source: String }
    nonisolated let available: Bool
    var samples: [Sample] = []
    var sleep: [HealthSleepSample] = []
    var workoutRecords: [HealthWorkoutRecord] = []
    var requestStatus: HealthAuthorization = .requested
    var authorizationRequests = 0
    var failing: Set<HealthMetric> = []

    init(available: Bool = true) { self.available = available }

    static func unit(_ m: HealthMetric) -> HealthUnit {
        switch m {
        case .walkingRunningDistance, .cyclingDistance: .kilometer
        case .activeEnergy: .kilojoule
        case .exerciseTime: .second
        case .bodyMass: .pound
        default: m.contractUnit
        }
    }

    func add(_ m: HealthMetric, _ date: String, _ value: Double, _ source: String = "Apple Watch") {
        samples.append(Sample(metric: m, date: at(date), value: value, source: source))
    }
    func addSleep(_ from: String, _ to: String, _ source: String = "Apple Watch") {
        sleep.append(HealthSleepSample(start: at(from), end: at(to), source: source))
    }
    func addWorkout(_ w: HealthWorkoutRecord) { workoutRecords.append(w) }
    func setStatus(_ s: HealthAuthorization) { requestStatus = s }
    func fail(_ m: HealthMetric) { failing.insert(m) }

    nonisolated func isHealthDataAvailable() -> Bool { available }
    func authorizationRequestStatus() async -> HealthAuthorization { requestStatus }
    func requestReadAuthorization() async throws {
        authorizationRequests += 1
        requestStatus = .requested
    }

    func statistics(_ metric: HealthMetric, in interval: DateInterval, bucket: HealthBucket, calendar: Calendar) async throws
        -> [HealthStatisticsBucket]
    {
        if failing.contains(metric) { throw ZoroError.unavailable(capability: "Health", reason: "not authorised") }
        var groups: [Date: [Sample]] = [:]
        for s in samples where s.metric == metric && interval.contains(s.date) {
            let key = bucket == .day ? calendar.startOfDay(for: s.date) : calendar.dateInterval(of: .weekOfYear, for: s.date)!.start
            groups[key, default: []].append(s)
        }
        return groups.keys.sorted().map { start in
            let g = groups[start]!
            let total = g.map(\.value).reduce(0, +)
            let value = metric.isCumulative ? total : total / Double(g.count)
            return HealthStatisticsBucket(
                start: start, end: start.addingTimeInterval(bucket == .day ? 86400 : 7 * 86400),
                quantity: HealthQuantity(value, Self.unit(metric)), sources: Array(Set(g.map(\.source))).sorted())
        }
    }

    func sleepSamples(in interval: DateInterval) async throws -> [HealthSleepSample] {
        sleep.filter { $0.end > interval.start && $0.start < interval.end }
    }

    func workouts(in interval: DateInterval, limit: Int) async throws -> [HealthWorkoutRecord] {
        Array(workoutRecords.filter { interval.contains($0.start) }.sorted { $0.start > $1.start }.prefix(limit))
    }

    func latestSample(_ metric: HealthMetric) async throws -> HealthLatestSample? {
        if metric == .sleep { return sleep.max { $0.end < $1.end }.map { HealthLatestSample(date: $0.end, source: $0.source) } }
        return samples.filter { $0.metric == metric }.max { $0.date < $1.date }.map { HealthLatestSample(date: $0.date, source: $0.source) }
    }
}

func seededStore() async -> FakeHealthStore {
    let s = FakeHealthStore()
    await s.add(.steps, "2026-11-12T09:00:00+05:30", 5000, "iPhone")
    await s.add(.steps, "2026-11-12T18:00:00+05:30", 3421)
    await s.add(.walkingRunningDistance, "2026-11-12T18:00:00+05:30", 6.1205)
    await s.add(.activeEnergy, "2026-11-12T18:00:00+05:30", 1723.808)  // kJ = 412.0 kcal
    await s.add(.exerciseTime, "2026-11-12T18:00:00+05:30", 2280)  // s = 38 min
    await s.add(.restingHeartRate, "2026-11-12T07:00:00+05:30", 58)
    await s.add(.heartRate, "2026-11-12T10:00:00+05:30", 70)
    await s.add(.heartRate, "2026-11-12T11:00:00+05:30", 78)
    // One night, recorded by both devices with overlap: counted once (402 min), credited to the 12th.
    await s.addSleep("2026-11-11T23:00:00+05:30", "2026-11-12T03:00:00+05:30")
    await s.addSleep("2026-11-11T23:30:00+05:30", "2026-11-12T02:00:00+05:30", "iPhone")
    await s.addSleep("2026-11-12T03:30:00+05:30", "2026-11-12T06:12:00+05:30")
    await s.addWorkout(HealthWorkoutRecord(
        id: "6f1c", activity: .running, start: at("2026-11-12T06:10:00+05:30"), end: at("2026-11-12T06:42:10+05:30"),
        distance: HealthQuantity(5.02, .kilometer), activeEnergy: HealthQuantity(331, .kilocalorie),
        averageHeartRate: HealthQuantity(151.6, .beatsPerMinute), source: "Apple Watch"))
    await s.addWorkout(HealthWorkoutRecord(
        id: "hk-7a2d", activity: .strength, start: at("2026-11-12T19:00:00+05:30"), end: at("2026-11-12T19:40:00+05:30"),
        distance: nil, activeEnergy: nil, averageHeartRate: nil, source: "Apple Watch"))
    return s
}

@Suite struct FitnessSyncTests {
    @Test func payloadMatchesContractWithNullsAndConversions() async throws {
        let store = await seededStore()
        let builder = FitnessSyncBuilder(store: store, calendar: istCalendar, now: { at("2026-11-13T06:30:00+05:30") })
        let payload = try await builder.build(days: 2)
        #expect(payload.generatedAt == "2026-11-13T06:30:00+05:30")
        #expect(payload.days.map(\.date) == ["2026-11-12", "2026-11-13"])

        let d = payload.days[0]
        #expect(d.steps == 8421)
        #expect(d.walkingRunningDistanceM == 6120.5)
        #expect(d.cyclingDistanceM == nil)
        #expect(d.activeEnergyKcal == 412.0)
        #expect(d.exerciseMinutes == 38)
        #expect(d.restingHeartRateBpm == 58)
        #expect(d.avgHeartRateBpm == 74)
        #expect(d.sleepMinutes == 402)
        #expect(d.bodyMassKg == nil)
        #expect(d.sources == ["Apple Watch", "iPhone"])

        let empty = payload.days[1]
        #expect(empty.steps == nil && empty.sleepMinutes == nil && empty.sources.isEmpty)

        #expect(payload.workouts.count == 2)
        let strength = payload.workouts[0]
        #expect(strength.id == "hk-7a2d" && strength.type == "strength")
        #expect(strength.distanceM == nil && strength.avgPaceSPerKm == nil && strength.durationS == 2400)
        let run = payload.workouts[1]
        #expect(run.id == "hk-6f1c")
        #expect(run.startAt == "2026-11-12T06:10:00+05:30" && run.endAt == "2026-11-12T06:42:10+05:30")
        #expect(run.durationS == 1930)
        #expect(run.distanceM == 5020.0)
        #expect(run.activeEnergyKcal == 331.0)
        #expect(run.avgHeartRateBpm == 152)
        #expect(run.avgPaceSPerKm == 384.5)
        #expect(run.source == "Apple Watch")
    }

    @Test func jsonKeepsNullsAndSnakeCase() async throws {
        let store = await seededStore()
        let payload = try await FitnessSyncBuilder(store: store, calendar: istCalendar, now: { at("2026-11-13T06:30:00+05:30") })
            .build(days: 1)
        let json = try #require(String(data: try ZoroJSON.encoder().encode(payload), encoding: .utf8))
        #expect(json.contains("\"body_mass_kg\":null"))
        #expect(json.contains("\"cycling_distance_m\":null"))
        #expect(json.contains("\"walking_running_distance_m\":null"))
        #expect(json.contains("\"generated_at\":\"2026-11-13T06:30:00+05:30\""))
        #expect(json.contains("\"workouts\":[]"))
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let day = try #require((object?["days"] as? [[String: Any]])?.first)
        #expect(Set(day.keys) == [
            "date", "steps", "walking_running_distance_m", "cycling_distance_m", "active_energy_kcal", "exercise_minutes",
            "resting_heart_rate_bpm", "avg_heart_rate_bpm", "sleep_minutes", "body_mass_kg", "sources",
        ])
        #expect(try ZoroJSON.decoder().decode(FitnessSyncPayload.self, from: Data(json.utf8)) == payload)
    }

    @Test func ungrantedMetricIsNullNotFailure() async throws {
        let store = await seededStore()
        await store.fail(.steps)
        let payload = try await FitnessSyncBuilder(store: store, calendar: istCalendar, now: { at("2026-11-13T06:30:00+05:30") })
            .build(days: 2)
        #expect(payload.days[0].steps == nil)
        #expect(payload.days[0].activeEnergyKcal == 412.0)
    }

    @Test func unavailableDeviceThrowsTypedError() async {
        let builder = FitnessSyncBuilder(store: FakeHealthStore(available: false), calendar: istCalendar)
        await #expect(throws: ZoroError.self) { try await builder.build() }
    }
}

@Suite struct HealthMathTests {
    @Test func pace() {
        #expect(HealthMath.paceSecondsPerKm(durationSeconds: 1930, distanceMeters: 5020) == 384.5)
        #expect(HealthMath.paceSecondsPerKm(durationSeconds: 3600, distanceMeters: 10_000) == 360)
        #expect(HealthMath.paceSecondsPerKm(durationSeconds: 1930, distanceMeters: nil) == nil)
        #expect(HealthMath.paceSecondsPerKm(durationSeconds: 600, distanceMeters: 30) == nil)
        #expect(HealthMath.paceSecondsPerKm(durationSeconds: 0, distanceMeters: 5000) == nil)
    }

    @Test func unitConversions() {
        #expect(HealthUnit.convert(1, from: .mile, to: .meter) == 1609.344)
        #expect(HealthMath.round1(HealthUnit.convert(4.184, from: .kilojoule, to: .kilocalorie)!) == 1)
        #expect(HealthUnit.convert(90, from: .second, to: .minute) == 1.5)
        #expect(HealthUnit.convert(2, from: .hour, to: .minute) == 120)
        #expect(abs(HealthUnit.convert(150, from: .pound, to: .kilogram)! - 68.0388555) < 1e-6)
        #expect(HealthUnit.convert(1, from: .meter, to: .kilocalorie) == nil)
        #expect(HealthMath.contractValue(HealthQuantity(150, .pound), for: .bodyMass) == 68.04)
        #expect(HealthMath.contractValue(HealthQuantity(73.6, .beatsPerMinute), for: .heartRate) == 74)
    }

    @Test func sleepAcrossSourcesAndNights() {
        let cal = istCalendar
        let d11 = at("2026-11-11T00:00:00+05:30"), d12 = at("2026-11-12T00:00:00+05:30"), d13 = at("2026-11-13T00:00:00+05:30")
        let buckets = [DateInterval(start: d11, end: d12), DateInterval(start: d12, end: d13), DateInterval(start: d13, end: d13.addingTimeInterval(86400))]
        let samples = [
            HealthSleepSample(start: at("2026-11-11T22:00:00+05:30"), end: at("2026-11-12T02:00:00+05:30"), source: "Watch"),
            HealthSleepSample(start: at("2026-11-11T23:00:00+05:30"), end: at("2026-11-12T01:00:00+05:30"), source: "Phone"),
            HealthSleepSample(start: at("2026-11-12T02:30:00+05:30"), end: at("2026-11-12T06:00:00+05:30"), source: "Watch"),
            // A separate afternoon nap (gap over 2 h) on the 12th.
            HealthSleepSample(start: at("2026-11-12T14:00:00+05:30"), end: at("2026-11-12T14:30:00+05:30"), source: "Watch"),
            HealthSleepSample(start: at("2026-11-12T10:00:00+05:30"), end: at("2026-11-12T09:00:00+05:30"), source: "Bad"),
        ]
        _ = cal
        #expect(SleepAggregator.minutes(samples, buckets: buckets) == [nil, 480, nil])
    }

    @Test func weekBucketsStartOnFirstWeekday() {
        let agg = HealthAggregator(store: FakeHealthStore(), calendar: istCalendar)
        let b = agg.buckets(covering: DateInterval(start: at("2026-11-12T10:00:00+05:30"), end: at("2026-11-20T10:00:00+05:30")), by: .week)
        #expect(b.count == 2)
        #expect(DeviceTime.iso(b[0].start, timeZone: ist) == "2026-11-09T00:00:00+05:30")
    }
}

@Suite struct HealthQueryAndServiceTests {
    func broker(_ store: FakeHealthStore) -> NativeActionBroker {
        NativeActionBroker(
            platform: .ios, handlers: [HealthQueryHandler(store: store, calendar: istCalendar)], confirmer: nil,
            now: { at("2026-11-13T06:30:00+05:30") })
    }

    func req(_ args: JSONObject) -> DeviceActionRequest {
        DeviceActionRequest(actionId: UUID().uuidString, tool: "device.health.query", args: args, risk: .low, expiresAt: at("2026-11-13T07:00:00+05:30"))
    }

    @Test func dailyQueryReturnsPointsSourcesAndFreshness() async throws {
        let store = await seededStore()
        let r = await broker(store).execute(req(["metric": "walking_running_distance", "from": "2026-11-11", "to": "2026-11-12", "bucket": "day"]))
        #expect(r.ok, "\(r.errorMessage ?? "")")
        let points = try #require(r.result?["points"]?.arrayValue)
        #expect(points.count == 2)
        #expect(points[0]["value"] == .null)
        #expect(points[1]["value"] == 6120.5)
        #expect(points[1]["unit"] == "m")
        #expect(points[1]["start"] == "2026-11-12T00:00:00+05:30")
        #expect(r.result?["sources"] == ["Apple Watch"])
        #expect(r.result?["latest_sample_at"] == "2026-11-12T18:00:00+05:30")
    }

    @Test func weeklyStepsAndSleep() async throws {
        let store = await seededStore()
        let steps = await broker(store).execute(req([
            "metric": "steps", "from": "2026-11-09T00:00:00+05:30", "to": "2026-11-16T00:00:00+05:30", "bucket": "week",
        ]))
        #expect(steps.result?["points"]?[0]?["value"] == 8421)
        #expect(steps.result?["points"]?.arrayValue?.count == 1)
        let sleep = await broker(store).execute(req(["metric": "sleep", "from": "2026-11-12", "to": "2026-11-12", "bucket": "day"]))
        #expect(sleep.result?["points"]?[0]?["value"] == 402)
        #expect(sleep.result?["points"]?[0]?["unit"] == "min")
        #expect(sleep.result?["sources"] == ["Apple Watch", "iPhone"])
    }

    @Test func validation() async {
        let b = broker(FakeHealthStore())
        let cases: [(JSONObject, String)] = [
            (["metric": "blood_pressure", "from": "2026-11-01", "to": "2026-11-02", "bucket": "day"], "metric"),
            (["metric": "steps", "from": "yesterday", "to": "2026-11-02", "bucket": "day"], "from"),
            (["metric": "steps", "from": "2026-11-05", "to": "2026-11-02", "bucket": "day"], "to"),
            (["metric": "steps", "from": "2026-02-30", "to": "2026-03-02", "bucket": "day"], "from"),
            (["metric": "steps", "from": "2026-11-01", "to": "2026-11-02", "bucket": "month"], "bucket"),
            (["metric": "steps", "from": "2020-01-01", "to": "2026-11-02", "bucket": "week"], "to"),
        ]
        for (args, field) in cases {
            let r = await b.execute(req(args))
            #expect(r.errorMessage?.hasPrefix("`\(field)`") == true, "\(args): \(r.errorMessage ?? "")")
        }
    }

    @Test func unavailableAndFirstUseAuthorization() async {
        let off = await broker(FakeHealthStore(available: false)).execute(
            req(["metric": "steps", "from": "2026-11-12", "to": "2026-11-12", "bucket": "day"]))
        #expect(off.errorCode == "unsupported" && off.capabilityStatus == .unavailable)

        let store = FakeHealthStore()
        await store.setStatus(.notDetermined)
        let r = await broker(store).execute(req(["metric": "steps", "from": "2026-11-12", "to": "2026-11-12", "bucket": "day"]))
        #expect(r.ok)
        #expect(await store.authorizationRequests == 1)
        #expect(r.result?["points"]?[0]?["value"] == .null)
        #expect(r.result?["latest_sample_at"] == .null)
    }

    @Test func serviceSummaries() async throws {
        let store = await seededStore()
        let service = HealthService(store: store, calendar: istCalendar, now: { at("2026-11-13T06:30:00+05:30") })
        #expect(await service.authorization() == .requested)
        #expect(await HealthService(store: FakeHealthStore(available: false)).authorization() == .unavailable)

        let day = try await service.dailySummary(for: at("2026-11-12T12:00:00+05:30"))
        #expect(day.steps == 8421)
        #expect(day.activeEnergyKcal == 412.0)
        #expect(day.exerciseMinutes == 38)
        #expect(day.sleepHours == 6.7)
        #expect(day.standHours == nil)
        #expect(day.source == "Apple Watch, iPhone")

        let week = try await service.weeklySummary(weekContaining: at("2026-11-12T12:00:00+05:30"))
        #expect(week.days.count == 7)
        #expect(week.totalSteps == 8421)
        #expect(week.workouts == 2)

        let workouts = try await service.workouts(in: DateInterval(start: at("2026-11-12T00:00:00+05:30"), duration: 86400), limit: 10)
        #expect(workouts.last?.distanceMeters == 5020)
        let fresh = try await service.dataFreshness()
        #expect(fresh.first { $0.metric == "body_mass" }?.lastSampleAt == nil)
        #expect(fresh.first { $0.metric == "sleep" }?.lastSampleAt == at("2026-11-12T06:12:00+05:30"))
        await #expect(throws: ZoroError.self) { try await HealthService(store: FakeHealthStore(available: false)).dataFreshness() }
    }
}
