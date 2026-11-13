import Foundation
import LifeSupport
import ZoroCore

/// The payload of a `fitness_summary` card (backend/app/fitness/cards.py). Metrics carry a value that may be a number,
/// text or null, plus per-kind extras (weekly change, trend slope, record date).
public struct FitnessCardPayload: Sendable, Equatable, Decodable {
    public struct Metric: Sendable, Equatable, Decodable {
        public var label: String
        public var value: JSONValue
        public var unit: String
        public var previous: Double?
        public var changePct: Double?
        public var slopePerWeek: Double?
        public var direction: String?
        public var date: String?

        enum CodingKeys: String, CodingKey {
            case label, value, unit, previous
            case changePct = "change_pct"
            case slopePerWeek = "slope_per_week"
            case direction, date
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            value = try c.value(.value, default: JSONValue.null)
            unit = try c.value(.unit, default: "")
            previous = try c.decodeIfPresent(Double.self, forKey: .previous)
            changePct = try c.decodeIfPresent(Double.self, forKey: .changePct)
            slopePerWeek = try c.decodeIfPresent(Double.self, forKey: .slopePerWeek)
            direction = try c.decodeIfPresent(String.self, forKey: .direction)
            date = try c.decodeIfPresent(String.self, forKey: .date)
        }
    }

    public var metrics: [Metric]
    public var observations: [String]
    public var dataSource: String
    public var freshness: FitnessFreshness
    public var stale: Bool
    public var externalModelAllowed: Bool
    public var plan: RunningPlan?

    enum CodingKeys: String, CodingKey {
        case metrics, observations
        case dataSource = "data_source"
        case freshness, stale
        case externalModelAllowed = "external_model_allowed"
        case plan
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metrics = try c.value(.metrics, default: [])
        observations = try c.value(.observations, default: [])
        dataSource = try c.value(.dataSource, default: "Apple Health (synced from your iPhone)")
        freshness = try c.value(.freshness, default: FitnessFreshness())
        stale = try c.value(.stale, default: freshness.stale)
        externalModelAllowed = try c.value(.externalModelAllowed, default: true)
        plan = try c.decodeIfPresent(RunningPlan.self, forKey: .plan)
    }
}

/// What a fitness card shows, in words.
public struct FitnessCardModel: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var value: String
        public var detail: String?
        public var accessibilityLabel: String { "\(label), \(value)" + (detail.map { ", \($0)" } ?? "") }
    }

    public var title: String
    public var rows: [Row]
    public var observations: [String]
    public var planLine: String?
    public var sourceLine: String
    public var staleNote: String?
    public static let disclaimer = "Fitness information, not medical advice."

    public init(card: UICard, now: Date) throws {
        guard card.kind == "fitness_summary" else {
            throw ZoroError.invalidResponse("not a fitness card: \(card.kind)")
        }
        let p = try card.decodePayload(FitnessCardPayload.self)
        title = card.title ?? "Fitness"
        rows = p.metrics.enumerated().map { index, m in Self.row(m, index: index) }
        observations = p.observations
        if let plan = p.plan {
            planLine = "\(plan.weeks.count)-week plan toward \(LifeFormat.number(plan.raceKm, places: 1)) km, \(plan.daysPerWeek) runs a week. \(PlanPresenter.startBasisSentence(plan))"
        }
        sourceLine = FreshnessFormatter.line(source: p.dataSource, freshness: p.freshness, now: now)
        staleNote = p.stale ? (FreshnessFormatter.staleNote(p.freshness) ?? "This may be out of date.") : nil
    }

    static func valueText(_ v: JSONValue, unit: String) -> String {
        let base: String
        switch v {
        case .number(let n): base = LifeFormat.number(n, places: 2)
        case .string(let s): base = s
        case .bool(let b): base = b ? "Yes" : "No"
        default: return "Not recorded"
        }
        return unit.isEmpty ? base : "\(base) \(unit)"
    }

    static func row(_ m: FitnessCardPayload.Metric, index: Int) -> Row {
        var detail: String?
        if let pct = m.changePct {
            let text = LifeFormat.number(abs(pct), places: 1)
            let change = Double(text) == 0 ? "About the same as last week" : (pct > 0 ? "Up \(text)% on last week" : "Down \(text)% on last week")
            detail = m.previous.map { "\(change) (\(LifeFormat.number($0, places: 1)) before)" } ?? change
        } else if let slope = m.slopePerWeek, let direction = m.direction {
            detail = direction == "insufficient_data" ? "Not enough data for a trend" : "\(direction.capitalizedFirst), about \(LifeFormat.number(abs(slope), places: 1)) \(m.unit) a week"
        } else if let date = m.date, let day = CalendarDate(date) {
            detail = LifeFormat.fullDay(day)
        }
        return Row(id: "\(index)-\(m.label)", label: m.label.capitalizedFirst, value: valueText(m.value, unit: m.unit), detail: detail)
    }
}
