#if DEBUG
import Foundation

/// Specimen content for the design gallery and snapshots only. Debug builds only, every source is
/// named "Specimen", and nothing here reaches a feature screen. Real screens get their values from
/// the backend with a real source and time.
public enum GallerySpecimens {
    /// A fixed clock so specimens and snapshots are reproducible.
    public static let now = Date(timeIntervalSince1970: 1_794_550_000)

    public static func stamp(_ name: String, minutesAgo: Double) -> SourceStamp {
        SourceStamp(source: name, retrievedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    public static let satellites: [OrbSatellite] = [
        OrbSatellite(id: "shopping", name: "Shopping", symbol: "basket"),
        OrbSatellite(id: "finance", name: "Finance", symbol: "indianrupeesign"),
        OrbSatellite(id: "memory", name: "Memory", symbol: "brain"),
    ]

    public static let product = ProductCardModel(
        id: "specimen-1", name: "Toned milk", brand: "Specimen dairy", variant: "Homogenised", packSize: "500 ml",
        quantity: 2, price: Decimal(string: "29")!, unitPrice: UnitPrice(amount: Decimal(string: "5.80")!, unit: "100 ml"),
        availability: .inStock, imageURL: nil, stamp: stamp("Specimen store A", minutesAgo: 6)
    )

    public static let staleProduct = ProductCardModel(
        id: "specimen-2", name: "Basmati rice", brand: "Specimen mills", variant: nil, packSize: "1 kg",
        quantity: 1, price: Decimal(string: "149.50")!, unitPrice: nil,
        availability: .limited(note: "3 left"), imageURL: nil, stamp: stamp("Specimen store B", minutesAgo: 95)
    )

    public static let comparison = ComparisonTableModel(
        items: ["Toned milk, 2 × 500 ml", "Basmati rice, 1 kg", "Tomatoes, 500 g"],
        stores: [
            ComparisonStore(id: "a", name: "Store A", prices: [Decimal(58), Decimal(string: "149.50")!, Decimal(24)],
                            deliveryFee: 0, stamp: stamp("Specimen store A", minutesAgo: 6)),
            ComparisonStore(id: "b", name: "Store B", prices: [Decimal(56), Decimal(155), nil],
                            deliveryFee: Decimal(25), stamp: stamp("Specimen store B", minutesAgo: 8)),
            ComparisonStore(id: "c", name: "Store C", prices: [Decimal(60), Decimal(142), Decimal(30)],
                            deliveryFee: Decimal(15), stamp: stamp("Specimen store C", minutesAgo: 5)),
        ]
    )

    public static let activities: [AgentActivity] = [
        AgentActivity(id: "1", agentName: "Shopping", symbol: "basket", status: .working, detail: "Comparing 3 items across 3 stores"),
        AgentActivity(id: "2", agentName: "Finance", symbol: "indianrupeesign", status: .done, detail: "Read this month's grocery spend"),
        AgentActivity(id: "3", agentName: "Communications", symbol: "message", status: .needsYou, detail: "Draft ready to send"),
        AgentActivity(id: "4", agentName: "Music", symbol: "music.note", status: .failed, detail: "Spotify needs you to sign in again"),
    ]

    public static let approval = ApprovalSummary(
        action: "Send this message to Asha on WhatsApp.",
        details: [
            ApprovalDetail(label: "To", value: "Asha (specimen contact)"),
            ApprovalDetail(label: "Message", value: "Running 10 minutes late, start without me."),
        ],
        amount: nil, level: .confirm, expiresAt: nil, handoffNote: nil
    )

    public static let paymentHandoff = ApprovalSummary(
        action: "Open the basket in Store A to pay.",
        details: [
            ApprovalDetail(label: "Items", value: "3"),
            ApprovalDetail(label: "Delivery", value: "Free"),
        ],
        amount: Decimal(string: "231.50")!, level: .biometric, expiresAt: now.addingTimeInterval(105),
        handoffNote: "You'll pay in Store A's app. ZORO never pays for you."
    )

    public static let categories: [CategoryValue] = [
        CategoryValue(label: "Groceries", amount: Decimal(string: "8420.50")!),
        CategoryValue(label: "Dining", amount: Decimal(3260)),
        CategoryValue(label: "Travel", amount: Decimal(1890)),
        CategoryValue(label: "Bills", amount: Decimal(5400)),
    ]

    public static let allocation: [CategoryValue] = [
        CategoryValue(label: "Equity", amount: Decimal(540_000)),
        CategoryValue(label: "Debt", amount: Decimal(210_000)),
        CategoryValue(label: "Gold", amount: Decimal(90_000)),
        CategoryValue(label: "Cash", amount: Decimal(60_000)),
    ]

    public static let trend: [TrendPoint] = [12_400, 13_100, 11_800, 14_250, 13_600, 15_020].enumerated().map { i, v in
        TrendPoint(date: now.addingTimeInterval(Double(i - 5) * 30 * 86_400), amount: Decimal(v))
    }

    /// Smooth, reproducible level curves for the rekha.
    public static func levels(count: Int, seed: Double) -> [Double] {
        (0..<count).map { i in
            let x = Double(i)
            let v = 0.5 + 0.3 * sin(x * 0.45 + seed) + 0.2 * sin(x * 1.3 + seed * 2)
            return max(0, min(1, v * (0.4 + 0.6 * abs(sin(x * 0.11 + seed)))))
        }
    }
}
#endif
