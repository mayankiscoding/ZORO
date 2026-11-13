import CommerceSupport
import Foundation
import ZoroCore

// Codable mirrors of backend/app/shopping (present.py, types.py, basket.py, compare.py, service.py,
// shortlist.py, tools_*.py, http.py). Field names match the Pydantic models; money is `Decimal` from
// decimal strings. Fixture tests decode JSON produced by the real models.

public struct Handoff: Codable, Sendable, Hashable {
    public var provider: String
    public var title: String
    public var url: String?
    public var verified: Bool
    public var note: String
}

public struct ProviderUnavailable: Codable, Sendable, Hashable {
    public var kind: String
    public var provider: String
    public var method: String
    /// Stable code: not_supported, requires_credentials, requires_partnership, provider_error …
    public var reason: String
    public var message: String
    public var handoff: Handoff?
}

public struct VariantOut: Codable, Sendable, Hashable {
    public var variantId: String
    public var skuId: String?
    public var label: String
    @WireDecimalOptional public var price: Decimal?
    @WireDecimalOptional public var mrp: Decimal?
    /// Server-computed, e.g. "₹5.80 per 100 ml".
    public var unitPrice: String?
    public var inStock: Bool?

    enum CodingKeys: String, CodingKey {
        case variantId = "variant_id", skuId = "sku_id", label, price, mrp, unitPrice = "unit_price", inStock = "in_stock"
    }
}

public struct ShownProduct: Codable, Sendable, Hashable, Identifiable {
    public var index: Int
    public var ref: String
    public var provider: String
    public var productId: String
    public var name: String
    public var brand: String?
    public var url: String?
    public var variants: [VariantOut]
    public var attributes: [String: String]
    public var source: String
    public var retrievedAt: Date

    public var id: String { ref }

    enum CodingKeys: String, CodingKey {
        case index, ref, provider, productId = "product_id", name, brand, url, variants, attributes, source
        case retrievedAt = "retrieved_at"
    }
}

public struct SearchIn: Codable, Sendable, Equatable {
    public var query: String
    public var providers: [String]?
    public var locationRef: String?
    public var limit: Int

    public init(query: String, providers: [String]? = nil, locationRef: String? = nil, limit: Int = 5) {
        self.query = query
        self.providers = providers
        self.locationRef = locationRef
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey { case query, providers, locationRef = "location_ref", limit }
}

public struct SearchOut: Codable, Sendable, Equatable {
    public var query: String
    public var products: [ShownProduct]
    public var unavailable: [ProviderUnavailable]
}

public struct Clarification: Codable, Sendable, Equatable {
    public var question: String
    public var options: [JSONObject]
}

// MARK: - Basket

public struct BasketItemView: Codable, Sendable, Hashable, Identifiable {
    public var itemId: String
    public var name: String
    public var brand: String?
    public var size: String?
    public var identityKey: String
    public var gtin: String?
    public var sku: String?
    public var quantity: Int
    public var preferredBrand: String?
    public var substitutionsAllowed: Bool
    public var equivalenceConfidencePct: Int
    @WireDecimalOptional public var unitPrice: Decimal?
    public var priceAt: Date?
    public var priceSource: String?

    public var id: String { itemId }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id", name, brand, size, identityKey = "identity_key", gtin, sku, quantity
        case preferredBrand = "preferred_brand", substitutionsAllowed = "substitutions_allowed"
        case equivalenceConfidencePct = "equivalence_confidence_pct", unitPrice = "unit_price"
        case priceAt = "price_at", priceSource = "price_source"
    }
}

public struct BasketView: Codable, Sendable, Equatable {
    public var basketId: String
    public var name: String
    public var customerLocationReference: String?
    public var originalProvider: String?
    public var items: [BasketItemView]
    public var pricedItems: Int
    /// Sum of priced lines only; `pricedItems` says how many.
    @WireDecimal public var knownTotal: Decimal
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case basketId = "basket_id", name, customerLocationReference = "customer_location_reference"
        case originalProvider = "original_provider", items, pricedItems = "priced_items", knownTotal = "known_total"
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct BasketViewOut: Codable, Sendable, Equatable {
    public var basket: BasketView?
}

public struct BasketChangeOut: Codable, Sendable, Equatable {
    /// added | updated | removed | needs_clarification | not_found
    public var status: String
    public var item: BasketItemView?
    public var basket: BasketView?
    public var clarification: Clarification?
}

public struct BasketAddIn: Codable, Sendable, Equatable {
    public var ref: String?
    public var variantHint: String?
    public var quantity: Int?
    public var substitutionsAllowed: Bool
    public var basketId: String?

