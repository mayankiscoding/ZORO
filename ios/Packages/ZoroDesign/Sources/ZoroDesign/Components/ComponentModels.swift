import Foundation

// Display models for shared components. Feature packages map their ZoroCore types into these.
// They carry no data of their own: every value comes from the caller, with its source and time.

/// Stock as reported by the source. `unknown` is shown honestly, never guessed.
public enum ProductAvailability: Sendable, Hashable {
    case inStock
    case limited(note: String?)
    case outOfStock
    case unknown

    public var label: String {
        switch self {
        case .inStock: "In stock"
        case .limited(let note): note ?? "Few left"
        case .outOfStock: "Out of stock"
        case .unknown: "Stock not reported"
        }
    }

    public var role: ZoroRole? {
        switch self {
        case .inStock: .positive
        case .limited: .attention
        case .outOfStock: .critical
        case .unknown: nil
        }
    }

    public var symbol: String {
        switch self {
        case .inStock: "checkmark.circle"
        case .limited: "exclamationmark.circle"
        case .outOfStock: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

public struct UnitPrice: Sendable, Hashable {
    public let amount: Decimal
    /// "100 g", "1 l", "piece".
    public let unit: String
    public init(amount: Decimal, unit: String) {
        self.amount = amount
        self.unit = unit
    }
}

/// Where a value came from and when. Every price, stock state and total carries one.
public struct SourceStamp: Sendable, Hashable {
    /// Store or service name as the owner knows it ("Instamart").
    public let source: String
    public let retrievedAt: Date

    public init(source: String, retrievedAt: Date) {
        self.source = source
        self.retrievedAt = retrievedAt
    }

    /// Prices older than this get an attention mark and "may have changed".
    public static let staleAfter: TimeInterval = 30 * 60

    public func isStale(now: Date) -> Bool { now.timeIntervalSince(retrievedAt) > Self.staleAfter }

    /// "From Instamart, checked 4:12 pm" today; "From Instamart, checked 12 Nov" on another day.
    public func line(now: Date, calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_IN")) -> String {
        var cal = calendar
        cal.locale = locale
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(cal.isDate(retrievedAt, inSameDayAs: now) ? "hmma" : "dMMM")
        return "From \(source), checked \(formatter.string(from: retrievedAt))"
    }
}

public struct ProductCardModel: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let brand: String?
    public let variant: String?
    public let packSize: String?
    public let quantity: Int
    public let price: Decimal
    public let unitPrice: UnitPrice?
    public let availability: ProductAvailability
    public let imageURL: URL?
    public let stamp: SourceStamp

    public init(
        id: String, name: String, brand: String?, variant: String?, packSize: String?, quantity: Int,
        price: Decimal, unitPrice: UnitPrice?, availability: ProductAvailability, imageURL: URL?, stamp: SourceStamp
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.variant = variant
        self.packSize = packSize
        self.quantity = quantity
        self.price = price
        self.unitPrice = unitPrice
        self.availability = availability
        self.imageURL = imageURL
        self.stamp = stamp
    }

    /// Line amount: price × quantity, exact.
    public var lineTotal: Decimal { price * Decimal(max(quantity, 0)) }

    /// Secondary line: brand, variant and pack size, comma-separated, skipping blanks.
    public var descriptor: String {
        [brand, variant, packSize].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }
}

/// One store column in a basket comparison. `prices[i]` is nil when item i is unavailable there.
public struct ComparisonStore: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let prices: [Decimal?]
    public let deliveryFee: Decimal?
    public let stamp: SourceStamp

    public init(id: String, name: String, prices: [Decimal?], deliveryFee: Decimal?, stamp: SourceStamp) {
        self.id = id
        self.name = name
        self.prices = prices
        self.deliveryFee = deliveryFee
        self.stamp = stamp
    }
}

/// A basket compared across stores. Totals and the best store are plain arithmetic, never a model.
public struct ComparisonTableModel: Sendable, Hashable {
    public let items: [String]
    public let stores: [ComparisonStore]

    public init(items: [String], stores: [ComparisonStore]) {
        self.items = items
        self.stores = stores
    }

    public func missingCount(_ store: ComparisonStore) -> Int {
        (0..<items.count).filter { $0 >= store.prices.count || store.prices[$0] == nil }.count
    }

