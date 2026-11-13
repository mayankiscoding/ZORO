import Foundation
import ZoroCore

// Mirrors backend/app/fitness (results.py, schemas.py, plans.py, service.py). Snake_case on the wire,
// explicit CodingKeys. Every measurement may be null: nothing is estimated.

/// How old the data behind an answer is (`Freshness`).
public struct FitnessFreshness: Sendable, Equatable, Codable {
    public enum Unit: String, Sendable, Codable, CaseIterable { case minutes, hours, days }

    public var lastSyncedAt: Date?
    public var latestDataDate: CalendarDate?
    public var ageValue: Int?
    public var ageUnit: Unit?
    /// Older than 36 hours, or never synced.
    public var stale: Bool

    public init(lastSyncedAt: Date? = nil, latestDataDate: CalendarDate? = nil, ageValue: Int? = nil, ageUnit: Unit? = nil, stale: Bool = true) {
        self.lastSyncedAt = lastSyncedAt
        self.latestDataDate = latestDataDate
        self.ageValue = ageValue
        self.ageUnit = ageUnit
        self.stale = stale
    }

    enum CodingKeys: String, CodingKey {
        case lastSyncedAt = "last_synced_at"
        case latestDataDate = "latest_data_date"
        case ageValue = "age_value"
        case ageUnit = "age_unit"
        case stale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        latestDataDate = try c.decodeIfPresent(CalendarDate.self, forKey: .latestDataDate)
        ageValue = try c.decodeIfPresent(Int.self, forKey: .ageValue)
        ageUnit = try c.decodeIfPresent(Unit.self, forKey: .ageUnit)
        stale = try c.value(.stale, default: true)
    }

    /// True when nothing has ever been synced.
    public var neverSynced: Bool { lastSyncedAt == nil }
}

/// A recovery observation: a code plus numbers. The sentence is built by `ObservationText`.
public struct FitnessObservation: Sendable, Equatable, Codable {
    public var code: String
    public var values: [String: Double]
    public init(code: String, values: [String: Double] = [:]) {
        self.code = code
        self.values = values
    }
    enum CodingKeys: String, CodingKey { case code, values }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        values = try c.value(.values, default: [:])
    }
}

/// The fields every tool answer carries (`Sourced`): where the data came from and how fresh it is.
public struct FitnessSourcing: Sendable, Equatable, Decodable {
    public var available: Bool
    /// `never_synced`, `no_data_for_date`, `no_data_in_window`, `not_enough_data`, `no_running_data`.
    public var reason: String?
    public var dataSource: String
    public var devices: [String]
    public var freshness: FitnessFreshness
    public var externalModelAllowed: Bool
    public var observations: [FitnessObservation]

    public init(
        available: Bool = true, reason: String? = nil, dataSource: String = "Apple Health (synced from your iPhone)",
        devices: [String] = [], freshness: FitnessFreshness = FitnessFreshness(), externalModelAllowed: Bool = true,
        observations: [FitnessObservation] = []
    ) {
        self.available = available
        self.reason = reason
        self.dataSource = dataSource
        self.devices = devices
        self.freshness = freshness
        self.externalModelAllowed = externalModelAllowed
        self.observations = observations
    }

    enum CodingKeys: String, CodingKey {
        case available, reason
        case dataSource = "data_source"
        case devices, freshness
        case externalModelAllowed = "external_model_allowed"
        case observations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.value(.available, default: true)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        dataSource = try c.value(.dataSource, default: "Apple Health (synced from your iPhone)")
        devices = try c.value(.devices, default: [])
        freshness = try c.value(.freshness, default: FitnessFreshness())
        externalModelAllowed = try c.value(.externalModelAllowed, default: true)
        observations = try c.value(.observations, default: [])
    }
}

public protocol FitnessSourced {
    var sourcing: FitnessSourcing { get }
}

