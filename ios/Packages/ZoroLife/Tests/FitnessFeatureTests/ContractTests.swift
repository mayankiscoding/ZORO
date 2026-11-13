import Foundation
import Testing
import ZoroCore
@testable import FitnessFeature

@Suite("Fitness contract: DTOs decode the server's real JSON")
struct FitnessContractTests {
    @Test func dailySummary() throws {
        let s = try Fixtures.decode(DailySummary.self, "summary")
        #expect(s.date.description == "2026-11-13")
        #expect(s.steps == 8421)
        #expect(s.distanceKm == 6.1)
        #expect(s.cyclingKm == nil)
        #expect(s.bodyMassKg == nil)
        #expect(s.sleepHours == 6.7)
        #expect(s.workouts.count == 1)
        #expect(s.workouts[0].paceText == "6:24")
        #expect(s.sourcing.available)
        #expect(s.sourcing.dataSource == "Apple Health (synced from your iPhone)")
        #expect(s.sourcing.devices == ["Apple Watch", "iPhone"])
        #expect(s.sourcing.observations.map(\.code) == ["rhr_above_baseline", "load_up"])
        #expect(s.sourcing.freshness.ageValue == 2)
        #expect(s.sourcing.freshness.ageUnit == .hours)
        #expect(s.sourcing.freshness.stale == false)
        #expect(s.sourcing.freshness.lastSyncedAt == ZoroJSON.parseDate("2026-11-13T10:00:00Z"))
    }

    @Test func unavailableSummaryCarriesTheReason() throws {
        let s = try Fixtures.decode(DailySummary.self, "summary_unavailable")
        #expect(!s.sourcing.available)
        #expect(s.sourcing.reason == "never_synced")
        #expect(s.steps == nil)
        #expect(s.sourcing.freshness.neverSynced)
        #expect(s.sourcing.freshness.stale)
    }

    @Test func staleSummary() throws {
        let s = try Fixtures.decode(DailySummary.self, "summary_stale")
        #expect(s.sourcing.freshness.stale)
        #expect(s.sourcing.freshness.ageUnit == .days)
    }

    @Test func weeklyComparison() throws {
        let w = try Fixtures.decode(WeeklyComparison.self, "weekly")
        #expect(w.metrics.count == 3)
        let steps = try #require(w.metrics.first { $0.metric == "steps" })
        #expect(steps.currentAvg == 8421.5)
        #expect(steps.changePct == 20.1)
        #expect(steps.enoughData)
        let weight = try #require(w.metrics.first { $0.metric == "body_mass_kg" })
        #expect(!weight.enoughData)
        #expect(weight.currentAvg == nil)
        #expect(w.workoutsCurrent == 4 && w.workoutsPrevious == 3)
        #expect(w.currentStart?.description == "2026-11-07")
    }

    @Test func trends() throws {
        let t = try Fixtures.decode(TrendResult.self, "trend")
        #expect(t.direction == .up)
        #expect(t.slopePerWeek == 312.5)
        #expect(t.pointsUsed == 26)
        let none = try Fixtures.decode(TrendResult.self, "trend_insufficient")
        #expect(none.direction == .insufficientData)
        #expect(!none.sourcing.available)
        #expect(none.sourcing.reason == "not_enough_data")
    }

    @Test func running() throws {
        let r = try Fixtures.decode(RunningProgress.self, "running")
        #expect(r.runs == 14)
        #expect(r.totalKm == 71.3)
        #expect(r.avgPaceText == "6:32")
        #expect(r.direction == .faster)
        #expect(r.weekly.count == 4)
        #expect(r.weekly[3].km == 18.2)
        let none = try Fixtures.decode(RunningProgress.self, "running_none")
        #expect(!none.sourcing.available)
        #expect(none.sourcing.reason == "no_running_data")
    }

    @Test func records() throws {
        let r = try Fixtures.decode(PersonalRecords.self, "records")
        #expect(r.records.map(\.kind) == ["longest_run", "fastest_pace_run", "most_steps_day"])
        #expect(r.records[0].display == "10.4")
        #expect(r.records[0].workoutId == "w9")
        #expect(r.records[1].display == "5:12")
        #expect(!r.note.isEmpty)
    }

