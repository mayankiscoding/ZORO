import Foundation
import ZoroCore

/// What the fitness screens need from the server. `FitnessAPIClient` is the real one; tests use a fake
/// `ZoroAPI` behind it, or a fake of this protocol.
public protocol FitnessServing: Sendable {
    func freshness() async throws -> FitnessFreshness
    func summary(date: CalendarDate?, timeZone: TimeZone) async throws -> DailySummary
    func weekly(timeZone: TimeZone) async throws -> WeeklyComparison
    func trend(metric: String, days: Int, timeZone: TimeZone) async throws -> TrendResult
    func running(days: Int, timeZone: TimeZone) async throws -> RunningProgress
    func records() async throws -> PersonalRecords
    func consistency(weeks: Int, timeZone: TimeZone) async throws -> Consistency
    func runningPlan(_ request: RunningPlanRequest, timeZone: TimeZone) async throws -> RunningPlanOut
    func sync(_ payload: FitnessSyncPayload) async throws -> FitnessSyncResult
}

/// Typed requests against `/v1/fitness`. Strava stays out: it is not part of this screen set.
public struct FitnessAPIClient: FitnessServing {
    public let api: any ZoroAPI
    public init(api: any ZoroAPI) { self.api = api }

    public func freshness() async throws -> FitnessFreshness {
        try await api.send(.get("/v1/fitness/freshness"), as: FitnessFreshness.self)
    }

    public func summary(date: CalendarDate?, timeZone: TimeZone) async throws -> DailySummary {
        try await api.send(
            .get("/v1/fitness/summary", query: [URLQueryItem(name: "date", value: date?.description), Self.tz(timeZone)]),
            as: DailySummary.self)
    }

    public func weekly(timeZone: TimeZone) async throws -> WeeklyComparison {
        try await api.send(.get("/v1/fitness/weekly", query: [Self.tz(timeZone)]), as: WeeklyComparison.self)
    }

    public func trend(metric: String, days: Int, timeZone: TimeZone) async throws -> TrendResult {
        try await api.send(
            .get("/v1/fitness/trends", query: [
                URLQueryItem(name: "metric", value: metric), URLQueryItem(name: "days", value: String(days)), Self.tz(timeZone),
            ]),
            as: TrendResult.self)
    }

    public func running(days: Int, timeZone: TimeZone) async throws -> RunningProgress {
        try await api.send(
            .get("/v1/fitness/running", query: [URLQueryItem(name: "days", value: String(days)), Self.tz(timeZone)]),
            as: RunningProgress.self)
    }

    public func records() async throws -> PersonalRecords {
        try await api.send(.get("/v1/fitness/records"), as: PersonalRecords.self)
    }

    public func consistency(weeks: Int, timeZone: TimeZone) async throws -> Consistency {
        try await api.send(
            .get("/v1/fitness/consistency", query: [URLQueryItem(name: "weeks", value: String(weeks)), Self.tz(timeZone)]),
            as: Consistency.self)
    }

    public func runningPlan(_ request: RunningPlanRequest, timeZone: TimeZone) async throws -> RunningPlanOut {
        var api = try APIRequest.json(.post, "/v1/fitness/running-plan", body: request)
        api.query = [Self.tz(timeZone)]
        return try await self.api.send(api, as: RunningPlanOut.self)
    }

    public func sync(_ payload: FitnessSyncPayload) async throws -> FitnessSyncResult {
        try await api.send(try .json(.post, "/v1/fitness/sync", body: payload), as: FitnessSyncResult.self)
    }

    static func tz(_ zone: TimeZone) -> URLQueryItem { URLQueryItem(name: "tz", value: zone.identifier) }
}
