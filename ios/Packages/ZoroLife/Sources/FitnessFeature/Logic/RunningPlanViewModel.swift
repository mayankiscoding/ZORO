import Foundation
import LifeSupport
import Observation

/// The running-plan builder: a small form, validated like the server, and the plan the server returns.
/// The server builds the plan with fixed rules (at most 10 percent more distance a week, a lighter week every
/// fourth week); the screen shows those rules and every assumption next to the plan.
@MainActor @Observable
public final class RunningPlanViewModel {
    public var goal: RunningGoal = .first5k
    /// nil = the goal's default length.
    public var weeks: Int?
    public var daysPerWeek: Int = 3
    /// What the owner typed; empty = use synced runs.
    public var currentKmText: String = ""
    public private(set) var plan: Loadable<RunningPlanOut> = .idle
    public private(set) var now: Date

    private let server: any FitnessServing
    private let timeZone: TimeZone
    private let clock: @Sendable () -> Date

    public init(server: any FitnessServing, timeZone: TimeZone = .current, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.server = server
        self.timeZone = timeZone
        self.clock = clock
        self.now = clock()
    }

    /// The request the form describes, or nil when the weekly distance cannot be read as a number.
    public var request: RunningPlanRequest? {
        let trimmed = currentKmText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        var km: Double?
        if !trimmed.isEmpty {
            guard let parsed = Double(trimmed) else { return nil }
            km = parsed
        }
        return RunningPlanRequest(goal: goal, weeks: weeks, daysPerWeek: daysPerWeek, currentWeeklyKm: km)
    }

    /// One sentence per problem with the form.
    public var problems: [String] {
        guard let request else { return ["Enter your weekly distance as a number from 0 to 200 km, or leave it empty."] }
        return request.problems
    }

    public var canBuild: Bool { problems.isEmpty && !plan.isLoading }

    public func build() async {
        guard canBuild, let request else { return }
        plan = .loading
        do {
            let result = try await server.runningPlan(request, timeZone: timeZone)
            now = clock()
            plan = .loaded(result)
        } catch {
            plan = .failed(ScreenFailure.from(error, subject: "your running plan"))
        }
    }

    public func clear() { plan = .idle }
}