    @Test func consistency() throws {
        let c = try Fixtures.decode(Consistency.self, "consistency")
        #expect(c.activeDays == 31)
        #expect(c.currentStreakDays == 3 && c.longestStreakDays == 6)
        #expect(c.avgSessionsPerWeek == 3.4)
        #expect(c.weeks.count == 8)
        #expect(c.weeksMeetingTarget == 5)
    }

    @Test func freshness() throws {
        let f = try Fixtures.decode(FitnessFreshness.self, "freshness")
        #expect(f.ageValue == 2 && f.ageUnit == .hours && !f.stale)
        #expect(f.latestDataDate?.description == "2026-11-13")
        let never = try Fixtures.decode(FitnessFreshness.self, "freshness_never")
        #expect(never.neverSynced && never.stale && never.ageValue == nil)
    }

    @Test func runningPlan() throws {
        let out = try Fixtures.decode(RunningPlanOut.self, "plan")
        let plan = try #require(out.plan)
        #expect(plan.goal == "first_5k")
        #expect(plan.weeks.count == 8)
        #expect(plan.daysPerWeek == 3)
        #expect(plan.startBasis == "user_provided")
        #expect(plan.startWeeklyKm == 10)
        #expect(plan.weeks[0].sessions.count == 3)
        #expect(plan.weeks[0].sessions.last?.kind == "long")
        #expect(plan.weeks.contains { $0.downWeek })
        #expect(!plan.rules.isEmpty && !plan.assumptions.isEmpty && !plan.notes.isEmpty)
        let assumed = try #require(try Fixtures.decode(RunningPlanOut.self, "plan_10k_assumed").plan)
        #expect(assumed.startBasis == "assumed")
        #expect(assumed.weeks.last?.taper == true)
    }

    @Test func syncResult() throws {
        let r = try Fixtures.decode(FitnessSyncResult.self, "sync_out")
        #expect(r.daysCreated == 3 && r.daysUpdated == 11)
        #expect(r.daysSent == 14 && r.workoutsSent == 2)
    }

    @Test func syncBodyUsesOnlyFieldsTheServerKnows() throws {
        let fields = try #require(try Fixtures.json("sync_in_fields") as? [String: [String]])
        let day = SyncDay(
            date: try #require(CalendarDate("2026-11-12")), steps: 8421, walkingRunningDistanceM: 6120.5, cyclingDistanceM: 0,
            activeEnergyKcal: 412, exerciseMinutes: 38, restingHeartRateBpm: 58, avgHeartRateBpm: 74, sleepMinutes: 402,
            bodyMassKg: 70, sources: ["Apple Watch"])
        let start = try #require(ZoroJSON.parseDate("2026-11-12T06:10:00+05:30"))
        let workout = SyncWorkout(
            id: "hk", type: "running", startAt: start, endAt: start.addingTimeInterval(1930), durationS: 1930, distanceM: 5020,
            activeEnergyKcal: 331, avgHeartRateBpm: 152, avgPaceSPerKm: 384.5, source: "Apple Watch")
        let payload = FitnessSyncPayload(generatedAt: start, days: [day], workouts: [workout])
        let object = try #require(try JSONSerialization.jsonObject(with: ZoroJSON.encoder().encode(payload)) as? [String: Any])
        #expect(Set(object.keys).isSubset(of: Set(fields["SyncIn"] ?? [])))
        let days = try #require(object["days"] as? [[String: Any]])
        #expect(Set(days[0].keys) == Set(fields["DayIn"] ?? []))
        let workouts = try #require(object["workouts"] as? [[String: Any]])
        #expect(Set(workouts[0].keys) == Set(fields["WorkoutIn"] ?? []))
        #expect(days[0]["date"] as? String == "2026-11-12")
    }

