import Foundation
import Testing
@testable import ZoroDesign

private func d(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Money formatting")
struct MoneyTests {
    @Test("Indian digit grouping", arguments: [
        ("0", "₹0.00"), ("7", "₹7.00"), ("999", "₹999.00"), ("1000", "₹1,000.00"), ("99999", "₹99,999.00"),
        ("100000", "₹1,00,000.00"), ("1234567.5", "₹12,34,567.50"), ("12345678.05", "₹1,23,45,678.05"),
        ("1000000000", "₹1,00,00,00,000.00"),
    ])
    func grouping(input: String, expected: String) {
        #expect(ZoroMoney.format(d(input)) == expected)
    }

    @Test("negative amounts use the typographic minus before the rupee sign")
    func negative() {
        #expect(ZoroMoney.format(d("-2500")) == "\u{2212}₹2,500.00")
        #expect(ZoroMoney.format(d("-0.001")) == "₹0.00") // rounds to zero: no minus
        #expect(ZoroMoney.format(d("250"), showsPlus: true) == "+₹250.00")
        #expect(ZoroMoney.format(d("0"), showsPlus: true) == "₹0.00")
    }

    @Test("rounds half away from zero to paise, exactly")
    func rounding() {
        #expect(ZoroMoney.format(d("0.005")) == "₹0.01")
        #expect(ZoroMoney.format(d("0.004")) == "₹0.00")
        #expect(ZoroMoney.format(d("-1.005")) == "\u{2212}₹1.01")
        // A value that is inexact in binary floating point stays exact.
        #expect(ZoroMoney.format(d("0.1") + d("0.2")) == "₹0.30")
        #expect(ZoroMoney.format(d("1234567890123.45")) == "₹12,34,56,78,90,123.45")
    }

    @Test("compact and whole styles")
    func styles() {
        #expect(ZoroMoney.format(d("1500"), style: .compact) == "₹1,500")
        #expect(ZoroMoney.format(d("1500.5"), style: .compact) == "₹1,500.50")
        #expect(ZoroMoney.format(d("1500.001"), style: .compact) == "₹1,500")
        #expect(ZoroMoney.format(d("1500.5"), style: .whole) == "₹1,501")
        #expect(ZoroMoney.format(d("-1500.4"), style: .whole) == "\u{2212}₹1,500")
        #expect(ZoroMoney.unitPrice(d("62"), per: "100 g") == "₹62 per 100 g")
    }

    @Test func groupIndianShortStrings() {
        #expect(ZoroMoney.groupIndian("") == "")
        #expect(ZoroMoney.groupIndian("12") == "12")
        #expect(ZoroMoney.groupIndian("1234") == "1,234")
        #expect(ZoroMoney.groupIndian("123456") == "1,23,456")
    }
}

@Suite("Component models")
struct ComponentModelTests {
    let now = Date(timeIntervalSince1970: 1_794_550_000)

    func stamp(_ minutes: Double) -> SourceStamp {
        SourceStamp(source: "Store", retrievedAt: now.addingTimeInterval(-minutes * 60))
    }

    @Test("basket comparison: exact totals, best complete store, ties to the first")
    func comparison() {
        let model = ComparisonTableModel(items: ["a", "b"], stores: [
            ComparisonStore(id: "x", name: "X", prices: [d("10.10"), d("20.20")], deliveryFee: d("5"), stamp: stamp(1)),
            ComparisonStore(id: "y", name: "Y", prices: [d("1"), nil], deliveryFee: 0, stamp: stamp(1)),
            ComparisonStore(id: "z", name: "Z", prices: [d("15.30"), d("20")], deliveryFee: nil, stamp: stamp(1)),
        ])
        #expect(model.total(model.stores[0]) == d("35.30"))
        #expect(model.total(model.stores[1]) == d("1"))
        #expect(model.missingCount(model.stores[1]) == 1)
        #expect(model.bestStoreID == "x") // y is cheaper but incomplete; z ties x and comes later
    }

    @Test("no complete store means no best store; short price arrays count as missing")
    func noBest() {
        let model = ComparisonTableModel(items: ["a", "b"], stores: [
            ComparisonStore(id: "x", name: "X", prices: [d("10")], deliveryFee: nil, stamp: stamp(1)),
            ComparisonStore(id: "y", name: "Y", prices: [nil, nil], deliveryFee: nil, stamp: stamp(1)),
        ])
        #expect(model.missingCount(model.stores[0]) == 1)
        #expect(model.missingCount(model.stores[1]) == 2)
        #expect(model.bestStoreID == nil)
        #expect(ComparisonTableModel(items: [], stores: []).bestStoreID == nil)
    }

    @Test("product line total and descriptor")
    func product() {
        let p = ProductCardModel(id: "1", name: "Milk", brand: "B", variant: "", packSize: "500 ml", quantity: 3,
                                 price: d("29.99"), unitPrice: nil, availability: .unknown, imageURL: nil, stamp: stamp(1))
        #expect(p.lineTotal == d("89.97"))
        #expect(p.descriptor == "B, 500 ml")
        #expect(p.availability.label == "Stock not reported")
        #expect(p.availability.role == nil)
    }

    @Test("source line and staleness")
    func source() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let fresh = stamp(5), stale = stamp(31), yesterday = stamp(60 * 30)
        #expect(!fresh.isStale(now: now))
        #expect(stale.isStale(now: now))
        let today = fresh.line(now: now, calendar: cal)
        #expect(today.hasPrefix("From Store, checked "))
        #expect(today.contains(":"))
        let older = yesterday.line(now: now, calendar: cal)
        #expect(older.hasPrefix("From Store, checked "))
        #expect(!older.contains(":"))
    }

    @Test("confidence thresholds", arguments: [(0.95, ConfidenceLevel.high), (0.8, .high), (0.79, .medium), (0.5, .medium), (0.49, .low), (-3, .low), (.nan, .low)])
    func confidence(score: Double, level: ConfidenceLevel) {
        #expect(ConfidenceLevel(score: score) == level)
    }

    @Test("approval expiry text counts down and says when it expired")
    func expiry() {
        let s = ApprovalSummary(action: "x", details: [], amount: nil, level: .biometric, expiresAt: now.addingTimeInterval(105), handoffNote: nil)
        #expect(s.expiryText(now: now) == "Expires in 1:45")
        #expect(s.expiryText(now: now.addingTimeInterval(200)) == "Expired. Ask again to approve.")
        let none = ApprovalSummary(action: "x", details: [], amount: nil, level: .confirm, expiresAt: nil, handoffNote: nil)
        #expect(none.expiryText(now: now) == nil)
    }

    @Test("chart shares are exact fractions and ignore negatives")
    func shares() {
        let s = ZoroChartMath.shares([d("1"), d("3"), d("-5")])
        #expect(s == [0.25, 0.75, 0])
        #expect(ZoroChartMath.shares([0, 0]) == [0, 0])
        #expect(ZoroChartMath.sliceHue(0).hue == .neel)
        #expect(ZoroChartMath.sliceHue(4).opacity < 1)
    }
}

