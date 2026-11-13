import Foundation
import Observation
import ZoroCore

/// The cost dashboard: `/v1/costs/summary` grouped by provider, model, task and day.
@MainActor
@Observable
public final class CostViewModel {
    public static let groups: [CostGroupBy] = [.provider, .model, .task, .day]

    public private(set) var phase: ScreenPhase = .idle
    public private(set) var breakdowns: [CostGroupBy: CostBreakdown] = [:]
    public private(set) var trend: [DailyCost] = []
    /// Groups that couldn't be loaded while the others were.
    public private(set) var failedGroups: [CostGroupBy] = []
    public var selected: CostGroupBy = .model

    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private var generation = 0

    public init(api: any ZoroAPI, topLimit: Int = 8) {
        self.api = api
        limit = topLimit
    }

    public var current: CostBreakdown? { breakdowns[selected] }

    /// Spend over the whole period, from the model grouping (any grouping reports the same total).
    public var totalCost: Decimal? {
        (breakdowns[.model] ?? breakdowns.values.first)?.reportedTotal
    }

    public var emptyMessage: String { "No model costs yet. Costs appear here after ZORO uses a cloud model." }

    public var partialNote: String? {
        guard !failedGroups.isEmpty else { return nil }
        let names = failedGroups.map { Self.title($0).lowercased() }.joined(separator: ", ")
        return "Couldn't load costs by \(names). Reload to try again."
    }

    public static func title(_ group: CostGroupBy) -> String {
        switch group {
        case .provider: "Provider"
        case .model: "Model"
        case .task: "Task"
        case .agent: "Agent"
        case .day: "Day"
        }
    }

    public func load() async {
        phase = .loading
        generation += 1
        let gen = generation
        let api = api
        let results = await withTaskGroup(of: (CostGroupBy, Result<CostSummary, Error>).self) { group in
            for g in Self.groups {
                group.addTask {
                    do { return (g, .success(try await api.costSummary(groupBy: g))) } catch { return (g, .failure(error)) }
                }
            }
            var all: [CostGroupBy: Result<CostSummary, Error>] = [:]
            for await (g, r) in group { all[g] = r }
            return all
        }
        guard gen == generation, !Task.isCancelled else { return }
        var loaded: [CostGroupBy: CostBreakdown] = [:]
        var failed: [CostGroupBy] = []
        var firstError: Error?
        for g in Self.groups {
            switch results[g] {
            case .success(let summary):
                loaded[g] = CostAggregation.breakdown(summary, limit: limit)
                if g == .day { trend = CostAggregation.dailyTrend(summary) }
            case .failure(let error):
                failed.append(g)
                firstError = firstError ?? error
            case .none:
                failed.append(g)
            }
        }
        failedGroups = failed
        if loaded.isEmpty {
            phase = firstError.flatMap(SystemFailure.phase(for:)) ?? .failed(ScreenFailure(message: "Costs couldn't be loaded. Try again."))
            return
        }
        breakdowns = loaded
        if failed.contains(.day) { trend = [] }
        phase = loaded.values.allSatisfy(\.isEmpty) ? .empty : .loaded
    }
}