    /// Sum of available item prices plus the delivery fee (if reported).
    public func total(_ store: ComparisonStore) -> Decimal {
        ZoroMoney.sum(store.prices.prefix(items.count).compactMap { $0 }) + (store.deliveryFee ?? 0)
    }

    /// The cheapest store that has every item; ties go to the first listed. nil when no store is complete.
    public var bestStoreID: String? {
        stores
            .filter { missingCount($0) == 0 }
            .min { total($0) < total($1) }?
            .id
    }
}

/// How sure ZORO is about a match or an answer.
public enum ConfidenceLevel: String, CaseIterable, Sendable {
    case high, medium, low

    public init(score: Double) {
        let s = score.isFinite ? score : 0
        self = s >= 0.8 ? .high : (s >= 0.5 ? .medium : .low)
    }

    public var label: String {
        switch self {
        case .high: "Good match"
        case .medium: "Close match"
        case .low: "Check this"
        }
    }

    public var role: ZoroRole {
        switch self {
        case .high: .positive
        case .medium: .accent
        case .low: .attention
        }
    }
}

public enum AgentActivityStatus: String, CaseIterable, Sendable {
    case queued, working, needsYou, done, failed

    public var label: String {
        switch self {
        case .queued: "Waiting to start"
        case .working: "Working"
        case .needsYou: "Needs your approval"
        case .done: "Done"
        case .failed: "Couldn't finish"
        }
    }

    public var role: ZoroRole? {
        switch self {
        case .queued: nil
        case .working: .positive
        case .needsYou: .attention
        case .done: nil
        case .failed: .critical
        }
    }
}

public struct AgentActivity: Identifiable, Sendable, Hashable {
    public let id: String
    public let agentName: String
    public let symbol: String
    public let status: AgentActivityStatus
    /// Plain sentence of what it is doing ("Comparing 6 items across 3 stores").
    public let detail: String?
    public init(id: String, agentName: String, symbol: String, status: AgentActivityStatus, detail: String?) {
        self.id = id
        self.agentName = agentName
        self.symbol = symbol
        self.status = status
        self.detail = detail
    }
}

/// Mirrors the backend privacy modes for display. Decisions are made on the server.
public enum ZoroPrivacyMode: String, CaseIterable, Sendable {
    case strictPrivate, cloudIntelligence

    public var title: String {
        switch self {
        case .strictPrivate: "Private mode"
        case .cloudIntelligence: "Cloud intelligence"
        }
    }

    public var explanation: String {
        switch self {
        case .strictPrivate: "Nothing leaves your ZORO server."
        case .cloudIntelligence: "Only what you allowed is sent out, with personal details removed."
        }
    }
}

/// Approval level as decided by the server's policy engine.
public enum ApprovalLevel: String, Sendable, CaseIterable {
    case confirm, biometric
}

public struct ApprovalDetail: Sendable, Hashable, Identifiable {
    public var id: String { label }
    public let label: String
    public let value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Exactly what will happen, shown before the owner approves.
public struct ApprovalSummary: Sendable, Hashable {
    /// One sentence in ZORO's voice: "Send this message to Asha on WhatsApp."
    public let action: String
    public let details: [ApprovalDetail]
    public let amount: Decimal?
    public let level: ApprovalLevel
    public let expiresAt: Date?
    /// For payments and orders: where the owner finishes ("You'll pay in the Instamart app.").
    public let handoffNote: String?

    public init(action: String, details: [ApprovalDetail], amount: Decimal?, level: ApprovalLevel, expiresAt: Date?, handoffNote: String?) {
        self.action = action
        self.details = details
        self.amount = amount
        self.level = level
        self.expiresAt = expiresAt
        self.handoffNote = handoffNote
    }

    /// "Expires in 1:45", or nil when there is no expiry. "Expired" once past.
    public func expiryText(now: Date) -> String? {
        guard let expiresAt else { return nil }
        let remaining = Int(expiresAt.timeIntervalSince(now).rounded(.down))
        guard remaining > 0 else { return "Expired. Ask again to approve." }
        return String(format: "Expires in %d:%02d", remaining / 60, remaining % 60)
    }
}
