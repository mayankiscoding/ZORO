import CommerceSupport
import Foundation
import ZoroCore

// Mirrors backend/app/shopping/compare.py, tools_catalog.py (CompareIn/Out, CheckoutIn),
// service.py (CheckoutResult) and http.py (ToolRun). Totals are computed by the server's deterministic
// code; this app shows them and never recomputes a payable.

public struct ComparisonLine: Codable, Sendable, Hashable {
    public var itemId: String
    public var name: String
    public var quantity: Int
    @WireDecimal public var unitPrice: Decimal
    @WireDecimal public var lineTotal: Decimal
    public var provenance: String
    public var source: String
    public var observedAt: Date
    public var confidence: Double

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id", name, quantity, unitPrice = "unit_price", lineTotal = "line_total", provenance, source
        case observedAt = "observed_at", confidence
    }
}

public struct ComparisonSubstitute: Codable, Sendable, Hashable {
    public var itemId: String
    public var name: String
    public var offerLabel: String
    @WireDecimal public var unitPrice: Decimal
    @WireDecimal public var lineTotal: Decimal
    public var confidence: Double
    public var reasons: [String]
    /// Whether the owner allowed substitutes for this item.
    public var allowed: Bool

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id", name, offerLabel = "offer_label", unitPrice = "unit_price", lineTotal = "line_total"
        case confidence, reasons, allowed
    }
}

public struct ComparisonMissing: Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable {
        case noOffer = "no_offer", stalePrice = "stale_price", outOfStock = "out_of_stock"
    }
    public var itemId: String
    public var name: String
    public var reason: Reason

    enum CodingKeys: String, CodingKey { case itemId = "item_id", name, reason }
}

public struct ComparisonFee: Codable, Sendable, Hashable {
    public var kind: String
    public var label: String
    @WireDecimal public var amount: Decimal
    public var waived: Bool
}

public struct ComparisonDiscount: Codable, Sendable, Hashable {
    public var code: String
    public var kind: String
    @WireDecimal public var amount: Decimal
}

public struct ProviderComparison: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case ranked, partial, unavailable }

    public var provider: String
    public var title: String
    public var status: Status
    public var rank: Int?
    @WireDecimal public var itemTotal: Decimal
    public var fees: [ComparisonFee]
    public var feesKnown: Bool
    @WireDecimal public var feeTotal: Decimal
    public var discounts: [ComparisonDiscount]
    @WireDecimal public var discountTotal: Decimal
    /// Only for complete coverage.
    @WireDecimalOptional public var finalPayable: Decimal?
    public var exactItems: Int
    public var totalItems: Int
    public var coveragePct: Int
    public var matchConfidence: Double?
    public var lines: [ComparisonLine]
    public var substitutes: [ComparisonSubstitute]
    public var missing: [ComparisonMissing]
    public var staleItems: [String]
    public var handoff: Handoff?
    public var notes: [String]

    public var id: String { provider }

    enum CodingKeys: String, CodingKey {
        case provider, title, status, rank, itemTotal = "item_total", fees, feesKnown = "fees_known", feeTotal = "fee_total"
        case discounts, discountTotal = "discount_total", finalPayable = "final_payable", exactItems = "exact_items"
        case totalItems = "total_items", coveragePct = "coverage_pct", matchConfidence = "match_confidence", lines
        case substitutes, missing, staleItems = "stale_items", handoff, notes
    }
}

public struct BasketComparison: Codable, Sendable, Equatable {
    public enum CheapestReason: String, Codable, Sendable {
        case cheapest, feesUnknown = "fees_unknown", tie, noCompleteProvider = "no_complete_provider"
        case emptyBasket = "empty_basket"
    }

    public var computedAt: Date
    public var totalItems: Int
    public var providers: [ProviderComparison]
    public var cheapestProvider: String?
    public var cheapestReason: CheapestReason

    enum CodingKeys: String, CodingKey {
        case computedAt = "computed_at", totalItems = "total_items", providers, cheapestProvider = "cheapest_provider"
        case cheapestReason = "cheapest_reason"
    }
}

public struct CompareIn: Codable, Sendable, Equatable {
    public var basketId: String?
    public init(basketId: String?) { self.basketId = basketId }
    enum CodingKeys: String, CodingKey { case basketId = "basket_id" }
}

public struct CompareOut: Codable, Sendable, Equatable {
    public var basket: BasketView?
    public var comparison: BasketComparison?
}

// MARK: - Checkout handoff

public struct CheckoutIn: Codable, Sendable, Equatable {
    public var provider: String
    @WireDecimal public var expectedPayable: Decimal
    public var locationRef: String?
    public var basketId: String?

    public init(provider: String, expectedPayable: Decimal, locationRef: String?, basketId: String?) {
        self.provider = provider
        self.expectedPayable = expectedPayable
        self.locationRef = locationRef
        self.basketId = basketId
    }

    enum CodingKeys: String, CodingKey {
        case provider, expectedPayable = "expected_payable", locationRef = "location_ref", basketId = "basket_id"
    }
}

public struct CheckoutCheck: Codable, Sendable, Hashable {
    public var check: String
    public var ok: Bool
    public var detail: String
}

public struct CheckoutResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case cartPrepared = "cart_prepared", handoff, rejected }
    public var status: Status
    public var provider: String
    public var reason: String
    public var checks: [CheckoutCheck]
    @WireDecimalOptional public var finalPayable: Decimal?
    @WireDecimalOptional public var providerToPay: Decimal?
    public var handoff: Handoff?
    public var warnings: [String]
    public var note: String

    enum CodingKeys: String, CodingKey {
        case status, provider, reason, checks, finalPayable = "final_payable", providerToPay = "provider_to_pay"
        case handoff, warnings, note
    }
}

/// `POST /v1/shopping/checkout` answers a tool run: completed with a result, or waiting for approval.
public struct CheckoutRun: Codable, Sendable, Equatable {
    public var status: String
    public var result: CheckoutResult?
    public var approval: ApprovalRequest?
}