public struct WorkoutBrief: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var type: String
    /// Local ISO time as the server wrote it, without conversion.
    public var startAt: String
    public var durationMin: Double?
    public var distanceKm: Double?
    public var paceText: String?
    public var avgHeartRateBpm: Int?
    public var origin: String

    enum CodingKeys: String, CodingKey {
        case id, type
        case startAt = "start_at"
        case durationMin = "duration_min"
        case distanceKm = "distance_km"
        case paceText = "pace_text"
        case avgHeartRateBpm = "avg_heart_rate_bpm"
        case origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        startAt = try c.decode(String.self, forKey: .startAt)
        durationMin = try c.decodeIfPresent(Double.self, forKey: .durationMin)
        distanceKm = try c.decodeIfPresent(Double.self, forKey: .distanceKm)
        paceText = try c.decodeIfPresent(String.self, forKey: .paceText)
        avgHeartRateBpm = try c.decodeIfPresent(Int.self, forKey: .avgHeartRateBpm)
        origin = try c.value(.origin, default: "healthkit")
    }

    public init(
        id: String, type: String, startAt: String, durationMin: Double? = nil, distanceKm: Double? = nil, paceText: String? = nil,
        avgHeartRateBpm: Int? = nil, origin: String = "healthkit"
    ) {
        self.id = id
        self.type = type
        self.startAt = startAt
        self.durationMin = durationMin
        self.distanceKm = distanceKm
        self.paceText = paceText
        self.avgHeartRateBpm = avgHeartRateBpm
        self.origin = origin
    }
}

/// `GET /v1/fitness/summary`.
public struct DailySummary: Sendable, Equatable, Decodable, FitnessSourced {
    public var sourcing: FitnessSourcing
    public var date: CalendarDate
    public var steps: Int?
    public var distanceKm: Double?
    public var cyclingKm: Double?
    public var activeEnergyKcal: Int?
    public var exerciseMinutes: Int?
    public var restingHeartRateBpm: Int?
    public var avgHeartRateBpm: Int?
    public var sleepHours: Double?
    public var bodyMassKg: Double?
    public var workouts: [WorkoutBrief]

    enum CodingKeys: String, CodingKey {
        case date, steps
        case distanceKm = "distance_km"
        case cyclingKm = "cycling_km"
        case activeEnergyKcal = "active_energy_kcal"
        case exerciseMinutes = "exercise_minutes"
        case restingHeartRateBpm = "resting_heart_rate_bpm"
        case avgHeartRateBpm = "avg_heart_rate_bpm"
        case sleepHours = "sleep_hours"
        case bodyMassKg = "body_mass_kg"
        case workouts
    }

    public init(from decoder: Decoder) throws {
        sourcing = try FitnessSourcing(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(CalendarDate.self, forKey: .date)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        distanceKm = try c.decodeIfPresent(Double.self, forKey: .distanceKm)
        cyclingKm = try c.decodeIfPresent(Double.self, forKey: .cyclingKm)
        activeEnergyKcal = try c.decodeIfPresent(Int.self, forKey: .activeEnergyKcal)
        exerciseMinutes = try c.decodeIfPresent(Int.self, forKey: .exerciseMinutes)
        restingHeartRateBpm = try c.decodeIfPresent(Int.self, forKey: .restingHeartRateBpm)
        avgHeartRateBpm = try c.decodeIfPresent(Int.self, forKey: .avgHeartRateBpm)
        sleepHours = try c.decodeIfPresent(Double.self, forKey: .sleepHours)
        bodyMassKg = try c.decodeIfPresent(Double.self, forKey: .bodyMassKg)
        workouts = try c.value(.workouts, default: [])
    }
}

public struct MetricComparison: Sendable, Equatable, Decodable, Identifiable {
    public var metric: String
    public var unit: String
    public var currentAvg: Double?
    public var previousAvg: Double?
    public var currentTotal: Double?
    public var previousTotal: Double?
    public var changePct: Double?
    public var daysCurrent: Int
    public var daysPrevious: Int
    public var enoughData: Bool
    public var id: String { metric }

