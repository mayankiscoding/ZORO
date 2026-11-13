import Foundation
import LifeSupport
import Testing
import ZoroCore
@testable import FitnessFeature

// MARK: Fakes

final class FakeHealth: HealthDataProviding, @unchecked Sendable {
    var auth: HealthAuthorization
    var grantsOnRequest: HealthAuthorization
    var requestError: Error?
    var daily: [String: HealthDailySummary] = [:]
    var workoutList: [WorkoutSummary] = []
    var weekly: HealthWeeklySummary?
    private(set) var requestCount = 0
    private(set) var dailyCalls = 0

    init(auth: HealthAuthorization = .requested, grantsOnRequest: HealthAuthorization = .requested) {
        self.auth = auth
        self.grantsOnRequest = grantsOnRequest
    }

    func authorization() async -> HealthAuthorization { auth }
    func requestAuthorization() async throws {
        requestCount += 1
        if let requestError { throw requestError }
        auth = grantsOnRequest
    }
    func dailySummary(for day: Date) async throws -> HealthDailySummary {
        dailyCalls += 1
        let key = FakeHealth.key(day)
        return daily[key] ?? HealthDailySummary(date: day, source: "iPhone", fetchedAt: day)
    }
    func weeklySummary(weekContaining day: Date) async throws -> HealthWeeklySummary {
        guard let weekly else { throw ZoroError.unavailable(capability: "Health", reason: "no week") }
        return weekly
    }
    func workouts(in interval: DateInterval, limit: Int) async throws -> [WorkoutSummary] { workoutList }
    func dataFreshness() async throws -> [HealthDataFreshness] { [] }

    static func key(_ d: Date) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return CalendarDate(date: d, timeZone: c.timeZone).description
    }
}

final class FakeSyncer: FitnessSyncing, @unchecked Sendable {
    var result: Result<FitnessSyncResult, Error>
    private(set) var count = 0
    init(_ result: Result<FitnessSyncResult, Error>) { self.result = result }
    func syncNow() async throws -> FitnessSyncResult {
        count += 1
        return try result.get()
    }
}

let kolkata = TimeZone(identifier: "Asia/Kolkata")!
let fixedNow = ZoroJSON.parseDate("2026-11-13T12:00:00Z")!

func serverWithData(_ api: FakeAPI = FakeAPI()) throws -> FakeAPI {
    try api.reply(.get, "/v1/fitness/freshness", fixture: "freshness")
    try api.reply(.get, "/v1/fitness/summary", fixture: "summary")
    try api.reply(.get, "/v1/fitness/weekly", fixture: "weekly")
    try api.reply(.get, "/v1/fitness/trends", fixture: "trend")
    try api.reply(.get, "/v1/fitness/running", fixture: "running")
    try api.reply(.get, "/v1/fitness/records", fixture: "records")
    try api.reply(.get, "/v1/fitness/consistency", fixture: "consistency")
    try api.reply(.post, "/v1/fitness/running-plan", fixture: "plan")
    try api.reply(.post, "/v1/fitness/sync", fixture: "sync_out")
    return api
}

@MainActor
func makeModel(api: FakeAPI, health: FakeHealth = FakeHealth(), syncer: FakeSyncer? = nil) -> FitnessViewModel {
    let server = FitnessAPIClient(api: api)
    let sync = syncer ?? FakeSyncer(.success(try! Fixtures.decode(FitnessSyncResult.self, "sync_out")))
    return FitnessViewModel(server: server, health: health, syncer: sync, timeZone: kolkata, clock: { fixedNow })
}

// MARK: Client

