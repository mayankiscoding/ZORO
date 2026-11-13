import Foundation
import ZoroCore

// Request and sync bodies (backend/app/fitness/api.py `PlanBody`, schemas.py `SyncIn`, `SyncOut`).

public enum RunningGoal: String, Sendable, Codable, CaseIterable, Identifiable {
    case first5k = "first_5k"
    case fiveK = "5k"
    case tenK = "10k"
    case halfMarathon = "half_marathon"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .first5k: "Run my first 5 km"
        case .fiveK: "Get faster over 5 km"
        case .tenK: "Run 10 km"
        case .halfMarathon: "Run a half marathon"
        }
    }

    /// "5 km", "21.1 km".
    public var distanceText: String {
        switch self {
        case .first5k, .fiveK: "5 km"
        case .tenK: "10 km"
        case .halfMarathon: "21.1 km"
        }
    }
}

/// The running-plan form, validated the way the server validates it (4...20 weeks, 2...6 days, 0...200 km).
public struct RunningPlanRequest: Sendable, Equatable, Encodable {
    public static let weeksRange = 4...20
    public static let daysRange = 2...6
    public static let weeklyKmRange = 0.0...200.0

    public var goal: RunningGoal
    /// nil = the goal's default length.
    public var weeks: Int?
    public var daysPerWeek: Int
    /// nil = use the runs already synced, or the server's stated assumption.
    public var currentWeeklyKm: Double?

    public init(goal: RunningGoal = .first5k, weeks: Int? = nil, daysPerWeek: Int = 3, currentWeeklyKm: Double? = nil) {
        self.goal = goal
        self.weeks = weeks
        self.daysPerWeek = daysPerWeek
        self.currentWeeklyKm = currentWeeklyKm
    }

    /// One sentence per problem, empty when the form is valid.
    public var problems: [String] {
        var out: [String] = []
        if let weeks, !Self.weeksRange.contains(weeks) { out.append("Choose between 4 and 20 weeks.") }
        if !Self.daysRange.contains(daysPerWeek) { out.append("Choose between 2 and 6 running days a week.") }
        if let currentWeeklyKm, !Self.weeklyKmRange.contains(currentWeeklyKm) || !currentWeeklyKm.isFinite {
            out.append("Enter your weekly distance as a number from 0 to 200 km.")
        }
        return out
    }

    enum CodingKeys: String, CodingKey {
        case goal, weeks
        case daysPerWeek = "days_per_week"
        case currentWeeklyKm = "current_weekly_km"
    }
}

// MARK: - Sync

public struct SyncDay: Sendable, Equatable, Encodable {
    public var date: CalendarDate
    public var steps: Double?
    public var walkingRunningDistanceM: Double?
    public var cyclingDistanceM: Double?
    public var activeEnergyKcal: Double?
    public var exerciseMinutes: Double?
    public var restingHeartRateBpm: Double?
    public var avgHeartRateBpm: Double?
    public var sleepMinutes: Double?
    public var bodyMassKg: Double?
    public var sources: [String]

    public init(
        date: CalendarDate, steps: Double? = nil, walkingRunningDistanceM: Double? = nil, cyclingDistanceM: Double? = nil,
        activeEnergyKcal: Double? = nil, exerciseMinutes: Double? = nil, restingHeartRateBpm: Double? = nil,
        avgHeartRateBpm: Double? = nil, sleepMinutes: Double? = nil, bodyMassKg: Double? = nil, sources: [String] = []
    ) {
        self.date = date
        self.steps = steps
        self.walkingRunningDistanceM = walkingRunningDistanceM
        self.cyclingDistanceM = cyclingDistanceM
        self.activeEnergyKcal = activeEnergyKcal
        self.exerciseMinutes = exerciseMinutes
        self.restingHeartRateBpm = restingHeartRateBpm
        self.avgHeartRateBpm = avgHeartRateBpm
        self.sleepMinutes = sleepMinutes
        self.bodyMassKg = bodyMassKg
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case date, steps
        case walkingRunningDistanceM = "walking_running_distance_m"
        case cyclingDistanceM = "cycling_distance_m"
        case activeEnergyKcal = "active_energy_kcal"
        case exerciseMinutes = "exercise_minutes"
        case restingHeartRateBpm = "resting_heart_rate_bpm"
        case avgHeartRateBpm = "avg_heart_rate_bpm"
        case sleepMinutes = "sleep_minutes"
        case bodyMassKg = "body_mass_kg"
        case sources
    }
}

public struct SyncWorkout: Sendable, Equatable, Encodable {
    /// `running`, `walking`, `cycling`, `strength`, `yoga`, `swimming`, `other`.
    public var id: String
    public var type: String
    public var startAt: Date
    public var endAt: Date?
    public var durationS: Double?
    public var distanceM: Double?
    public var activeEnergyKcal: Double?
    public var avgHeartRateBpm: Double?
    public var avgPaceSPerKm: Double?
    public var source: String?

    public init(
        id: String, type: String, startAt: Date, endAt: Date? = nil, durationS: Double? = nil, distanceM: Double? = nil,
        activeEnergyKcal: Double? = nil, avgHeartRateBpm: Double? = nil, avgPaceSPerKm: Double? = nil, source: String? = nil
    ) {
        self.id = id
        self.type = type
        self.startAt = startAt
        self.endAt = endAt
        self.durationS = durationS
        self.distanceM = distanceM
        self.activeEnergyKcal = activeEnergyKcal
        self.avgHeartRateBpm = avgHeartRateBpm
        self.avgPaceSPerKm = avgPaceSPerKm
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, type
        case startAt = "start_at"
        case endAt = "end_at"
        case durationS = "duration_s"
        case distanceM = "distance_m"
        case activeEnergyKcal = "active_energy_kcal"
        case avgHeartRateBpm = "avg_heart_rate_bpm"
        case avgPaceSPerKm = "avg_pace_s_per_km"
        case source
    }
}

/// `POST /v1/fitness/sync` body. Aggregates only; raw samples stay on the device.
public struct FitnessSyncPayload: Sendable, Equatable, Encodable {
    public var generatedAt: Date
    public var days: [SyncDay]
    public var workouts: [SyncWorkout]

    public init(generatedAt: Date, days: [SyncDay], workouts: [SyncWorkout]) {
        self.generatedAt = generatedAt
        self.days = days
        self.workouts = workouts
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case days, workouts
    }
}

/// What the server did with a sync (`SyncOut`).
public struct FitnessSyncResult: Sendable, Equatable, Decodable {
    public var receivedAt: Date
    public var generatedAt: Date
    public var daysCreated: Int
    public var daysUpdated: Int
    public var daysSkippedOlder: Int
    public var workoutsCreated: Int
    public var workoutsUpdated: Int
    public var workoutsSkippedOlder: Int

    enum CodingKeys: String, CodingKey {
        case receivedAt = "received_at"
        case generatedAt = "generated_at"
        case daysCreated = "days_created"
        case daysUpdated = "days_updated"
        case daysSkippedOlder = "days_skipped_older"
        case workoutsCreated = "workouts_created"
        case workoutsUpdated = "workouts_updated"
        case workoutsSkippedOlder = "workouts_skipped_older"
    }

    public var daysSent: Int { daysCreated + daysUpdated }
    public var workoutsSent: Int { workoutsCreated + workoutsUpdated }
}