    enum CodingKeys: String, CodingKey {
        case metric, unit
        case currentAvg = "current_avg"
        case previousAvg = "previous_avg"
        case currentTotal = "current_total"
        case previousTotal = "previous_total"
        case changePct = "change_pct"
        case daysCurrent = "days_current"
        case daysPrevious = "days_previous"
        case enoughData = "enough_data"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metric = try c.decode(String.self, forKey: .metric)
        unit = try c.decode(String.self, forKey: .unit)
        currentAvg = try c.decodeIfPresent(Double.self, forKey: .currentAvg)
        previousAvg = try c.decodeIfPresent(Double.self, forKey: .previousAvg)
        currentTotal = try c.decodeIfPresent(Double.self, forKey: .currentTotal)
        previousTotal = try c.decodeIfPresent(Double.self, forKey: .previousTotal)
        changePct = try c.decodeIfPresent(Double.self, forKey: .changePct)
        daysCurrent = try c.value(.daysCurrent, default: 0)
        daysPrevious = try c.value(.daysPrevious, default: 0)
        enoughData = try c.value(.enoughData, default: false)
    }
}

/// `GET /v1/fitness/weekly`: the last seven days against the seven before.
public struct WeeklyComparison: Sendable, Equatable, Decodable, FitnessSourced {
    public var sourcing: FitnessSourcing
    public var currentStart: CalendarDate?
    public var currentEnd: CalendarDate?
    public var previousStart: CalendarDate?
    public var previousEnd: CalendarDate?
    public var metrics: [MetricComparison]
    public var workoutsCurrent: Int
    public var workoutsPrevious: Int

    enum CodingKeys: String, CodingKey {
        case currentStart = "current_start"
        case currentEnd = "current_end"
        case previousStart = "previous_start"
        case previousEnd = "previous_end"
        case metrics
        case workoutsCurrent = "workouts_current"
        case workoutsPrevious = "workouts_previous"
    }

    public init(from decoder: Decoder) throws {
        sourcing = try FitnessSourcing(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentStart = try c.decodeIfPresent(CalendarDate.self, forKey: .currentStart)
        currentEnd = try c.decodeIfPresent(CalendarDate.self, forKey: .currentEnd)
        previousStart = try c.decodeIfPresent(CalendarDate.self, forKey: .previousStart)
        previousEnd = try c.decodeIfPresent(CalendarDate.self, forKey: .previousEnd)
        metrics = try c.value(.metrics, default: [])
        workoutsCurrent = try c.value(.workoutsCurrent, default: 0)
        workoutsPrevious = try c.value(.workoutsPrevious, default: 0)
    }
}

/// `GET /v1/fitness/trends`: a direction and a slope. The server sends no daily series.
public struct TrendResult: Sendable, Equatable, Decodable, FitnessSourced {
    public enum Direction: String, Sendable, Decodable, CaseIterable {
        case up, down, steady
        case insufficientData = "insufficient_data"
    }

    public var sourcing: FitnessSourcing
    public var metric: String
    public var unit: String
    public var windowStart: CalendarDate?
    public var windowEnd: CalendarDate?
    public var pointsUsed: Int
    public var minPoints: Int
    public var slopePerWeek: Double?
    public var mean: Double?
    public var direction: Direction

    enum CodingKeys: String, CodingKey {
        case metric, unit
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case pointsUsed = "points_used"
        case minPoints = "min_points"
        case slopePerWeek = "slope_per_week"
        case mean, direction
    }

    public init(from decoder: Decoder) throws {
        sourcing = try FitnessSourcing(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metric = try c.value(.metric, default: "")
        unit = try c.value(.unit, default: "")
        windowStart = try c.decodeIfPresent(CalendarDate.self, forKey: .windowStart)
        windowEnd = try c.decodeIfPresent(CalendarDate.self, forKey: .windowEnd)
        pointsUsed = try c.value(.pointsUsed, default: 0)
        minPoints = try c.value(.minPoints, default: 7)
        slopePerWeek = try c.decodeIfPresent(Double.self, forKey: .slopePerWeek)
        mean = try c.decodeIfPresent(Double.self, forKey: .mean)
        direction = (try? c.decode(Direction.self, forKey: .direction)) ?? .insufficientData
    }
}

public struct WeeklyKm: Sendable, Equatable, Decodable, Identifiable {
    public var weekStart: CalendarDate
    public var km: Double
    public var runs: Int
    public var id: CalendarDate { weekStart }
    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case km, runs
    }
}

/// `GET /v1/fitness/running`.
public struct RunningProgress: Sendable, Equatable, Decodable, FitnessSourced {
    public enum Direction: String, Sendable, Decodable, CaseIterable {
        case faster, slower, steady
        case insufficientData = "insufficient_data"
    }