@Suite("Fitness client requests")
struct ClientTests {
    @Test func requestsMirrorTheRoutes() async throws {
        let api = try serverWithData()
        let client = FitnessAPIClient(api: api)
        _ = try await client.freshness()
        _ = try await client.summary(date: CalendarDate("2026-11-12"), timeZone: kolkata)
        _ = try await client.weekly(timeZone: kolkata)
        _ = try await client.trend(metric: "sleep_hours", days: 60, timeZone: kolkata)
        _ = try await client.running(days: 90, timeZone: kolkata)
        _ = try await client.records()
        _ = try await client.consistency(weeks: 8, timeZone: kolkata)
        let calls = api.calls.get
        #expect(calls.map(\.path) == [
            "/v1/fitness/freshness", "/v1/fitness/summary", "/v1/fitness/weekly", "/v1/fitness/trends", "/v1/fitness/running",
            "/v1/fitness/records", "/v1/fitness/consistency",
        ])
        #expect(calls.allSatisfy { $0.method == .get })
        func query(_ i: Int, _ name: String) -> String? { calls[i].query.first { $0.name == name }?.value }
        #expect(query(1, "date") == "2026-11-12")
        #expect(query(1, "tz") == "Asia/Kolkata")
        #expect(query(3, "metric") == "sleep_hours")
        #expect(query(3, "days") == "60")
        #expect(query(6, "weeks") == "8")
    }

    @Test func todaySendsNoDateParameter() async throws {
        let api = try serverWithData()
        _ = try await FitnessAPIClient(api: api).summary(date: nil, timeZone: kolkata)
        #expect(api.calls.get[0].query.map(\.name) == ["tz"])
    }

    @Test func planRequestBody() async throws {
        let api = try serverWithData()
        let request = RunningPlanRequest(goal: .tenK, weeks: 10, daysPerWeek: 4, currentWeeklyKm: 12.5)
        _ = try await FitnessAPIClient(api: api).runningPlan(request, timeZone: kolkata)
        let call = try #require(api.calls.get.first)
        #expect(call.method == .post)
        let body = try bodyObject(call)
        #expect(body["goal"] as? String == "10k")
        #expect(body["weeks"] as? Int == 10)
        #expect(body["days_per_week"] as? Int == 4)
        #expect(body["current_weekly_km"] as? Double == 12.5)
        #expect(call.query.first?.value == "Asia/Kolkata")
    }

    @Test func planBodyOmitsWhatTheOwnerDidNotChoose() async throws {
        let api = try serverWithData()
        _ = try await FitnessAPIClient(api: api).runningPlan(RunningPlanRequest(), timeZone: kolkata)
        let body = try bodyObject(api.calls.get[0])
        #expect(body["weeks"] == nil)
        #expect(body["current_weekly_km"] == nil)
        #expect(body["goal"] as? String == "first_5k")
    }

    @Test func syncPostsToTheSyncRoute() async throws {
        let api = try serverWithData()
        let result = try await FitnessAPIClient(api: api).sync(FitnessSyncPayload(generatedAt: fixedNow, days: [], workouts: []))
        #expect(result.daysSent == 14)
        #expect(api.calls.get[0].path == "/v1/fitness/sync")
    }
}

// MARK: View model

@Suite("Fitness view model")
@MainActor
struct ViewModelTests {
    @Test func loadsEveryFigureWithItsSource() async throws {
        let model = makeModel(api: try serverWithData())
        #expect(model.screen == .idle)
        await model.load()
        #expect(model.screen == .loaded)
        #expect(model.freshness?.ageValue == 2)
        #expect(model.today.value?.steps == 8421)
        #expect(model.weekly.value?.metrics.count == 3)
        #expect(model.trend.value?.direction == .up)
        #expect(model.running.value?.runs == 14)
        #expect(model.records.value?.records.count == 3)
        #expect(model.consistency.value?.activeDays == 31)
        for source in [model.today.value?.sourcing, model.weekly.value?.sourcing, model.running.value?.sourcing] {
            #expect(source?.dataSource == "Apple Health (synced from your iPhone)")
        }
    }

    @Test func neverSyncedIsAnInvitationNotAFailure() async throws {
        let api = FakeAPI()
        try api.reply(.get, "/v1/fitness/freshness", fixture: "freshness_never")
        let model = makeModel(api: api)
        await model.load()
        #expect(model.screen == .empty)
        #expect(model.today == .idle)
        #expect(api.requests("/v1/fitness/summary").isEmpty, "no figures are requested before anything is synced")
    }

    @Test func unreachableServerIsDisconnectedWithAnAction() async throws {
        let api = FakeAPI()
        api.fail(.get, "/v1/fitness/freshness", with: ZoroError.transport("offline"))
        let model = makeModel(api: api)
        await model.load()
        let failure = try #require(model.screen.failure)
        #expect(failure.kind == .disconnected)
        #expect(failure.message.contains("Could not reach your ZORO server"))
    }

    @Test func missingHealthPermissionOnlyFailsItsSection() async throws {
        let api = try serverWithData()
        let denied = ZoroError.http(status: 403, body: ErrorBody(code: "permission_not_granted:health.read", message: "no"))
        api.fail(.get, "/v1/fitness/records", with: denied)
        let model = makeModel(api: api)
        await model.load()
        #expect(model.screen == .loaded)
        #expect(model.records.failure?.message == "Allow health.read in Security and privacy, then try again.")
        #expect(model.today.value != nil)
    }

