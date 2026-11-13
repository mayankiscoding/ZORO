import Charts
import SwiftUI

// Swift Charts wrappers. Values arrive as `Decimal` and are converted to Double only to place marks;
// every number shown as text is formatted from the original Decimal with a `ZoroAmountFormatter`
// (rupees by default; pass `.usDollars` or `currencyCode: "USD"` for model costs).

public struct CategoryValue: Identifiable, Sendable, Hashable {
    public var id: String { label }
    public let label: String
    public let amount: Decimal
    public init(label: String, amount: Decimal) {
        self.label = label
        self.amount = amount
    }
}

public struct TrendPoint: Identifiable, Sendable, Hashable {
    public var id: Date { date }
    public let date: Date
    public let amount: Decimal
    public init(date: Date, amount: Decimal) {
        self.date = date
        self.amount = amount
    }
}

public enum ZoroChartMath {
    /// Plotting position only. Never use the result for display or arithmetic.
    public static func plotValue(_ amount: Decimal) -> Double { NSDecimalNumber(decimal: amount).doubleValue }

    /// Shares of a whole as fractions (0...1), for ring labels. Negative values count as 0.
    public static func shares(_ values: [Decimal]) -> [Double] {
        let clean = values.map { max($0, 0) }
        let total = ZoroMoney.sum(clean)
        guard total > 0 else { return clean.map { _ in 0 } }
        return clean.map { plotValue($0 / total) }
    }

    /// Axis tick text: whole units for rupees and amounts of one or more; the formatter's precision below one.
    public static func axisLabel(_ tick: Double, formatter: ZoroAmountFormatter) -> String {
        if formatter.currencyCode == "INR" || abs(tick) >= 1 {
            return formatter.string(Decimal(Int(tick.rounded())), style: .whole)
        }
        return formatter.string(Decimal(string: String(format: "%.4f", tick)) ?? 0)
    }

    /// Ring slice colours, in order: neel, mor, genda, moonstone, then neel again at lower opacity.
    public static func sliceHue(_ index: Int) -> (hue: ZoroHue, opacity: Double) {
        let hues: [ZoroHue] = [.neel, .mor, .genda, .moonstone]
        let round = index / hues.count
        return (hues[index % hues.count], max(1 - Double(round) * 0.35, 0.3))
    }
}

/// Horizontal bars by category, largest first, amount at the bar end.
public struct CategoryBarChart: View {
    let values: [CategoryValue]
    let formatter: ZoroAmountFormatter
    public init(_ values: [CategoryValue], formatter: ZoroAmountFormatter = .rupees) {
        self.values = values
        self.formatter = formatter
    }
    public init(_ values: [CategoryValue], currencyCode: String) {
        self.init(values, formatter: .currency(code: currencyCode))
    }

    public var body: some View {
        let sorted = values.sorted { $0.amount > $1.amount }
        Chart(sorted) { value in
            BarMark(x: .value("Amount", ZoroChartMath.plotValue(value.amount)), y: .value("Category", value.label))
                .foregroundStyle(.neel)
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(formatter.string(value.amount, style: formatter.currencyCode == "INR" ? .whole : .exact))
                        .zoroText(.caption).foregroundStyle(.secondary)
                }
                .accessibilityLabel(value.label)
                .accessibilityValue(formatter.string(value.amount, style: .exact))
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.subheadline) } }
        .frame(minHeight: CGFloat(max(sorted.count, 1)) * 36)
    }
}

/// A single trend line with a soft area beneath. The last point is marked.
public struct TrendLineChart: View {
    let points: [TrendPoint]
    let formatter: ZoroAmountFormatter
    public init(_ points: [TrendPoint], formatter: ZoroAmountFormatter = .rupees) {
        self.points = points.sorted { $0.date < $1.date }
        self.formatter = formatter
    }
    public init(_ points: [TrendPoint], currencyCode: String) {
        self.init(points, formatter: .currency(code: currencyCode))
    }

    public var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Date", point.date), y: .value("Amount", ZoroChartMath.plotValue(point.amount)))
                    .foregroundStyle(ZoroColor(.mor).opacity(0.14))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", point.date), y: .value("Amount", ZoroChartMath.plotValue(point.amount)))
                    .foregroundStyle(.mor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                    .accessibilityValue(formatter.string(point.amount))
            }
            if let last = points.last {
                PointMark(x: .value("Date", last.date), y: .value("Amount", ZoroChartMath.plotValue(last.amount)))
                    .foregroundStyle(.genda)
                    .symbolSize(60)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine().foregroundStyle(ZoroNeutral.hairline)
                AxisValueLabel {
                    // Axis ticks are plotting positions, not data.
                    if let tick = value.as(Double.self) {
                        Text(ZoroChartMath.axisLabel(tick, formatter: formatter))
                    }
                }
            }
        }
        .frame(minHeight: 160)
    }
}

/// Allocation as a ring, with the total in the middle in SF Pro Expanded.
public struct AllocationRingChart: View {
    let values: [CategoryValue]
    let formatter: ZoroAmountFormatter
    public init(_ values: [CategoryValue], formatter: ZoroAmountFormatter = .rupees) {
        self.values = values
        self.formatter = formatter
    }
    public init(_ values: [CategoryValue], currencyCode: String) {
        self.init(values, formatter: .currency(code: currencyCode))
    }

    public var body: some View {
        let total = ZoroMoney.sum(values.map { max($0.amount, 0) })
        HStack(alignment: .center, spacing: ZoroSpace.l.value) {
            Chart(Array(values.enumerated()), id: \.element.id) { index, value in
                let slice = ZoroChartMath.sliceHue(index)
                SectorMark(angle: .value("Amount", ZoroChartMath.plotValue(max(value.amount, 0))), innerRadius: .ratio(0.68), angularInset: 1.5)
                    .foregroundStyle(ZoroColor(slice.hue).opacity(slice.opacity))
                    .cornerRadius(3)
                    .accessibilityLabel(value.label)
                    .accessibilityValue(formatter.string(value.amount))
            }
            .chartBackground { _ in
                Group {
                    if formatter.currencyCode == "INR" {
                        MoneyText(total, style: .whole, textStyle: .amount)
                    } else {
                        Text(formatter.string(total, style: .whole)).zoroText(.amount)
                    }
                }
                .padding(ZoroSpace.l.value)
            }
            .frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                let shares = ZoroChartMath.shares(values.map(\.amount))
                ForEach(Array(values.enumerated()), id: \.element.id) { index, value in
                    let slice = ZoroChartMath.sliceHue(index)
                    HStack(spacing: ZoroSpace.s.value) {
                        Circle().fill(ZoroColor(slice.hue).opacity(slice.opacity)).frame(width: 8, height: 8)
                        Text(value.label).zoroText(.detail)
                        Spacer(minLength: ZoroSpace.s.value)
                        Text(shares[index], format: .percent.precision(.fractionLength(0))).zoroText(.detail).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
