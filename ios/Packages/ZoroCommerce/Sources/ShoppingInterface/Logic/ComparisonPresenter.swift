import CommerceSupport
import Foundation
import ZoroDesign

/// Turns the server's `BasketComparison` into sentences and rows. Pure: no I/O, no arithmetic on
/// payables (the server computed them); it only chooses words and order.
public struct ComparisonPresentation: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// "Lowest", "2nd", "Partial", "Not available": words, never colour alone.
        public var badge: String
        public var badgeRole: ZoroRole?
        /// "₹121.00 to pay" or "₹54.00 for 1 of 2 items".
        public var amountLine: String
        public var finalPayable: Decimal?
        public var coverageLine: String
        public var matchConfidence: Double?
        public var feeLine: String
        public var discountLine: String?
        public var missingLines: [String]
        public var staleLine: String?
        public var substituteLines: [String]
        public var cautions: [String]
        public var handoff: Handoff?
        public var canCheckout: Bool
    }

    public var headline: String
    /// Plain explanation of why a store is or is not called cheapest.
    public var explanation: String?
    public var cheapestProviderId: String?
    public var rows: [Row]
    /// Set when the comparison itself is older than the freshness window.
    public var freshnessWarning: String?
}

public enum ComparisonPresenter {
    public static func present(_ result: BasketComparison, now: Date, calendar: Calendar = .current) -> ComparisonPresentation {
        let ranked = result.providers.filter { $0.status == .ranked }.sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
        let partial = result.providers.filter { $0.status != .ranked }
        let lowestRanked = ranked.compactMap(\.finalPayable).min()
        let titles = Dictionary(result.providers.map { ($0.provider, $0.title) }, uniquingKeysWith: { a, _ in a })

        var headline: String
        var explanation: String?
        switch result.cheapestReason {
        case .cheapest:
            let title = result.cheapestProvider.flatMap { titles[$0] } ?? "One store"
            let amount = ranked.first?.finalPayable.map { Figures.money($0) } ?? ""
            headline = "\(title) is cheapest for the full basket at \(amount)."
            explanation = "It prices every item with fresh exact matches, and its fees are known."
            if !partial.isEmpty {
                explanation! += " \(storeList(partial.map(\.title))) \(partial.count == 1 ? "is" : "are") left out because \(partial.count == 1 ? "it does" : "they do") not have a fresh price for every item."
            }
        case .tie:
            let tied = ranked.filter { $0.finalPayable == lowestRanked }.map(\.title)
            headline = "\(storeList(tied)) cost the same for the full basket\(lowestRanked.map { ", \(Figures.money($0))" } ?? "")."
            explanation = "Pick the store you prefer; the payable is identical."
        case .feesUnknown:
            let unknown = ranked.filter { !$0.feesKnown }.map(\.title)
            headline = "No store is called cheapest yet."
            explanation = "\(ranked.count) \(ranked.count == 1 ? "store prices" : "stores price") every item, but fees are not known for \(storeList(unknown)), so the final payable could be higher there. Record the fee you see in the app to compare fairly."
        case .noCompleteProvider:
            headline = "No store can be called cheapest."
            explanation = "No store has a fresh price for every item in your basket, so totals would compare different baskets. Record a price you saw, or compare again later."
        case .emptyBasket:
            headline = "Your basket is empty."
            explanation = "Add items to your basket, then compare stores."
        }

        let rows = result.providers.map { row(for: $0, cheapest: result.cheapestProvider, lowestRanked: lowestRanked) }
        var freshness: String?
        if now.timeIntervalSince(result.computedAt) > SourceStamp.staleAfter {
            freshness = "Prices were compared at \(Figures.moment(result.computedAt, now: now, calendar: calendar)) and may have changed. Compare again before you check out."
        }
        return ComparisonPresentation(headline: headline, explanation: explanation, cheapestProviderId: result.cheapestProvider,
                                      rows: rows, freshnessWarning: freshness)
    }

    static func row(for p: ProviderComparison, cheapest: String?, lowestRanked: Decimal?) -> ComparisonPresentation.Row {
        let badge: String
        var role: ZoroRole?
        switch p.status {
        case .ranked:
            if p.provider == cheapest {
                badge = "Lowest"
                role = .positive
            } else {
                badge = ordinal(p.rank ?? 0)
            }
        case .partial:
            badge = "Partial"
            role = .attention
        case .unavailable:
            badge = "Not available"
        }

        let amountLine: String
        if let payable = p.finalPayable {
            amountLine = "\(Figures.money(payable)) to pay"
        } else if p.status == .partial {
            amountLine = "\(Figures.money(p.itemTotal)) for \(p.exactItems) of \(p.totalItems) items"
        } else {
            amountLine = "No prices"
        }

        let coverage = "\(p.exactItems) of \(p.totalItems) items priced (\(p.coveragePct)%)"

        let feeLine: String
        if p.status != .ranked {
            feeLine = "Fees not checked until every item is priced"
        } else if !p.feesKnown {
            feeLine = "Fees not known; the payable may be higher"
        } else if p.fees.isEmpty {
            feeLine = "No fees"
        } else {
            feeLine = p.fees.map { fee in
                fee.waived ? "\(fee.label) waived" : "\(fee.label) \(Figures.money(fee.amount))"
            }.joined(separator: ", ")
        }

        let discountLine = p.discounts.isEmpty ? nil
            : "Discounts \(ZoroMoney.minus)\(Figures.money(p.discountTotal)) (\(p.discounts.map(\.code).joined(separator: ", ")))"

        let missing = p.missing.map { m -> String in
            switch m.reason {
            case .noOffer: "\(m.name): not available"
            case .stalePrice: "\(m.name): price is old, so it is left out"
            case .outOfStock: "\(m.name): out of stock"
            }
        }

        let stale = p.staleItems.isEmpty ? nil
            : "\(p.staleItems.count) \(p.staleItems.count == 1 ? "price is" : "prices are") too old to use. Check the store or record what you see."

        let subs = p.substitutes.map { s -> String in
            let permission = s.allowed ? "substitutes allowed" : "you have not allowed substitutes"
            return "Instead of \(s.name): \(s.offerLabel), \(Figures.money(s.lineTotal)) (\(permission))"
        }

        var cautions = p.notes
        if p.status == .partial, let lowest = lowestRanked, p.itemTotal < lowest {
            cautions.append("Looks lower only because \(p.totalItems - p.exactItems) of \(p.totalItems) items are missing.")
        }

        return ComparisonPresentation.Row(
            id: p.provider, title: p.title, badge: badge, badgeRole: role, amountLine: amountLine, finalPayable: p.finalPayable,
            coverageLine: coverage, matchConfidence: p.matchConfidence, feeLine: feeLine, discountLine: discountLine,
            missingLines: missing, staleLine: stale, substituteLines: subs, cautions: cautions, handoff: p.handoff,
            canCheckout: p.status == .ranked && p.finalPayable != nil)
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    static func storeList(_ names: [String]) -> String {
        switch names.count {
        case 0: "No store"
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
