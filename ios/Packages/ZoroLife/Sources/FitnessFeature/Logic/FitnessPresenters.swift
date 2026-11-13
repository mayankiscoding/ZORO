import Foundation
import LifeSupport
import ZoroCore

/// One figure on a card: label, value text and unit, with the sentence VoiceOver reads.
public struct FigureTile: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    /// "8,421", or "Not recorded" when the device had no reading. Never a made-up zero.
    public var value: String
    public var unit: String?
    public var isMissing: Bool

    public init(id: String, label: String, value: String, unit: String? = nil, isMissing: Bool = false) {
        self.id = id
        self.label = label
        self.value = value
        self.unit = unit
        self.isMissing = isMissing
    }

    public var accessibilityLabel: String {
        isMissing ? "\(label), not recorded" : "\(label), \(value)" + (unit.map { " \($0)" } ?? "")
    }
}

public enum TodayPresenter {
    /// The figures the device recorded. Missing ones are left out; `missingNote` names them.
    public static func tiles(_ s: DailySummary) -> [FigureTile] {
        var out: [FigureTile] = []
        func add(_ id: String, _ label: String, _ value: String?, _ unit: String?) {
            if let value { out.append(FigureTile(id: id, label: label, value: value, unit: unit)) }
        }
        add("steps", "Steps", s.steps.map(LifeFormat.count), nil)
        add("distance", "Distance", s.distanceKm.map { LifeFormat.number($0, places: 2) }, "km")
        add("energy", "Active energy", s.activeEnergyKcal.map(LifeFormat.count), "kcal")
        add("exercise", "Exercise", s.exerciseMinutes.map(LifeFormat.count), "min")
        add("rhr", "Resting heart rate", s.restingHeartRateBpm.map(LifeFormat.count), "bpm")
        add("sleep", "Sleep", s.sleepHours.map { LifeFormat.number($0, places: 1) }, "h")
        add("weight", "Body weight", s.bodyMassKg.map { LifeFormat.number($0, places: 1) }, "kg")
        add("cycling", "Cycling", s.cyclingKm.map { LifeFormat.number($0, places: 2) }, "km")
        return out
    }

    /// "No reading yet for distance and sleep." or nil when everything the card shows is present.
    public static func missingNote(_ s: DailySummary) -> String? {
        var names: [String] = []
        if s.steps == nil { names.append("steps") }
        if s.distanceKm == nil { names.append("distance") }
        if s.activeEnergyKcal == nil { names.append("active energy") }
        if s.exerciseMinutes == nil { names.append("exercise") }
        if s.sleepHours == nil { names.append("sleep") }
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "No reading yet for \(list). Your iPhone or watch has not recorded it, or Health access for it is off."
    }

    /// "Running, 5.02 km, 6:24 per km".
    public static func workoutLine(_ w: WorkoutBrief) -> String {
        var parts = [w.type.prefix(1).uppercased() + w.type.dropFirst()]
        if let km = w.distanceKm { parts.append("\(LifeFormat.number(km, places: 2)) km") }
        if let min = w.durationMin { parts.append("\(LifeFormat.number(min, places: 0)) min") }
        if let pace = w.paceText { parts.append("\(pace) per km") }
        return parts.joined(separator: ", ")
    }
}

public struct ComparisonRow: Sendable, Equatable, Identifiable {
    public enum Direction: Sendable, Equatable { case up, down, same, unknown }
    public var id: String
    public var label: String
    /// "8,421 steps a day"
    public var current: String
    /// "Last week 7,010"
    public var previous: String
    /// "Up 20.1% on last week", "Not enough days to compare yet."
    public var change: String
    public var direction: Direction

    public var accessibilityLabel: String { "\(label). This week \(current). \(previous). \(change)" }
}

public enum WeeklyPresenter {
    static let labels: [String: String] = [
        "steps": "Steps", "exercise_minutes": "Exercise", "active_energy_kcal": "Active energy", "sleep_hours": "Sleep",
        "resting_heart_rate_bpm": "Resting heart rate", "body_mass_kg": "Body weight", "distance_km": "Distance",
    ]

