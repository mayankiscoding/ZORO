import Foundation
import Testing
import ZoroCore
@testable import FitnessFeature

@Suite("Freshness formatting")
struct FreshnessTests {
    let now = ZoroJSON.parseDate("2026-11-13T12:00:00Z")!
    func fresh(minutesAgo: Double) -> FitnessFreshness {
        FitnessFreshness(lastSyncedAt: now.addingTimeInterval(-minutesAgo * 60), stale: false)
    }

    @Test func buckets() {
        #expect(FreshnessFormatter.age(fresh(minutesAgo: 0.2), now: now) == "just now")
        #expect(FreshnessFormatter.age(fresh(minutesAgo: 1), now: now) == "1 minute ago")
        #expect(FreshnessFormatter.age(fresh(minutesAgo: 45), now: now) == "45 minutes ago")
        #expect(FreshnessFormatter.age(fresh(minutesAgo: 60), now: now) == "1 hour ago")
        #expect(FreshnessFormatter.age(fresh(minutesAgo: 60 * 30), now: now) == "30 hours ago")
        #expect(FreshnessFormatter.age(fresh(minutesAgo: 60 * 24 * 2), now: now) == "2 days ago")
        #expect(FreshnessFormatter.age(fresh(minutesAgo: 60 * 24 * 40), now: now) == "40 days ago")
    }

    @Test func aClockBehindTheServerNeverGivesANegativeAge() {
        let future = FitnessFreshness(lastSyncedAt: now.addingTimeInterval(500), stale: false)
        #expect(FreshnessFormatter.age(future, now: now) == "just now")
    }

    @Test func fallsBackToTheServersOwnAge() {
        let f = FitnessFreshness(ageValue: 1, ageUnit: .days, stale: false)
        #expect(FreshnessFormatter.age(f, now: now) == "1 day ago")
        #expect(FreshnessFormatter.age(FitnessFreshness(), now: now) == nil)
    }

    @Test func lineNamesSourceAndAge() {
        let source = "Apple Health (synced from your iPhone)"
        #expect(FreshnessFormatter.line(source: source, freshness: fresh(minutesAgo: 120), now: now) == "From Apple Health (synced from your iPhone), synced 2 hours ago.")
        #expect(FreshnessFormatter.line(source: source, freshness: fresh(minutesAgo: 0), now: now) == "From Apple Health (synced from your iPhone), synced just now.")
        #expect(FreshnessFormatter.line(source: source, freshness: FitnessFreshness(), now: now) == "From Apple Health (synced from your iPhone). Nothing has been synced yet.")
    }

    @Test func staleNoteSaysWhatToDo() {
        #expect(FreshnessFormatter.staleNote(fresh(minutesAgo: 10)) == nil)
        #expect(FreshnessFormatter.staleNote(FitnessFreshness(lastSyncedAt: now, stale: true)) == "This may be out of date. Tap Sync now for current figures.")
        #expect(FreshnessFormatter.staleNote(FitnessFreshness())?.contains("Nothing has been synced yet") == true)
    }

    @Test func latestDay() {
        let f = FitnessFreshness(latestDataDate: CalendarDate("2026-11-12"), stale: false)
        #expect(FreshnessFormatter.latestDay(f) == "Latest day: 12 Nov")
        #expect(FreshnessFormatter.latestDay(FitnessFreshness()) == nil)
    }
}

@Suite("Fitness presenters")
struct PresenterTests {
    @Test func todayTilesShowOnlyWhatWasRecorded() throws {
        let s = try Fixtures.decode(DailySummary.self, "summary")
        let tiles = TodayPresenter.tiles(s)
        #expect(tiles.map(\.id) == ["steps", "distance", "energy", "exercise", "rhr", "sleep"])
        #expect(tiles[0].value == "8,421")
        #expect(tiles[1].value == "6.1" && tiles[1].unit == "km")
        #expect(tiles[0].accessibilityLabel == "Steps, 8,421")
        #expect(tiles[2].accessibilityLabel == "Active energy, 412 kcal")
        #expect(TodayPresenter.missingNote(s) == nil, "every figure the card shows is present")
    }

    @Test func missingNoteListsWhatIsMissing() throws {
        let s = try Fixtures.decode(DailySummary.self, "summary_stale")
        let note = try #require(TodayPresenter.missingNote(s))
        #expect(note.hasPrefix("No reading yet for distance, active energy, exercise and sleep."))
        #expect(TodayPresenter.tiles(s).map(\.id) == ["steps"])
    }

    @Test func workoutLine() throws {
        let s = try Fixtures.decode(DailySummary.self, "summary")
        #expect(TodayPresenter.workoutLine(s.workouts[0]) == "Running, 5.02 km, 32 min, 6:24 per km")
    }

    @Test func weeklyRows() throws {
        let rows = WeeklyPresenter.rows(try Fixtures.decode(WeeklyComparison.self, "weekly"))
        #expect(rows[0].label == "Steps")
        #expect(rows[0].current == "8,422 steps a day" || rows[0].current == "8,421 steps a day")
        #expect(rows[0].change == "Up 20.1% on last week")
        #expect(rows[0].direction == .up)
        #expect(rows[1].label == "Sleep")
        #expect(rows[1].current == "6.7 h a day")
        #expect(rows[1].change == "Down 5.6% on last week")
        #expect(rows[1].direction == .down)
        #expect(rows[2].direction == .unknown)
        #expect(rows[2].change == "Not enough days to compare yet. This week has 1 day of data and last week 0 days.")
        #expect(rows[2].current == "Not enough days")
    }

