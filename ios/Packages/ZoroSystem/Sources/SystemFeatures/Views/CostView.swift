import Charts
import SwiftUI
import ZoroCore
import ZoroDesign

/// Cost dashboard. Costs are US dollars as the backend reports them: the trend uses ZoroDesign's chart
/// with `.usDollars`; the breakdown bars stay local because they keep the server's order and tint "Other".
public struct CostView: View {
    @Bindable var model: CostViewModel

    public init(model: CostViewModel) { self.model = model }

    public var body: some View {
        ScreenScroll {
            Text("Costs").zoroText(.title).accessibilityAddTraits(.isHeader)
            Text("What cloud models cost. Amounts are in US dollars, as your providers bill them.")
                .zoroText(.detail).foregroundStyle(.secondary)
            PhaseView(phase: model.phase, loadingMessage: "Loading costs.", emptyMessage: model.emptyMessage, retry: { await model.load() }) {
                loaded
            }
        }
        .navigationTitle("Costs")
        .systemInlineTitle()
        .task { if model.phase == .idle { await model.load() } }
        .refreshable { await model.load() }
    }

    @ViewBuilder private var loaded: some View {
        if let note = model.partialNote { NoticeBanner(notice: .failure(note), dismiss: {}) }
        if let total = model.totalCost {
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                    Text("Total").zoroText(.detail).foregroundStyle(.secondary)
                    Text(SystemFormat.usd(total)).zoroText(.amountHero).lineLimit(1).minimumScaleFactor(0.7)
                    if let current = model.current {
                        Text("\(SystemFormat.count(current.requests)) requests, \(SystemFormat.count(current.inputTokens)) tokens in, \(SystemFormat.count(current.outputTokens)) tokens out.")
                            .zoroText(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZoroSpace.s.value) {
                ForEach(CostViewModel.groups, id: \.self) { group in
                    ZoroChip("By \(CostViewModel.title(group).lowercased())", isSelected: model.selected == group) { model.selected = group }
                }
            }
        }
        if let breakdown = model.current {
            if model.selected == .day && model.trend.count > 1 {
                ZoroCard { CostTrendChart(points: model.trend) }
            } else if !breakdown.isEmpty {
                ZoroCard { CostBarChart(lines: breakdown.lines) }
            }
            if breakdown.isEmpty {
                ZoroCard { ZoroStateView(.empty, message: "Nothing to show by \(CostViewModel.title(model.selected).lowercased()) yet.") }
            } else {
                ZoroCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(breakdown.lines.enumerated()), id: \.element.id) { index, line in
                            if index > 0 { RowDivider() }
                            InfoRow(line.label, detail: "\(SystemFormat.count(line.requests)) requests, \(SystemFormat.count(line.inputTokens + line.outputTokens)) tokens, \(percent(line.share))") {
                                Text(SystemFormat.usd(line.cost)).zoroText(.amount).lineLimit(1).minimumScaleFactor(0.7)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if !breakdown.totalsMatch {
                    Text("The rows add up to \(SystemFormat.usd(breakdown.computedTotal)), not the reported total. Some rows may be filtered.")
                        .zoroText(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            ZoroCard { ZoroStateView(.error, message: "Couldn't load costs by \(CostViewModel.title(model.selected).lowercased()). Reload to try again.", action: ZoroStateAction("Try again") { Task { await model.load() } }) }
        }
    }

    private func percent(_ share: Decimal) -> String {
        let value = NSDecimalNumber(decimal: share * 100).doubleValue
        return String(format: "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// Horizontal bars, largest first, dollar amount at the bar end. Marks use `Double` only for position.
struct CostBarChart: View {
    let lines: [CostLine]

    var body: some View {
        Chart(lines) { line in
            BarMark(x: .value("Cost", ZoroChartMath.plotValue(line.cost)), y: .value("Item", line.label))
                .foregroundStyle(line.isOther ? AnyShapeStyle(.moonstone) : AnyShapeStyle(.neel))
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(SystemFormat.usd(line.cost)).zoroText(.caption).foregroundStyle(.secondary)
                }
                .accessibilityLabel(line.label)
                .accessibilityValue(SystemFormat.usd(line.cost))
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.subheadline) } }
        .frame(minHeight: CGFloat(max(lines.count, 1)) * 36)
    }
}

/// Daily spend as a line: ZoroDesign's trend chart, written in US dollars.
struct CostTrendChart: View {
    let points: [DailyCost]

    var body: some View {
        TrendLineChart(points.map { TrendPoint(date: $0.date, amount: $0.cost) }, formatter: .usDollars)
            .frame(minHeight: 180)
    }
}
