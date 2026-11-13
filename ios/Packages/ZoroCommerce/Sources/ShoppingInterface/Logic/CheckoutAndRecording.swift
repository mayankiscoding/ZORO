import CommerceSupport
import Foundation
import Observation
import ZoroCore

/// "Record a price you saw": the owner types a price from a store's app or shelf. It is stored as
/// `user_reported` with the time they saw it, never as a store-provided price.
@MainActor
@Observable
public final class RecordPriceViewModel {
    public var providerId = ""
    public var itemId: String?
    /// item | delivery_fee | handling_fee | platform_fee | small_cart_fee | other_fee
    public var kind = "item"
    public var priceText = ""
    public var seenAt = Date()
    public var label = ""
    public private(set) var isSaving = false
    public private(set) var message: String?
    public private(set) var saved: RecordPriceOut?

    @ObservationIgnored let client: ShoppingClient
    @ObservationIgnored private let clock: @Sendable () -> Date

    public init(client: ShoppingClient, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.clock = clock
        self.seenAt = clock()
    }

    public static let kinds: [(id: String, title: String)] = [
        ("item", "Item price"), ("delivery_fee", "Delivery fee"), ("handling_fee", "Handling fee"),
        ("platform_fee", "Platform fee"), ("small_cart_fee", "Small cart fee"), ("other_fee", "Other fee"),
    ]

    /// Exact parse of "1,250.50" or "₹1,250.50"; nil when not a valid amount with at most two decimals.
    public static func parsePrice(_ text: String) -> Decimal? {
        let cleaned = text.replacingOccurrences(of: "₹", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              cleaned.filter({ $0 == "." }).count <= 1,
              (cleaned.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0) <= 2,
              let value = DecimalString.parse(cleaned), value >= 0, value < 10_000_000_000
        else { return nil }
        return value
    }

    public var validationMessage: String? {
        if providerId.isEmpty { return "Choose the store where you saw the price." }
        if kind == "item" && itemId == nil { return "Choose the basket item this price is for." }
        if Self.parsePrice(priceText) == nil { return "Enter the price in rupees, like 49.50." }
        if seenAt > clock().addingTimeInterval(60) { return "The time you saw it cannot be in the future." }
        return nil
    }

    public func save() async {
        guard validationMessage == nil, let price = Self.parsePrice(priceText) else {
            message = validationMessage
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let record = PriceRecord(provider: providerId, kind: kind, itemId: kind == "item" ? itemId : nil, price: price,
                                     observedAt: seenAt, label: String(label.prefix(200)))
            let out = try await client.record(record)
            if out.status == "recorded" {
                saved = out
                message = "Saved \(Figures.money(out.price)) as a price you saw. Compare again to use it."
                priceText = ""
            } else {
                message = "That basket item could not be found. Refresh your basket, then try again."
            }
        } catch {
            message = ScreenFailure.from(error, subject: "the price").message
        }
    }
}

/// Checkout handoff. The owner verifies store, quantities, address reference and final payable; the
/// server prepares the cart if the store allows it; then the store's own app opens. ZORO never pays.
@MainActor
@Observable
public final class CheckoutViewModel {
    public enum Step: Equatable, Sendable {
        case review
        case preparing
        /// Ready: open the store's app (URL may be nil when the store has no verified link).
        case handoff(CheckoutResult)
        /// The server refused (payable changed, item missing …): one sentence, then compare again.
        case rejected(String)
        /// Preparing the cart needs your approval in ZORO first.
        case needsApproval(ApprovalRequest)
        case failed(ScreenFailure)
    }

    public enum Check: String, CaseIterable, Sendable {
        case store, quantities, address, payable
    }

    public let provider: ProviderComparison
    public let basket: BasketView
    public private(set) var step: Step = .review
    public private(set) var confirmed: Set<Check> = []

    @ObservationIgnored private let client: ShoppingClient

    public init(client: ShoppingClient, provider: ProviderComparison, basket: BasketView) {
        self.client = client
        self.provider = provider
        self.basket = basket
    }

    public func checkLine(_ check: Check) -> String {
        switch check {
        case .store: "Store: \(provider.title)"
        case .quantities: basket.items.map { "\($0.quantity) × \($0.name)" }.joined(separator: ", ")
        case .address: "Delivery address: \(basket.customerLocationReference ?? "the default address in \(provider.title)")"
        case .payable: "Final payable: \(Figures.money(provider.finalPayable))"
        }
    }

    public func toggle(_ check: Check) {
        if confirmed.contains(check) { confirmed.remove(check) } else { confirmed.insert(check) }
    }

    public var canContinue: Bool {
        confirmed.count == Check.allCases.count && provider.finalPayable != nil && step == .review
    }

    /// The store link: from the prepared result when there is one, else the comparison's handoff.
    public var handoffURL: URL? {
        if case .handoff(let r) = step, let raw = r.handoff?.url { return URL(string: raw) }
        return provider.handoff?.url.flatMap(URL.init(string:))
    }

    public func prepare() async {
        guard canContinue, let payable = provider.finalPayable else { return }
        step = .preparing
        do {
            let run = try await client.checkout(CheckoutIn(provider: provider.provider, expectedPayable: payable,
                                                           locationRef: basket.customerLocationReference,
                                                           basketId: basket.basketId))
            if let approval = run.approval, run.status == "needs_approval" {
                step = .needsApproval(approval)
            } else if let result = run.result {
                step = result.status == .rejected ? .rejected(Self.rejection(result)) : .handoff(result)
            } else {
                step = .failed(ScreenFailure(kind: .error, message: "The server did not say what happened. Try again."))
            }
        } catch {
            step = .failed(ScreenFailure.from(error, subject: "the checkout"))
        }
    }

    public func restart() {
        step = .review
        confirmed = []
    }

    static func rejection(_ r: CheckoutResult) -> String {
        let failed = r.checks.filter { !$0.ok }.map { $0.detail.isEmpty ? $0.check.replacingOccurrences(of: "_", with: " ") : $0.detail }
        let detail = failed.isEmpty ? "" : " (\(failed.joined(separator: "; ")))"
        switch r.reason {
        case "payable_changed":
            let now = r.finalPayable.map { " It is now \(Figures.money($0))." } ?? ""
            return "The payable changed since you compared.\(now) Compare again, then check out."
        case "address_required": return "No delivery address is set for this basket. Ask ZORO to set one, then try again."
        case "incomplete_coverage": return "This store no longer has a fresh price for every item. Compare again first."
        case "empty_basket": return "Your basket is empty. Add items, then compare stores."
        case "invalid_quantity": return "A quantity is outside 1 to 99. Fix it in your basket, then try again."
        case "unknown_provider": return "ZORO does not know this store any more. Compare again, then pick a store."
        case "provider_item_unknown": return "This store does not have a matching product for every item. Open the store and add them there."
        default: return "The store could not take this basket\(detail). Compare again, then try once more."
        }
    }
}