    @Test func weeklyRangeAndWorkouts() throws {
        let w = try Fixtures.decode(WeeklyComparison.self, "weekly")
        #expect(WeeklyPresenter.rangeLine(w) == "7 Nov to 13 Nov, against 31 Oct to 6 Nov")
        #expect(WeeklyPresenter.workoutsLine(w) == "Workouts: 4 this week, 3 last week.")
    }

    @Test func trendSentences() throws {
        let up = TrendPresenter.summary(try Fixtures.decode(TrendResult.self, "trend"))
        #expect(up.headline == "Steps: going up by about 313 steps a week")
        #expect(up.symbol == "arrow.up.right")
        #expect(up.detail == "Average 7,890 steps. Based on 26 days.")
        let none = TrendPresenter.summary(try Fixtures.decode(TrendResult.self, "trend_insufficient"))
        #expect(none.headline == "Not enough data for body weight yet")
        #expect(none.detail.hasPrefix("2 of 7 days needed."))
        #expect(none.symbol == "ellipsis")
    }

    @Test func runningPresentation() throws {
        let r = try Fixtures.decode(RunningProgress.self, "running")
        let tiles = RunningPresenter.tiles(r)
        #expect(tiles.map(\.id) == ["runs", "distance", "pace", "recent"])
        #expect(tiles[1].value == "71.3")
        #expect(tiles[2].value == "6:32")
        #expect(RunningPresenter.paceSentence(r) == "Your pace is getting faster: about 3 seconds per km quicker each week.")
        let bars = RunningPresenter.weeklyBars(r)
        #expect(bars.count == 4)
        #expect(bars[3].valueText == "18.2 km in 3 runs")
        #expect(bars[2].valueText == "0 km in 0 runs")
        #expect(bars[3].label.hasPrefix("Week of "))
    }

    @Test func paceTrendNeedsEnoughRuns() throws {
        var r = try Fixtures.decode(RunningProgress.self, "running")
        r.direction = .insufficientData
        r.runs = 2
        #expect(RunningPresenter.paceSentence(r) == "Pace trend needs at least 4 runs. You have 2; 2 more and it will show here.")
    }

    @Test func recordRows() throws {
        let rows = RecordsPresenter.rows(try Fixtures.decode(PersonalRecords.self, "records"))
        #expect(rows[0].label == "Longest run")
        #expect(rows[0].value == "10.4 km")
        #expect(rows[0].detail == "4 Nov 2026, Apple Watch")
        #expect(rows[1].value == "5:12 min per km")
        #expect(rows[2].label == "Most steps in a day")
        #expect(rows[0].accessibilityLabel == "Longest run, 10.4 km, on 4 Nov 2026, Apple Watch")
    }

    @Test func consistencyPresentation() throws {
        let c = try Fixtures.decode(Consistency.self, "consistency")
        let tiles = ConsistencyPresenter.tiles(c)
        #expect(tiles[0].value == "31 of 50")
        #expect(tiles[1].value == "3" && tiles[1].unit == "days")
        #expect(tiles[3].value == "3.4" && tiles[3].unit == "target 3")
        #expect(ConsistencyPresenter.summary(c) == "5 of the last 8 weeks reached 3 sessions. A day counts as active with at least 20 minutes of exercise.")
        #expect(ConsistencyPresenter.weeklyBars(c).count == 8)
    }

    @Test func planPresentation() throws {
        let plan = try #require(try Fixtures.decode(RunningPlanOut.self, "plan").plan)
        #expect(PlanPresenter.goalTitle("first_5k") == "Run my first 5 km")
        #expect(PlanPresenter.startBasisSentence(plan) == "Starts at 10 km a week, the figure you gave.")
        #expect(PlanPresenter.weekTitle(plan.weeks[3]).contains("lighter week"))
        #expect(PlanPresenter.sessionLine(plan.weeks[0].sessions[0]).hasPrefix("Tuesday: easy run,"))
        let assumed = try #require(try Fixtures.decode(RunningPlanOut.self, "plan_10k_assumed").plan)
        #expect(PlanPresenter.startBasisSentence(assumed).contains("That is an assumption"))
    }

    @Test func unavailableSentencesAlwaysSayWhatToDo() {
        for reason in ["never_synced", "no_data_for_date", "no_data_in_window", "not_enough_data", "no_running_data", nil, "something_new"] {
            let text = FitnessUnavailableText.sentence(reason: reason)
            #expect(text.hasSuffix("."))
            #expect(text.contains("sync") || text.contains("Sync") || text.contains("Keep"))
        }
    }

    @Test func syncSummary() throws {
        #expect(SyncPresenter.summary(try Fixtures.decode(FitnessSyncResult.self, "sync_out")) == "Sent 14 days and 2 workouts to your server.")
    }

    @Test func noAllCapsLabels() throws {
        let labels = TodayPresenter.tiles(try Fixtures.decode(DailySummary.self, "summary")).map(\.label)
            + TrendMetric.allCases.map(\.title) + RunningGoal.allCases.map(\.title)
        for label in labels { #expect(label != label.uppercased() || label.count < 3, "\(label) is all caps") }
    }

    @Test func rangesMatchTheServer() {
        #expect(RunningPlanRequest.weeksRange == 4...20)
        #expect(RunningPlanRequest.daysRange == 2...6)
        #expect(RunningPlanRequest(goal: .tenK, weeks: 3).problems == ["Choose between 4 and 20 weeks."])
        #expect(RunningPlanRequest(daysPerWeek: 7).problems == ["Choose between 2 and 6 running days a week."])
        #expect(RunningPlanRequest(currentWeeklyKm: 250).problems.count == 1)
        #expect(RunningPlanRequest(goal: .fiveK, weeks: 8, daysPerWeek: 4, currentWeeklyKm: 12).problems.isEmpty)
    }
}