    public init(ref: String, variantHint: String?, quantity: Int, substitutionsAllowed: Bool = false, basketId: String? = nil) {
        self.ref = ref
        self.variantHint = variantHint
        self.quantity = quantity
        self.substitutionsAllowed = substitutionsAllowed
        self.basketId = basketId
    }

    enum CodingKeys: String, CodingKey {
        case ref, variantHint = "variant_hint", quantity, substitutionsAllowed = "substitutions_allowed", basketId = "basket_id"
    }
}

// MARK: - Recording a price

public enum Provenance: String, Codable, Sendable, CaseIterable {
    case providerAPI = "provider_api", userReported = "user_reported", userScreenshotOCR = "user_screenshot_ocr"
}

public struct PriceRecord: Codable, Sendable, Equatable {
    public var provider: String
    /// item | delivery_fee | handling_fee | platform_fee | small_cart_fee | other_fee
    public var kind: String
    public var itemId: String?
    @WireDecimal public var price: Decimal
    @WireDecimalOptional public var mrp: Decimal?
    public var provenance: Provenance
    public var observedAt: Date?
    public var label: String
    public var inStock: Bool?

    public init(provider: String, kind: String = "item", itemId: String?, price: Decimal, mrp: Decimal? = nil,
                observedAt: Date?, label: String = "", inStock: Bool? = nil) {
        self.provider = provider
        self.kind = kind
        self.itemId = itemId
        self.price = price
        self.mrp = mrp
        self.provenance = .userReported
        self.observedAt = observedAt
        self.label = label
        self.inStock = inStock
    }

    enum CodingKeys: String, CodingKey {
        case provider, kind, itemId = "item_id", price, mrp, provenance, observedAt = "observed_at", label, inStock = "in_stock"
    }
}

public struct RecordPriceOut: Codable, Sendable, Equatable {
    public var status: String
    public var observationId: String?
    public var provider: String
    public var kind: String
    @WireDecimal public var price: Decimal
    public var provenance: String
    public var observedAt: Date?

    enum CodingKeys: String, CodingKey {
        case status, observationId = "observation_id", provider, kind, price, provenance, observedAt = "observed_at"
    }
}

// MARK: - Providers and shortlist

public enum IntegrationLevel: String, Codable, Sendable, CaseIterable {
    case fullyIntegrated = "fully_integrated", officialAPI = "official_api", affiliateSearch = "affiliate_search"
    case deepLinkHandoff = "deep_link_handoff", manualFallback = "manual_fallback", unavailable

    public var label: String {
        switch self {
        case .fullyIntegrated: "Works in ZORO"
        case .officialAPI: "Official connection"
        case .affiliateSearch: "Search through the affiliate programme"
        case .deepLinkHandoff: "Opens the store's app"
        case .manualFallback: "You enter it yourself"
        case .unavailable: "Not available"
        }
    }
}

public struct MethodLevel: Codable, Sendable, Hashable {
    public var method: String
    public var level: IntegrationLevel
    public var note: String
}

public struct ProviderInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var category: String
    public var status: String
    public var methods: [MethodLevel]
    public var handoff: Handoff?
    public var note: String
}

public struct ShortlistEntry: Codable, Sendable, Hashable, Identifiable {
    public var entryId: String
    public var provider: String
    public var productId: String
    public var variantId: String?
    public var name: String
    public var brand: String?
    public var url: String?
    @WireDecimalOptional public var price: Decimal?
    public var attributes: [String: String]
    public var source: String
    public var retrievedAt: Date

    public var id: String { entryId }

    enum CodingKeys: String, CodingKey {
        case entryId = "entry_id", provider, productId = "product_id", variantId = "variant_id", name, brand, url, price
        case attributes, source, retrievedAt = "retrieved_at"
    }
}

public struct ShortlistOut: Codable, Sendable, Equatable {
    public var status: String
    public var entry: ShortlistEntry?
    public var clarification: Clarification?
}

public struct ProductPick: Codable, Sendable, Equatable {
    public var ref: String
    public init(ref: String) { self.ref = ref }
}
