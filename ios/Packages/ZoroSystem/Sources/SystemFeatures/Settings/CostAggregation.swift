import Foundation
import ZoroCore

/// One row of the cost dashboard. All money is `Decimal` US dollars as the backend reports it.
public struct CostLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cost: Decimal
    /// Fraction of the total, 0 to 1, rounded to four places. 0 when the total is 0.
    public var share: Decimal
    public var avgLatencyMs: Double
    public var errorRate: Double
    /// True for the combined "Other" row.
    public var isOther: Bool
}

public struct CostBreakdown: Equatable, Sendable {
    public var groupBy: CostGroupBy
    /// The total the server reported.
    public var reportedTotal: Decimal
    /// The exact sum of the rows the server sent, before any "Other" grouping.
    public var computedTotal: Decimal
    public var lines: [CostLine]
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int

    /// False when the server's total and the sum of its rows disagree (rows may be filtered or rounded).
    public var totalsMatch: Bool { reportedTotal == computedTotal }
    public var isEmpty: Bool { lines.isEmpty }
}

public struct DailyCost: Identifiable, Equatable, Sendable {
    public var date: Date
    public var cost: Decimal
    public var id: Date { date }
}

public enum CostAggregation {
    /// Rows sorted by cost (largest first; by date for `.day`), the tail beyond `limit` combined into
    /// "Other", shares and totals computed with `Decimal` only.
    public static func breakdown(_ summary: CostSummary, limit: Int = 8) -> CostBreakdown {
        let items = summary.items
        let computed = items.reduce(Decimal(0)) { $0 + $1.costUsd }
        let denominator = summary.totalCostUsd > 0 ? summary.totalCostUsd : computed

        func line(_ row: CostRow) -> CostLine {
            CostLine(
                id: row.key, label: label(for: row.key, groupBy: summary.groupBy), requests: row.requests,
                inputTokens: row.inputTokens, outputTokens: row.outputTokens, cost: row.costUsd,
                share: share(row.costUsd, of: denominator), avgLatencyMs: row.avgLatencyMs, errorRate: row.errorRate, isOther: false)
        }

        var lines: [CostLine]
        if summary.groupBy == .day {
            lines = items.sorted { $0.key < $1.key }.map(line)
        } else {
            let sorted = items.sorted { ($0.costUsd, $1.key) > ($1.costUsd, $0.key) }
            let head = Array(sorted.prefix(max(limit, 1)))
            let tail = Array(sorted.dropFirst(max(limit, 1)))
            lines = head.map(line)
            if !tail.isEmpty {
                let cost = tail.reduce(Decimal(0)) { $0 + $1.costUsd }
                let requests = tail.reduce(0) { $0 + $1.requests }
                let weighted = requests > 0 ? tail.reduce(0.0) { $0 + $1.avgLatencyMs * Double($1.requests) } / Double(requests) : 0
                let errors = requests > 0 ? tail.reduce(0.0) { $0 + $1.errorRate * Double($1.requests) } / Double(requests) : 0
                lines.append(CostLine(
                    id: "other", label: "Other (\(tail.count))", requests: requests,
                    inputTokens: tail.reduce(0) { $0 + $1.inputTokens }, outputTokens: tail.reduce(0) { $0 + $1.outputTokens },
                    cost: cost, share: share(cost, of: denominator), avgLatencyMs: weighted, errorRate: errors, isOther: true))
            }
        }
        return CostBreakdown(
            groupBy: summary.groupBy, reportedTotal: summary.totalCostUsd, computedTotal: computed, lines: lines,
            requests: items.reduce(0) { $0 + $1.requests }, inputTokens: items.reduce(0) { $0 + $1.inputTokens },
            outputTokens: items.reduce(0) { $0 + $1.outputTokens })
    }

    /// Fraction rounded half away from zero to four places.
    public static func share(_ part: Decimal, of whole: Decimal) -> Decimal {
        guard whole > 0, part > 0 else { return 0 }
        var value = part / whole
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 4, .plain)
        return min(rounded, 1)
    }

    /// Days with a `yyyy-MM-dd` key, oldest first. Keys that aren't dates are left out of the trend.
    public static func dailyTrend(_ summary: CostSummary) -> [DailyCost] {
        summary.items.compactMap { row in
            guard let date = parseDay(row.key) else { return nil }
            return DailyCost(date: date, cost: row.costUsd)
        }.sorted { $0.date < $1.date }
    }

    static func parseDay(_ key: String) -> Date? {
        let parts = key.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// Row label: day keys become "12 Nov"; everything else is shown as the server sent it.
    public static func label(for key: String, groupBy: CostGroupBy) -> String {
        switch groupBy {
        case .day:
            guard let date = parseDay(key) else { return key }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_IN")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "d MMM"
            return f.string(from: date)
        case .task:
            return SystemFormat.sentenceCase(key.replacingOccurrences(of: "_", with: " "))
        default:
            return key
        }
    }
}