    @Test func serverSaysNotEnoughDataThroughTheTypedUnavailableResult() async throws {
        let api = try serverWithData()
        try api.reply(.get, "/v1/fitness/running", fixture: "running_none")
        let model = makeModel(api: api)
        await model.load()
        #expect(model.running.value?.sourcing.available == false)
        #expect(model.running.value?.sourcing.reason == "no_running_data")
    }

    @Test func changingTheTrendMetricReloadsOnlyTheTrend() async throws {
        let api = try serverWithData()
        let model = makeModel(api: api)
        await model.load()
        let before = api.calls.get.count
        await model.selectTrend(metric: .sleepHours, days: 60)
        #expect(model.trendMetric == .sleepHours)
        #expect(model.trendDays == 60)
        #expect(api.calls.get.count == before + 1)
        let last = try #require(api.calls.get.last)
        #expect(last.query.first { $0.name == "metric" }?.value == "sleep_hours")
        await model.selectTrend(days: 1000)
        #expect(model.trendDays == 180)
    }

    @Test func refreshAfterFailureRecovers() async throws {
        let api = FakeAPI()
        api.fail(.get, "/v1/fitness/freshness", with: ZoroError.timeout)
        let model = makeModel(api: api)
        await model.load()
        #expect(model.screen.failure != nil)
        _ = try serverWithData(api)
        await model.load()
        #expect(model.screen == .loaded)
    }

    @Test func onDeviceWeekLoadsOnlyAfterHealthWasRequested() async throws {
        let health = FakeHealth(auth: .notDetermined)
        let model = makeModel(api: try serverWithData(), health: health)
        await model.load()
        #expect(model.thisWeekOnDevice == .idle)

        let week = HealthWeeklySummary(
            weekStart: fixedNow, days: [HealthDailySummary(date: fixedNow, steps: 5000, source: "iPhone", fetchedAt: fixedNow)], workouts: 1,
            source: "Apple Health", fetchedAt: fixedNow)
        let granted = FakeHealth(auth: .requested)
        granted.weekly = week
        let model2 = makeModel(api: try serverWithData(), health: granted)
        await model2.load()
        #expect(model2.thisWeekOnDevice.value?.workouts == 1)
        let bars = DeviceWeekPresenter.stepBars(week, timeZone: kolkata)
        #expect(bars.map(\.valueText) == ["5,000 steps"])
    }

    @Test func daysWithoutStepsAreNotDrawnAsZero() {
        let week = HealthWeeklySummary(
            weekStart: fixedNow,
            days: [
                HealthDailySummary(date: fixedNow, steps: nil, source: "iPhone", fetchedAt: fixedNow),
                HealthDailySummary(date: fixedNow.addingTimeInterval(86400), steps: 0, source: "iPhone", fetchedAt: fixedNow),
            ], workouts: 0, source: "Apple Health", fetchedAt: fixedNow)
        let bars = DeviceWeekPresenter.stepBars(week, timeZone: kolkata)
        #expect(bars.count == 1)
        #expect(bars[0].value == 0)
        #expect(DeviceWeekPresenter.sourceLine(week, now: fixedNow, timeZone: kolkata).hasPrefix("From Apple Health on this device, read "))
    }
}

// MARK: Health permission and sync

@Suite("Fitness sync flow")
@MainActor
struct SyncFlowTests {
    @Test func firstSyncAsksForHealthThenSyncsThenReloads() async throws {
        let health = FakeHealth(auth: .notDetermined)
        let syncer = FakeSyncer(.success(try Fixtures.decode(FitnessSyncResult.self, "sync_out")))
        let model = makeModel(api: try serverWithData(), health: health, syncer: syncer)
        await model.load()
        #expect(model.healthAuthorization == .notDetermined)
        #expect(model.syncButtonTitle == "Allow Health and sync")
        await model.syncNow()
        #expect(health.requestCount == 1)
        #expect(syncer.count == 1)
        guard case .done(let result) = model.syncState else { Issue.record("expected done, got \(model.syncState)"); return }
        #expect(result.daysSent == 14)
        #expect(model.healthAuthorization == .requested)
        #expect(model.syncButtonTitle == "Sync now")
        #expect(model.screen == .loaded)
    }

