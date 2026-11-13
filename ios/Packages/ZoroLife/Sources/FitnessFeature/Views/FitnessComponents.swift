import Charts
import LifeSupport
import SwiftUI
import ZoroDesign

/// A grid of figures. Wraps to the available width and the user's text size.
struct FigureGrid: View {
    let tiles: [FigureTile]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: ZoroSpace.m.value, alignment: .topLeading)], alignment: .leading, spacing: ZoroSpace.m.value) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                    Text(tile.label).zoroText(.caption).foregroundStyle(.secondary)
                    Text(tile.value).zoroText(.amount).lineLimit(1).minimumScaleFactor(0.7)
                    if let unit = tile.unit { Text(unit).zoroText(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tile.accessibilityLabel)
            }
        }
    }
}

/// The source and freshness line under a figure, with the stale warning when there is one.
struct FreshnessFooter: View {
    let source: String
    let freshness: FitnessFreshness
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
            Text(FreshnessFormatter.line(source: source, freshness: freshness, now: now))
                .zoroText(.caption).foregroundStyle(.secondary)
            if let latest = FreshnessFormatter.latestDay(freshness) {
                Text(latest).zoroText(.caption).foregroundStyle(.secondary)
            }
            if let note = FreshnessFormatter.staleNote(freshness) {
                Label(note, systemImage: "clock.badge.exclamationmark")
                    .zoroText(.caption)
                    .foregroundStyle(ZoroRole.attention.hue.color(scheme: scheme, contrast: .increased))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @Environment(\.colorScheme) private var scheme
}

/// One section of the fitness screen: a header, then loading, error, "not available yet" or the content, then the source line.
struct FitnessSection<Value: FitnessSourced & Equatable & Sendable, Content: View>: View {
    let title: String
    let state: Loadable<Value>
    let now: Date
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
            ZoroSectionHeader(title)
            ZoroCard {
                switch state {
                case .idle, .loading:
                    ZoroStateView(.loading, message: "Loading \(title.lowercased()).")
                case .failed(let failure):
                    ZoroStateView(
                        failure.kind == .disconnected ? .disconnected : .error, message: failure.message,
                        action: failure.retryable ? ZoroStateAction("Try again", perform: retry) : nil)
                case .loaded(let value):
                    VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                        if value.sourcing.available {
                            content(value)
                        } else {
                            ZoroStateView(.empty, message: FitnessUnavailableText.sentence(reason: value.sourcing.reason))
                        }
                        FreshnessFooter(source: value.sourcing.dataSource, freshness: value.sourcing.freshness, now: now)
                    }
                }
            }
        }
    }
}

/// Bars for weekly figures. Heights are plotting positions; the exact text is on each bar's VoiceOver value.
struct FigureBarChart: View {
    let bars: [FigureBar]
    let unit: String

    var body: some View {
        Chart(bars) { bar in
            BarMark(x: .value("Week", bar.shortLabel), y: .value(unit, bar.value))
                .foregroundStyle(.mor)
                .cornerRadius(4)
                .accessibilityLabel(bar.label)
                .accessibilityValue(bar.valueText)
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine().foregroundStyle(ZoroNeutral.hairline)
                AxisValueLabel()
            }
        }
        .frame(minHeight: 150)
        .accessibilityLabel(unit)
    }
}

/// Wraps content in a two-column grid when there is room (Mac, iPad), one column otherwise.
struct AdaptiveColumns<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 340), spacing: ZoroSpace.l.value, alignment: .top)], alignment: .leading,
            spacing: ZoroSpace.l.value
        ) { content }
    }
}