    public static func label(for metric: String) -> String {
        labels[metric] ?? metric.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }

    static func unitText(_ unit: String) -> String {
        switch unit {
        case "steps": "steps"
        case "minutes": "min"
        case "hours": "h"
        default: unit
        }
    }

    public static func rows(_ w: WeeklyComparison) -> [ComparisonRow] {
        w.metrics.map { m in
            let unit = unitText(m.unit)
            func value(_ v: Double?) -> String? {
                v.map { LifeFormat.number($0, places: m.unit == "steps" || m.unit == "kcal" ? 0 : 1) }
            }
            guard m.enoughData, let cur = value(m.currentAvg), let prev = value(m.previousAvg) else {
                return ComparisonRow(
                    id: m.metric, label: label(for: m.metric), current: "Not enough days", previous: "Last week: not enough days",
                    change:
                        "Not enough days to compare yet. This week has \(dayCount(m.daysCurrent)) of data and last week \(dayCount(m.daysPrevious)).",
                    direction: .unknown)
            }
            let change: String
            let direction: ComparisonRow.Direction
            if let pct = m.changePct {
                let text = LifeFormat.number(abs(pct), places: 1)
                if Double(text) == 0 {
                    (change, direction) = ("About the same as last week", .same)
                } else if pct > 0 {
                    (change, direction) = ("Up \(text)% on last week", .up)
                } else {
                    (change, direction) = ("Down \(text)% on last week", .down)
                }
            } else {
                (change, direction) = ("No change figure, because last week's average was zero", .unknown)
            }
            return ComparisonRow(
                id: m.metric, label: label(for: m.metric), current: "\(cur) \(unit) a day", previous: "Last week \(prev)",
                change: change, direction: direction)
        }
    }

