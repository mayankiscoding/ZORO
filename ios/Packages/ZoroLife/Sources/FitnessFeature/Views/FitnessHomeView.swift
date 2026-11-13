import LifeSupport
import SwiftUI
import ZoroCore
import ZoroDesign

/// The Fitness space: today, week against week, trends, running, records, consistency, the running-plan builder, a data source and
/// freshness line on every figure, Health access and Sync now. Reads its services from the environment.
public struct FitnessHomeView: View {
    @Environment(\.zoroServices) private var services
    @State private var model: FitnessViewModel?

    public init() {}

    public var body: some View {
        Group {
            if let model {
                FitnessHomeContent(model: model, services: services)
            } else {
                ZoroStateView(.loading, message: "Loading your fitness figures.")
            }
        }
        .task {
            if model == nil { model = FitnessViewModel(services: services) }
            await model?.load()
        }
    }
}

/// The screen for a given model. Internal so previews and tests can pass a model built on fakes.
struct FitnessHomeContent: View {
    @Bindable var model: FitnessViewModel
    let services: ZoroServices
    @State private var showingPlan = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoroSpace.xl.value) {
                header
                syncCard
                switch model.screen {
                case .idle, .loading:
                    ZoroStateView(.loading, message: "Loading your fitness figures.")
                case .failed(let failure):
                    ZoroStateView(
                        failure.kind == .disconnected ? .disconnected : .error, message: failure.message,
                        action: ZoroStateAction("Try again") { Task { await model.load() } })
                case .empty:
                    ZoroStateView(
                        .empty,
                        message: model.canSyncFromThisDevice
                            ? "Nothing has been synced from Apple Health yet. Tap Sync now to send your recent activity to your server."
                            : "Nothing has been synced yet. Open ZORO on your iPhone and tap Sync now; the figures appear here.")
                case .loaded:
                    sections
                }
                Text(FitnessCardModel.disclaimer)
                    .zoroText(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, ZoroSpace.l.value)
            .padding(.vertical, ZoroSpace.l.value)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ZoroNeutral.background)
        .navigationTitle("Fitness")
        .refreshable { await model.load() }
        .sheet(isPresented: $showingPlan) {
            RunningPlanView(model: RunningPlanViewModel(server: FitnessAPIClient(api: services.api)))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
            Text("Fitness").zoroText(.title).accessibilityAddTraits(.isHeader)
            Text("Your activity from Apple Health, with where each figure came from and when it was synced.")
                .zoroText(.body).foregroundStyle(.secondary)
        }
    }

    private var syncCard: some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                if let freshness = model.freshness {
                    Text(
                        freshness.neverSynced
                            ? "Nothing has been synced yet."
                            : "Last synced \(FreshnessFormatter.age(freshness, now: model.now) ?? "a while ago").")
                        .zoroText(.heading)
                }
                Text(model.syncNote).zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.canSyncFromThisDevice {
                    Button(model.syncButtonTitle) { Task { await model.syncNow() } }
                        .buttonStyle(.zoroPrimary)
                        .disabled(model.syncState.isRunning)
                        .frame(maxWidth: 320)
                }
                switch model.syncState {
                case .syncing:
                    ZoroStateView(.loading, message: "Reading Health and sending daily totals to your server.")
                case .done(let result):
                    Label(SyncPresenter.summary(result), systemImage: "checkmark.circle").zoroText(.detail)
                case .failed(let failure):
                    ZoroStateView(failure.kind == .disconnected ? .disconnected : .error, message: failure.message)
                case .idle:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder private var sections: some View {
        AdaptiveColumns {
            FitnessSection(title: "Today", state: model.today, now: model.now, retry: { Task { await model.load() } }) { s in
                VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                    FigureGrid(tiles: TodayPresenter.tiles(s))
                    if let missing = TodayPresenter.missingNote(s) {
                        Text(missing).zoroText(.detail).foregroundStyle(.secondary)
                    }
                    ForEach(s.workouts) { w in
                        Label(TodayPresenter.workoutLine(w), systemImage: "figure.run").zoroText(.detail)
                    }
                    ForEach(ObservationText.sentences(s.sourcing.observations), id: \.self) { sentence in
                        Text(sentence).zoroText(.zoroBody).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            FitnessSection(title: "This week against last week", state: model.weekly, now: model.now, retry: { Task { await model.load() } }) { w in
                VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                    if let range = WeeklyPresenter.rangeLine(w) { Text(range).zoroText(.caption).foregroundStyle(.secondary) }
                    ForEach(WeeklyPresenter.rows(w)) { row in
                        ComparisonRowView(row: row)
                    }
                    Text(WeeklyPresenter.workoutsLine(w)).zoroText(.detail)
                }
            }
            trendSection
            deviceWeekSection
            FitnessSection(title: "Running", state: model.running, now: model.now, retry: { Task { await model.load() } }) { r in
                VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                    FigureGrid(tiles: RunningPresenter.tiles(r))
                    Text(RunningPresenter.paceSentence(r)).zoroText(.detail)
                    if !r.weekly.isEmpty {
                        Text("Distance each week").zoroText(.caption).foregroundStyle(.secondary)
                        FigureBarChart(bars: RunningPresenter.weeklyBars(r), unit: "Kilometres")
                    }
                }
            }
            FitnessSection(title: "Personal records", state: model.records, now: model.now, retry: { Task { await model.load() } }) { r in
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    ForEach(RecordsPresenter.rows(r)) { row in
                        VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.label).zoroText(.body)
                                Spacer(minLength: ZoroSpace.s.value)
                                Text(row.value).zoroText(.amount)
                            }
                            Text(row.detail).zoroText(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                    }
                    if !r.note.isEmpty { Text(r.note).zoroText(.caption).foregroundStyle(.secondary) }
                }
            }
            FitnessSection(title: "Consistency", state: model.consistency, now: model.now, retry: { Task { await model.load() } }) { c in
                VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                    FigureGrid(tiles: ConsistencyPresenter.tiles(c))
                    Text(ConsistencyPresenter.summary(c)).zoroText(.detail).foregroundStyle(.secondary)
                    if !c.weeks.isEmpty {
                        Text("Sessions each week").zoroText(.caption).foregroundStyle(.secondary)
                        FigureBarChart(bars: ConsistencyPresenter.weeklyBars(c), unit: "Sessions")
                    }
                }
            }
        }
        Button("Build a running plan") { showingPlan = true }
            .buttonStyle(.zoroSecondary).frame(maxWidth: 320)
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
            ZoroSectionHeader("Trend", detail: "The direction of one figure over the last \(model.trendDays) days.")
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ZoroSpace.s.value) {
                            ForEach(TrendMetric.allCases) { metric in
                                ZoroChip(metric.title, isSelected: metric == model.trendMetric) {
                                    Task { await model.selectTrend(metric: metric) }
                                }
                            }
                        }
                    }
                    switch model.trend {
                    case .idle, .loading:
                        ZoroStateView(.loading, message: "Working out the trend.")
                    case .failed(let failure):
                        ZoroStateView(
                            failure.kind == .disconnected ? .disconnected : .error, message: failure.message,
                            action: ZoroStateAction("Try again") { Task { await model.selectTrend() } })
                    case .loaded(let trend):
                        let summary = TrendPresenter.summary(trend)
                        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                            Label(summary.headline, systemImage: summary.symbol).zoroText(.heading)
                            Text(summary.detail).zoroText(.detail).foregroundStyle(.secondary)
                            FreshnessFooter(source: trend.sourcing.dataSource, freshness: trend.sourcing.freshness, now: model.now)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deviceWeekSection: some View {
        if case .loaded(let week) = model.thisWeekOnDevice {
            let bars = DeviceWeekPresenter.stepBars(week, timeZone: .current)
            if !bars.isEmpty {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    ZoroSectionHeader("Steps this week, on this iPhone")
                    ZoroCard {
                        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                            FigureBarChart(bars: bars, unit: "Steps")
                            Text(DeviceWeekPresenter.sourceLine(week, now: model.now, timeZone: .current))
                                .zoroText(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct ComparisonRowView: View {
    let row: ComparisonRow

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label).zoroText(.body)
                Spacer(minLength: ZoroSpace.s.value)
                Text(row.current).zoroText(.detail).multilineTextAlignment(.trailing)
            }
            HStack(spacing: ZoroSpace.xs.value) {
                Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
                Text(row.change)
            }
            .zoroText(.caption).foregroundStyle(.secondary)
            if row.direction != .unknown {
                Text(row.previous).zoroText(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var symbol: String {
        switch row.direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .same: "arrow.right"
        case .unknown: "ellipsis"
        }
    }
}