    @Test func deniedHealthSheetDoesNotSync() async throws {
        let health = FakeHealth(auth: .notDetermined, grantsOnRequest: .notDetermined)
        let syncer = FakeSyncer(.success(try Fixtures.decode(FitnessSyncResult.self, "sync_out")))
        let model = makeModel(api: try serverWithData(), health: health, syncer: syncer)
        await model.load()
        await model.syncNow()
        #expect(syncer.count == 0)
        let failure = try #require(model.syncState == .idle ? nil : { if case .failed(let f) = model.syncState { f } else { nil } }())
        #expect(failure.message.contains("Health access was not allowed"))
        #expect(failure.message.contains("tap Sync now"))
    }

    @Test func requestErrorIsShownAsASentence() async throws {
        let health = FakeHealth(auth: .notDetermined)
        health.requestError = ZoroError.unavailable(capability: "Health", reason: "blocked by a profile")
        let model = makeModel(api: try serverWithData(), health: health)
        await model.load()
        await model.syncNow()
        guard case .failed(let f) = model.syncState else { Issue.record("expected failure"); return }
        #expect(f.message == "Health is not available: blocked by a profile.")
    }

    @Test func macCannotSyncAndSaysSo() async throws {
        let health = FakeHealth(auth: .unavailable)
        let syncer = FakeSyncer(.success(try Fixtures.decode(FitnessSyncResult.self, "sync_out")))
        let model = makeModel(api: try serverWithData(), health: health, syncer: syncer)
        await model.load()
        #expect(!model.canSyncFromThisDevice)
        #expect(model.syncNote == "Apple Health is only on iPhone. This screen shows what your iPhone last synced.")
        await model.syncNow()
        #expect(syncer.count == 0)
        #expect(model.syncState == .idle)
        #expect(model.screen == .loaded)
    }

    @Test func serverFailureDuringSyncIsReported() async throws {
        let syncer = FakeSyncer(.failure(ZoroError.transport("offline")))
        let model = makeModel(api: try serverWithData(), syncer: syncer)
        await model.load()
        await model.syncNow()
        guard case .failed(let f) = model.syncState else { Issue.record("expected failure"); return }
        #expect(f.kind == .disconnected)
    }

    @Test func emptyStateThenSyncFillsTheScreen() async throws {
        let api = FakeAPI()
        try api.reply(.get, "/v1/fitness/freshness", fixture: "freshness_never")
        let model = makeModel(api: api)
        await model.load()
        #expect(model.screen == .empty)
        _ = try serverWithData(api)
        await model.syncNow()
        #expect(model.screen == .loaded)
        #expect(model.today.value?.steps == 8421)
    }
}