    static func dayCount(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    /// "Workouts: 4 this week, 3 last week."
    public static func workoutsLine(_ w: WeeklyComparison) -> String {
        "Workouts: \(w.workoutsCurrent) this week, \(w.workoutsPrevious) last week."
    }

    /// "13 Nov to 19 Nov, against 6 Nov to 12 Nov".
    public static func rangeLine(_ w: WeeklyComparison) -> String? {
        guard let cs = w.currentStart, let ce = w.currentEnd, let ps = w.previousStart, let pe = w.previousEnd else { return nil }
        return "\(LifeFormat.shortDay(cs)) to \(LifeFormat.shortDay(ce)), against \(LifeFormat.shortDay(ps)) to \(LifeFormat.shortDay(pe))"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The metrics `/v1/fitness/trends` accepts.
public enum TrendMetric: String, Sendable, CaseIterable, Identifiable {
    case steps
    case exerciseMinutes = "exercise_minutes"
    case activeEnergy = "active_energy_kcal"
    case sleepHours = "sleep_hours"
    case restingHeartRate = "resting_heart_rate_bpm"
    case bodyMass = "body_mass_kg"
    case distance = "distance_km"

    public var id: String { rawValue }
    public var title: String { WeeklyPresenter.label(for: rawValue) }
}

public struct TrendSummary: Sendable, Equatable {
    public var headline: String
    public var detail: String
    public var symbol: String
}

public enum TrendPresenter {
    public static func summary(_ t: TrendResult) -> TrendSummary {
        let name = WeeklyPresenter.label(for: t.metric)
        let unit = WeeklyPresenter.unitText(t.unit)
        guard t.sourcing.available, t.direction != .insufficientData else {
            return TrendSummary(
                headline: "Not enough data for \(name.lowercased()) yet",
                detail: "\(t.pointsUsed) of \(t.minPoints) days needed. " + FitnessUnavailableText.sentence(reason: t.sourcing.reason ?? "not_enough_data"),
                symbol: "ellipsis")
        }
        let places = t.unit == "steps" || t.unit == "kcal" ? 0 : 1
        let slope = t.slopePerWeek ?? 0
        let slopeText = LifeFormat.number(abs(slope), places: places)
        var detail = "Based on \(t.pointsUsed) days."
        if let mean = t.mean { detail = "Average \(LifeFormat.number(mean, places: places)) \(unit). " + detail }
        switch t.direction {
        case .up:
            return TrendSummary(headline: "\(name): going up by about \(slopeText) \(unit) a week", detail: detail, symbol: "arrow.up.right")
        case .down:
            return TrendSummary(headline: "\(name): going down by about \(slopeText) \(unit) a week", detail: detail, symbol: "arrow.down.right")
        default:
            return TrendSummary(headline: "\(name): steady", detail: detail, symbol: "arrow.right")
        }
    }
}

public struct FigureBar: Sendable, Equatable, Identifiable {
    public var id: String
    /// Full label for VoiceOver: "Week of 13 Nov".
    public var label: String
    /// Axis label: "13 Nov".
    public var shortLabel: String
    /// Plotting position only; the text shown is `valueText`.
    public var value: Double
    public var valueText: String
}

public enum RunningPresenter {
    public static func tiles(_ r: RunningProgress) -> [FigureTile] {
        var out = [
            FigureTile(id: "runs", label: "Runs", value: LifeFormat.count(r.runs)),
            FigureTile(id: "distance", label: "Distance", value: LifeFormat.number(r.totalKm, places: 1), unit: "km"),
        ]
        if let pace = r.avgPaceText { out.append(FigureTile(id: "pace", label: "Average pace", value: pace, unit: "per km")) }
        if let recent = r.recentPaceText { out.append(FigureTile(id: "recent", label: "Last three runs", value: recent, unit: "per km")) }
        return out
    }

    /// The pace trend in words. Needs `min_runs` runs; with fewer it says how many more.
    public static func paceSentence(_ r: RunningProgress) -> String {
        switch r.direction {
        case .insufficientData:
            let missing = max(r.minRuns - r.runs, 0)
            return "Pace trend needs at least \(r.minRuns) runs. You have \(r.runs)"
                + (missing > 0 ? "; \(missing) more and it will show here." : ".")
        case .steady:
            return "Your pace is steady."
        case .faster, .slower:
            let seconds = LifeFormat.number(abs(r.paceChangeSPerKmPerWeek ?? 0), places: 0)
            let word = r.direction == .faster ? "faster" : "slower"
            return "Your pace is getting \(word): about \(seconds) seconds per km \(word == "faster" ? "quicker" : "slower") each week."
        }
    }

    public static func weeklyBars(_ r: RunningProgress) -> [FigureBar] {
        r.weekly.map {
            FigureBar(
                id: $0.weekStart.description, label: "Week of \(LifeFormat.shortDay($0.weekStart))",
                shortLabel: LifeFormat.shortDay($0.weekStart), value: $0.km,
                valueText: "\(LifeFormat.number($0.km, places: 1)) km in \($0.runs) \($0.runs == 1 ? "run" : "runs")")
        }
    }
}

public enum RecordsPresenter {
    static let labels: [String: String] = [
        "longest_run": "Longest run", "fastest_pace_run": "Fastest run pace", "longest_workout": "Longest workout",
        "most_steps_day": "Most steps in a day", "most_exercise_day": "Most exercise in a day",
        "most_active_energy_day": "Most active energy in a day",
    ]

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var value: String
        public var detail: String
        public var accessibilityLabel: String { "\(label), \(value), on \(detail)" }
    }

    public static func rows(_ r: PersonalRecords) -> [Row] {
        r.records.map { rec in
            let label = labels[rec.kind] ?? rec.kind.replacingOccurrences(of: "_", with: " ").capitalizedFirst
            var detail = LifeFormat.fullDay(rec.on)
            if let source = rec.source { detail += ", \(source)" }
            return Row(id: rec.kind, label: label, value: rec.unit.isEmpty ? rec.display : "\(rec.display) \(rec.unit)", detail: detail)
        }
    }
}

public enum ConsistencyPresenter {
    public static func tiles(_ c: Consistency) -> [FigureTile] {
        var out = [
            FigureTile(id: "active", label: "Active days", value: "\(c.activeDays) of \(c.daysWithData)", unit: "days with data"),
            FigureTile(id: "streak", label: "Current streak", value: LifeFormat.count(c.currentStreakDays), unit: c.currentStreakDays == 1 ? "day" : "days"),
            FigureTile(id: "longest", label: "Longest streak", value: LifeFormat.count(c.longestStreakDays), unit: c.longestStreakDays == 1 ? "day" : "days"),
        ]
        if let avg = c.avgSessionsPerWeek {
            out.append(FigureTile(id: "sessions", label: "Sessions per week", value: LifeFormat.number(avg, places: 1), unit: "target \(c.targetSessionsPerWeek)"))
        }
        return out
    }

    public static func summary(_ c: Consistency) -> String {
        "\(c.weeksMeetingTarget) of the last \(c.weeks.count) weeks reached \(c.targetSessionsPerWeek) sessions. A day counts as active with at least \(c.minActiveMinutes) minutes of exercise."
    }

    public static func weeklyBars(_ c: Consistency) -> [FigureBar] {
        c.weeks.map {
            FigureBar(
                id: $0.weekStart.description, label: "Week of \(LifeFormat.shortDay($0.weekStart))",
                shortLabel: LifeFormat.shortDay($0.weekStart), value: Double($0.sessions),
                valueText: "\($0.sessions) \($0.sessions == 1 ? "session" : "sessions")")
        }
    }
}

public enum SyncPresenter {
    /// "Sent 14 days and 2 workouts to your server."
    public static func summary(_ r: FitnessSyncResult) -> String {
        let days = r.daysSent, workouts = r.workoutsSent
        return "Sent \(days) \(days == 1 ? "day" : "days") and \(workouts) \(workouts == 1 ? "workout" : "workouts") to your server."
    }
}

public enum PlanPresenter {
    public static func goalTitle(_ goal: String) -> String {
        RunningGoal(rawValue: goal)?.title ?? goal
    }

    public static func startBasisSentence(_ plan: RunningPlan) -> String {
        let km = LifeFormat.number(plan.startWeeklyKm, places: 1)
        switch plan.startBasis {
        case "user_provided": return "Starts at \(km) km a week, the figure you gave."
        case "synced_runs": return "Starts at \(km) km a week, from your last four synced weeks."
        default: return "Starts at \(km) km a week. That is an assumption: no running volume was given or synced."
        }
    }

    public static func weekTitle(_ w: PlanWeek) -> String {
        var title = "Week \(w.week), \(LifeFormat.number(w.totalKm, places: 1)) km"
        if w.downWeek { title += ", lighter week" }
        if w.taper { title += ", race week" }
        return title
    }

    public static func sessionLine(_ s: PlanSession) -> String {
        let day = ["mon": "Monday", "tue": "Tuesday", "wed": "Wednesday", "thu": "Thursday", "fri": "Friday", "sat": "Saturday", "sun": "Sunday"][s.day] ?? s.day
        return "\(day): \(s.kind) run, \(LifeFormat.number(s.distanceKm, places: 1)) km. \(s.effort.capitalizedFirst)."
    }
}

/// Steps per day for the last seven days, read from Health on this device. Days with no reading are left out, not drawn as zero.
public enum DeviceWeekPresenter {
    public static func stepBars(_ week: HealthWeeklySummary, timeZone: TimeZone) -> [FigureBar] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let short = DateFormatter()
        short.locale = Locale(identifier: "en_IN")
        short.timeZone = timeZone
        short.setLocalizedDateFormatFromTemplate("EEE")
        let long = DateFormatter()
        long.locale = Locale(identifier: "en_IN")
        long.timeZone = timeZone
        long.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        return week.days.sorted { $0.date < $1.date }.compactMap { day in
            guard let steps = day.steps else { return nil }
            return FigureBar(
                id: CalendarDate(date: day.date, timeZone: timeZone).description, label: long.string(from: day.date),
                shortLabel: short.string(from: day.date), value: Double(steps), valueText: "\(LifeFormat.count(steps)) steps")
        }
    }

    /// "From Health on this iPhone, read 4:12 pm."
    public static func sourceLine(_ week: HealthWeeklySummary, now: Date, timeZone: TimeZone) -> String {
        "From \(week.source) on this device, read \(LifeFormat.moment(week.fetchedAt, now: now, timeZone: timeZone))."
    }
}