@Suite("Amount formatter")
struct AmountFormatterTests {
    @Test func rupeesAndDollarsAreFormattedExactly() {
        #expect(ZoroAmountFormatter.rupees.string(Decimal(string: "123456.5")!) == "₹1,23,456.50")
        #expect(ZoroAmountFormatter.usDollars.string(Decimal(string: "0.00421")!) == "$0.0042")
        #expect(ZoroAmountFormatter.usDollars.string(Decimal(string: "1234567.505")!) == "$1,234,567.51")
        #expect(ZoroAmountFormatter.usDollars.string(Decimal(string: "12.5")!, style: .whole) == "$13")
        #expect(ZoroAmountFormatter.usDollars.string(Decimal(string: "-0.5")!) == "\u{2212}$0.5000")
        #expect(ZoroAmountFormatter.usDollars.string(0) == "$0.00")
        #expect(ZoroAmountFormatter.currency(code: "usd").currencyCode == "USD")
        #expect(ZoroAmountFormatter.currency(code: "INR").string(1500, style: .compact) == "₹1,500")
        #expect(ZoroAmountFormatter.currency(code: "EUR").string(Decimal(string: "1234.5")!) == "EUR 1,234.50")
    }

    @Test func axisLabelsFollowTheCurrency() {
        #expect(ZoroChartMath.axisLabel(150_000, formatter: .rupees) == "₹1,50,000")
        #expect(ZoroChartMath.axisLabel(0.25, formatter: .usDollars) == "$0.2500")
        #expect(ZoroChartMath.axisLabel(12.4, formatter: .usDollars) == "$12")
    }

    @MainActor @Test func chartsAndCapsuleAcceptACurrency() {
        _ = CategoryBarChart([CategoryValue(label: "gpt", amount: 1)], currencyCode: "USD")
        _ = TrendLineChart([], formatter: .usDollars)
        _ = AllocationRingChart([], currencyCode: "INR")
        _ = ZoroCapsuleLabel(text: "High risk", role: .attention)
    }
}