@Suite("HealthKit aggregates to sync payload")
struct HealthSyncTests {
    func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kolkata
        return c
    }

    @Test func buildsDaysAndWorkoutsFromWhatTheDeviceReturned() async throws {
        let health = FakeHealth()
        let today = calendar().startOfDay(for: fixedNow)
        health.daily[FakeHealth.key(today)] = HealthDailySummary(
            date: today, steps: 8421, activeEnergyKcal: 412, exerciseMinutes: 38, restingHeartRate: 58, sleepHours: 6.7, source: "Apple Watch", fetchedAt: fixedNow)
        let yesterday = calendar().date(byAdding: .day, value: -1, to: today)!
        health.daily[FakeHealth.key(yesterday)] = HealthDailySummary(date: yesterday, steps: 1000, source: "iPhone", fetchedAt: fixedNow)
        health.workoutList = [
            WorkoutSummary(id: "w1", activityType: "Running", start: fixedNow, end: fixedNow.addingTimeInterval(1930), energyKcal: 331, distanceMeters: 5020, source: "Apple Watch"),
            WorkoutSummary(id: "w2", activityType: "TraditionalStrengthTraining", start: fixedNow, end: fixedNow.addingTimeInterval(600), source: "iPhone"),
            WorkoutSummary(id: "w3", activityType: "Pickleball", start: fixedNow, end: fixedNow.addingTimeInterval(600), source: ""),
        ]
        let api = try serverWithData()
        let sync = HealthFitnessSync(health: health, server: FitnessAPIClient(api: api), days: 3, timeZone: kolkata, clock: { fixedNow })
        let result = try await sync.syncNow()
        #expect(result.daysSent == 14)
        #expect(health.dailyCalls == 3)

        let call = try #require(api.requests("/v1/fitness/sync").first)
        let body = try bodyObject(call)
        let days = try #require(body["days"] as? [[String: Any]])
        #expect(days.count == 2, "the day with no readings is not sent as a row of nulls")
        #expect(days.map { $0["date"] as? String } == ["2026-11-12", "2026-11-13"], "oldest first")
        let last = days[1]
        #expect(last["steps"] as? Double == 8421)
        #expect(last["sleep_minutes"] as? Double == 6.7 * 60)
        #expect(last["sources"] as? [String] == ["Apple Watch"])
        #expect(last["body_mass_kg"] == nil, "nothing is estimated")
        let workouts = try #require(body["workouts"] as? [[String: Any]])
        #expect(workouts.map { $0["type"] as? String } == ["running", "strength", "other"])
        let pace = try #require(workouts[0]["avg_pace_s_per_km"] as? Double)
        #expect(abs(pace - 1930 / 5.02) < 0.001)
        #expect(workouts[1]["avg_pace_s_per_km"] == nil)
        #expect(workouts[2]["source"] == nil)
        #expect(body["generated_at"] as? String == "2026-11-13T12:00:00Z")
    }

    @Test func refusesWithoutHealthAccess() async throws {
        let api = try serverWithData()
        for (auth, reason) in [(HealthAuthorization.unavailable, "only available on an iPhone"), (.notDetermined, "not been allowed yet")] {
            let sync = HealthFitnessSync(health: FakeHealth(auth: auth), server: FitnessAPIClient(api: api), timeZone: kolkata, clock: { fixedNow })
            do {
                _ = try await sync.syncNow()
                Issue.record("expected a refusal")
            } catch let ZoroError.unavailable(capability, why) {
                #expect(capability == "Apple Health")
                #expect(why.contains(reason))
            }
        }
        #expect(api.requests("/v1/fitness/sync").isEmpty)
    }

    @Test func workoutTypeMapping() {
        #expect(HealthFitnessSync.workoutType("HKWorkoutActivityTypeRunning") == "running")
        #expect(HealthFitnessSync.workoutType("walking") == "walking")
        #expect(HealthFitnessSync.workoutType("Cycling") == "cycling")
        #expect(HealthFitnessSync.workoutType("functional_strength_training") == "strength")
        #expect(HealthFitnessSync.workoutType("Yoga") == "yoga")
        #expect(HealthFitnessSync.workoutType("Swimming") == "swimming")
        #expect(HealthFitnessSync.workoutType("") == "other")
    }
}

// MARK: Running plan builder

@Suite("Running plan view model")
@MainActor
struct PlanViewModelTests {
    func model(_ api: FakeAPI) -> RunningPlanViewModel {
        RunningPlanViewModel(server: FitnessAPIClient(api: api), timeZone: kolkata, clock: { fixedNow })
    }

    @Test func buildsAPlanFromTheForm() async throws {
        let api = try serverWithData()
        let m = model(api)
        m.goal = .tenK
        m.daysPerWeek = 4
        m.weeks = 10
        m.currentKmText = "12,5"
        #expect(m.problems.isEmpty)
        await m.build()
        let plan = try #require(m.plan.value?.plan)
        #expect(plan.weeks.count == 8)
        let body = try bodyObject(api.requests("/v1/fitness/running-plan").first)
        #expect(body["current_weekly_km"] as? Double == 12.5)
        #expect(body["goal"] as? String == "10k")
    }

    @Test func validatesLikeTheServer() async throws {
        let api = try serverWithData()
        let m = model(api)
        m.currentKmText = "abc"
        #expect(m.problems == ["Enter your weekly distance as a number from 0 to 200 km, or leave it empty."])
        #expect(!m.canBuild)
        await m.build()
        #expect(api.requests("/v1/fitness/running-plan").isEmpty)
        m.currentKmText = "300"
        #expect(m.problems == ["Enter your weekly distance as a number from 0 to 200 km."])
        m.currentKmText = ""
        m.weeks = 2
        #expect(m.problems == ["Choose between 4 and 20 weeks."])
        m.weeks = nil
        #expect(m.problems.isEmpty && m.canBuild)
    }

    @Test func serverFailureCanBeRetried() async throws {
        let api = try serverWithData()
        api.fail(.post, "/v1/fitness/running-plan", with: ZoroError.timeout)
        let m = model(api)
        await m.build()
        #expect(m.plan.failure?.kind == .disconnected)
        try api.reply(.post, "/v1/fitness/running-plan", fixture: "plan")
        await m.build()
        #expect(m.plan.value?.plan != nil)
        m.clear()
        #expect(m.plan == .idle)
    }
}