    @Test func emptyReadingsAreOmittedNotZeroed() throws {
        let day = SyncDay(date: try #require(CalendarDate("2026-11-12")), steps: 100)
        let object = try #require(try JSONSerialization.jsonObject(with: ZoroJSON.encoder().encode(day)) as? [String: Any])
        #expect(object["steps"] as? Double == 100)
        #expect(object["sleep_minutes"] == nil)
        #expect(object["body_mass_kg"] == nil)
    }

    @Test func observationSentencesMatchTheServerWords() throws {
        let cases = try #require(try Fixtures.json("observation_sentences") as? [String: [String: Any]])
        #expect(cases.count == 4)
        for (code, entry) in cases {
            let values = try #require(entry["values"] as? [String: Double])
            let expected = try #require(entry["en"] as? String)
            #expect(ObservationText.sentence(for: FitnessObservation(code: code, values: values)) == expected, "\(code) drifted from the server")
        }
        #expect(ObservationText.sentence(for: FitnessObservation(code: "something_new", values: [:])) == nil)
        #expect(ObservationText.sentence(for: FitnessObservation(code: "load_up", values: [:])) == nil)
    }

    @Test func nothingMedicalInTheWording() throws {
        let banned = ["diagnos", "disease", "medication", "treat", "doctor", "condition"]
        let cases = try #require(try Fixtures.json("observation_sentences") as? [String: [String: Any]])
        for entry in cases.values {
            let text = (entry["en"] as? String ?? "").lowercased()
            for word in banned { #expect(!text.contains(word)) }
        }
        #expect(FitnessCardModel.disclaimer == "Fitness information, not medical advice.")
    }
}

@Suite("Fitness cards")
struct FitnessCardTests {
    let now = ZoroJSON.parseDate("2026-11-13T12:00:00Z")!

    @Test func dailyCard() throws {
        let m = try FitnessCardModel(card: Fixtures.card("card_daily"), now: now)
        #expect(m.title == "Today")
        #expect(m.rows.map(\.label) == ["Steps", "Distance", "Active energy", "Exercise", "Resting heart rate", "Sleep"])
        #expect(m.rows[0].value == "8,421")
        #expect(m.rows[1].value == "6.1 km")
        #expect(m.rows[5].value == "6.7 h")
        #expect(m.observations.count == 2)
        #expect(m.sourceLine == "From Apple Health (synced from your iPhone), synced 2 hours ago.")
        #expect(m.staleNote == nil)
    }

    @Test func weeklyCardShowsChangeAgainstLastWeek() throws {
        let m = try FitnessCardModel(card: Fixtures.card("card_weekly"), now: now)
        #expect(m.rows[0].detail == "Up 20.1% on last week (7,010.3 before)")
        #expect(m.rows[1].detail?.hasPrefix("Down 5.6% on last week") == true)
    }

    @Test func recordsCardShowsDates() throws {
        let m = try FitnessCardModel(card: Fixtures.card("card_records"), now: now)
        #expect(m.rows[0].label == "Longest run")
        #expect(m.rows[0].value == "10.4 km")
        #expect(m.rows[0].detail == "4 Nov 2026")
    }

    @Test func runningCardKeepsServerPaceText() throws {
        let m = try FitnessCardModel(card: Fixtures.card("card_running"), now: now)
        #expect(m.rows.map(\.label) == ["Runs", "Distance", "Average pace"])
        #expect(m.rows[2].value == "6:32 per km")
    }

    @Test func planCardSummarisesThePlan() throws {
        let m = try FitnessCardModel(card: Fixtures.card("card_plan"), now: now)
        let line = try #require(m.planLine)
        #expect(line.hasPrefix("8-week plan toward 5 km, 3 runs a week."))
        #expect(line.contains("the figure you gave"))
    }

    @Test func staleCardWarns() throws {
        let m = try FitnessCardModel(card: Fixtures.card("card_stale"), now: now)
        #expect(m.staleNote == "This may be out of date. Tap Sync now for current figures.")
        #expect(m.sourceLine.contains("synced 4 days ago") || m.sourceLine.contains("synced 3 days ago"))
    }

    @Test func otherCardsAreRefused() {
        #expect(throws: ZoroError.self) { try FitnessCardModel(card: UICard(kind: "music"), now: now) }
    }
}