    public var sourcing: FitnessSourcing
    public var windowStart: CalendarDate?
    public var windowEnd: CalendarDate?
    public var runs: Int
    public var totalKm: Double
    public var avgPaceSPerKm: Double?
    public var avgPaceText: String?
    public var recentPaceText: String?
    public var paceChangeSPerKmPerWeek: Double?
    public var direction: Direction
    public var minRuns: Int
    public var weekly: [WeeklyKm]

    enum CodingKeys: String, CodingKey {
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case runs
        case totalKm = "total_km"
        case avgPaceSPerKm = "avg_pace_s_per_km"
        case avgPaceText = "avg_pace_text"
        case recentPaceText = "recent_pace_text"
        case paceChangeSPerKmPerWeek = "pace_change_s_per_km_per_week"
        case direction
        case minRuns = "min_runs"
        case weekly
    }

    public init(from decoder: Decoder) throws {
        sourcing = try FitnessSourcing(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowStart = try c.decodeIfPresent(CalendarDate.self, forKey: .windowStart)
        windowEnd = try c.decodeIfPresent(CalendarDate.self, forKey: .windowEnd)
        runs = try c.value(.runs, default: 0)
        totalKm = try c.value(.totalKm, default: 0)
        avgPaceSPerKm = try c.decodeIfPresent(Double.self, forKey: .avgPaceSPerKm)
        avgPaceText = try c.decodeIfPresent(String.self, forKey: .avgPaceText)
        recentPaceText = try c.decodeIfPresent(String.self, forKey: .recentPaceText)
        paceChangeSPerKmPerWeek = try c.decodeIfPresent(Double.self, forKey: .paceChangeSPerKmPerWeek)
        direction = (try? c.decode(Direction.self, forKey: .direction)) ?? .insufficientData
        minRuns = try c.value(.minRuns, default: 4)
        weekly = try c.value(.weekly, default: [])
    }
}

public struct PersonalRecord: Sendable, Equatable, Decodable, Identifiable {
    /// `longest_run`, `fastest_pace_run`, `longest_workout`, `most_steps_day`, `most_exercise_day`, `most_active_energy_day`.
    public var kind: String
    public var value: Double
    public var unit: String
    /// The exact figure to show ("10.4", "5:12").
    public var display: String
    public var on: CalendarDate
    public var workoutId: String?
    public var source: String?
    public var id: String { kind }

    enum CodingKeys: String, CodingKey {
        case kind, value, unit, display, on
        case workoutId = "workout_id"
        case source
    }
}

/// `GET /v1/fitness/records`.
public struct PersonalRecords: Sendable, Equatable, Decodable, FitnessSourced {
    public var sourcing: FitnessSourcing
    public var records: [PersonalRecord]
    public var note: String

    enum CodingKeys: String, CodingKey { case records, note }

    public init(from decoder: Decoder) throws {
        sourcing = try FitnessSourcing(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.value(.records, default: [])
        note = try c.value(.note, default: "")
    }
}

public struct WeekSessions: Sendable, Equatable, Decodable, Identifiable {
    public var weekStart: CalendarDate
    public var sessions: Int
    public var activeDays: Int
    public var id: CalendarDate { weekStart }
    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case sessions
        case activeDays = "active_days"
    }
}

/// `GET /v1/fitness/consistency`.
public struct Consistency: Sendable, Equatable, Decodable, FitnessSourced {
    public var sourcing: FitnessSourcing
    public var windowStart: CalendarDate?
    public var windowEnd: CalendarDate?
    public var minActiveMinutes: Int
    public var daysWithData: Int
    public var activeDays: Int
    public var currentStreakDays: Int
    public var longestStreakDays: Int
    public var avgSessionsPerWeek: Double?
    public var targetSessionsPerWeek: Int
    public var weeksMeetingTarget: Int
    public var weeks: [WeekSessions]

    enum CodingKeys: String, CodingKey {
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case minActiveMinutes = "min_active_minutes"
        case daysWithData = "days_with_data"
        case activeDays = "active_days"
        case currentStreakDays = "current_streak_days"
        case longestStreakDays = "longest_streak_days"
        case avgSessionsPerWeek = "avg_sessions_per_week"
        case targetSessionsPerWeek = "target_sessions_per_week"
        case weeksMeetingTarget = "weeks_meeting_target"
        case weeks
    }

    public init(from decoder: Decoder) throws {
        sourcing = try FitnessSourcing(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowStart = try c.decodeIfPresent(CalendarDate.self, forKey: .windowStart)
        windowEnd = try c.decodeIfPresent(CalendarDate.self, forKey: .windowEnd)
        minActiveMinutes = try c.value(.minActiveMinutes, default: 20)
        daysWithData = try c.value(.daysWithData, default: 0)
        activeDays = try c.value(.activeDays, default: 0)
        currentStreakDays = try c.value(.currentStreakDays, default: 0)
        longestStreakDays = try c.value(.longestStreakDays, default: 0)
        avgSessionsPerWeek = try c.decodeIfPresent(Double.self, forKey: .avgSessionsPerWeek)
        targetSessionsPerWeek = try c.value(.targetSessionsPerWeek, default: 3)
        weeksMeetingTarget = try c.value(.weeksMeetingTarget, default: 0)
        weeks = try c.value(.weeks, default: [])
    }
}

// MARK: - Running plan

public struct PlanSession: Sendable, Equatable, Decodable, Identifiable {
    /// `mon`...`sun`.
    public var day: String
    /// `easy`, `long`, `steady`.
    public var kind: String
    public var distanceKm: Double
    public var effort: String
    public var id: String { day }
    enum CodingKeys: String, CodingKey {
        case day, kind
        case distanceKm = "distance_km"
        case effort
    }
}

public struct PlanWeek: Sendable, Equatable, Decodable, Identifiable {
    public var week: Int
    public var totalKm: Double
    public var downWeek: Bool
    public var taper: Bool
    public var sessions: [PlanSession]
    public var id: Int { week }
    enum CodingKeys: String, CodingKey {
        case week
        case totalKm = "total_km"
        case downWeek = "down_week"
        case taper, sessions
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = try c.decode(Int.self, forKey: .week)
        totalKm = try c.decode(Double.self, forKey: .totalKm)
        downWeek = try c.value(.downWeek, default: false)
        taper = try c.value(.taper, default: false)
        sessions = try c.decode([PlanSession].self, forKey: .sessions)
    }
}

public struct RunningPlan: Sendable, Equatable, Decodable {
    /// `first_5k`, `5k`, `10k`, `half_marathon`.
    public var goal: String
    public var raceKm: Double
    public var weeks: [PlanWeek]
    public var daysPerWeek: Int
    public var startWeeklyKm: Double
    /// `user_provided`, `synced_runs`, `assumed`.
    public var startBasis: String
    public var reachesTargetDistance: Bool
    public var rules: [String]
    public var assumptions: [String]
    public var notes: [String]

    enum CodingKeys: String, CodingKey {
        case goal
        case raceKm = "race_km"
        case weeks
        case daysPerWeek = "days_per_week"
        case startWeeklyKm = "start_weekly_km"
        case startBasis = "start_basis"
        case reachesTargetDistance = "reaches_target_distance"
        case rules, assumptions, notes
    }
}

/// `POST /v1/fitness/running-plan`.
public struct RunningPlanOut: Sendable, Equatable, Decodable, FitnessSourced {
    public var sourcing: FitnessSourcing
    public var plan: RunningPlan?

    enum CodingKeys: String, CodingKey { case plan }

    public init(from decoder: Decoder) throws {
        sourcing = try FitnessSourcing(from: decoder)
        plan = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(RunningPlan.self, forKey: .plan)
    }
}
