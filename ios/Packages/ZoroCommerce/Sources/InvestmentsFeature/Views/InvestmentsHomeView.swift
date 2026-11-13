import CommerceSupport
import SwiftUI
import UniformTypeIdentifiers
import ZoroCore
import ZoroDesign

/// The Investments space. Information from the owner's own data, never advice; no orders are placed.
public struct InvestmentsHomeView: View {
    @Environment(\.zoroServices) private var services
    @Environment(\.commerceFileUploader) private var uploader

    public init() {}

    public var body: some View {
        InvestmentsSpace(client: InvestmentsClient(api: services.api, uploader: uploader), services: services)
    }
}

enum InvestmentsSection: String, CaseIterable, Identifiable {
    case portfolio, watchlists, analysis, backtest, ticket
    var id: String { rawValue }
    var title: String {
        switch self {
        case .portfolio: "Portfolio"
        case .watchlists: "Watchlists"
        case .analysis: "Analysis"
        case .backtest: "Backtest"
        case .ticket: "Order ticket"
        }
    }
}

struct InvestmentsSpace: View {
    @State private var section: InvestmentsSection = .portfolio
    @State private var portfolio: PortfolioViewModel
    @State private var watchlist: WatchlistViewModel
    @State private var analysis: StockAnalysisViewModel
    @State private var backtest: BacktestViewModel
    @State private var ticket: OrderTicketViewModel

    init(client: InvestmentsClient, services: ZoroServices) {
        _portfolio = State(initialValue: PortfolioViewModel(client: client))
        _watchlist = State(initialValue: WatchlistViewModel(client: client))
        _analysis = State(initialValue: StockAnalysisViewModel(client: client))
        _backtest = State(initialValue: BacktestViewModel(client: client))
        #if os(macOS)
        let platform = DevicePlatform.macos
        #else
        let platform = DevicePlatform.ios
        #endif
        _ticket = State(initialValue: OrderTicketViewModel(api: services.api, approvals: services.approvals, platform: platform))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                    Picker("Section", selection: $section) {
                        ForEach(InvestmentsSection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Investments section")
                    switch section {
                    case .portfolio: PortfolioSection(model: portfolio)
                    case .watchlists: WatchlistSection(model: watchlist)
                    case .analysis: AnalysisSection(model: analysis)
                    case .backtest: BacktestSection(model: backtest)
                    case .ticket: OrderTicketSection(model: ticket)
                    }
                }
                .padding(ZoroSpace.l.value)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(ZoroNeutral.background)
            .navigationTitle("Investments")
        }
    }
}

/// The not-advice line, always visible where analysis or results appear.
struct NotAdviceLine: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").zoroText(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Portfolio

struct PortfolioSection: View {
    let model: PortfolioViewModel
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            if let p = model.portfolio, model.phase == .loaded {
                PortfolioSummaryView(portfolio: p)
                if let perf = model.performance, perf.points.count > 1 {
                    ZoroCard {
                        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                            Text("Value over time").zoroText(.heading)
                            TrendLineChart(perf.points.map { TrendPoint(date: $0.takenAt, amount: $0.value) })
                        }
                    }
                }
            } else {
                PhaseStateView(model.phase, loading: "Loading your portfolio.",
                               empty: "No holdings yet. Import a holdings CSV from your broker to see your portfolio.") {
                    Task { await model.load() }
                }
            }
            importControls
        }
        .task { await model.load() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = (try? Data(contentsOf: url)) ?? Data()
            Task { await model.importHoldings(filename: url.lastPathComponent, data: data) }
        }
    }

    @ViewBuilder private var importControls: some View {
        switch model.importState {
        case .idle: EmptyView()
        case .importing: ZoroStateView(.loading, message: "Importing your holdings.")
        case .done(let message): NoticeLine(message)
        case .failed(let message): ZoroStateView(.error, message: message)
        }
        Button("Import holdings CSV") { picking = true }
            .buttonStyle(model.phase == .empty ? AnyButtonStyle(.zoroPrimary) : AnyButtonStyle(.zoroSecondary))
            .disabled(model.importState == .importing)
    }
}

/// Lets one button switch between the primary and secondary styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Portfolio summary, shared by the screen and the `portfolio` card.
public struct PortfolioSummaryView: View {
    let portfolio: PortfolioSummary

    public init(portfolio: PortfolioSummary) { self.portfolio = portfolio }

    public var body: some View {
        let p = portfolio
        let allocation = p.holdings.compactMap { h in h.value.map { CategoryValue(label: h.symbol, amount: $0) } }
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    Text("Current value").zoroText(.caption).foregroundStyle(.secondary)
                    MoneyText(p.value, textStyle: .amountHero)
                    FigureRow("Invested", value: Figures.money(p.invested))
                    FigureRow("Profit or loss", value: Figures.money(p.pnl, showsPlus: true)
                                + (p.pnlPercent.map { " (\(Figures.percent($0, places: 2, showsPlus: true)))" } ?? ""),
                              role: p.pnl < 0 ? .critical : (p.pnl > 0 ? .positive : nil))
                    if !p.unpriced.isEmpty {
                        Text("Priced \(p.pricedCount) of \(p.holdingsCount). No price for \(p.unpriced.joined(separator: ", ")).")
                            .zoroText(.caption).foregroundStyle(ZoroRole.attention.style)
                    }
                    Text("Prices from \(p.sources.joined(separator: ", ")), as of \(Figures.moment(p.asOf, now: Date()))")
                        .zoroText(.caption).foregroundStyle(.secondary)
                }
            }
            if !allocation.isEmpty {
                ZoroCard {
                    VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                        Text("Allocation").zoroText(.heading)
                        AllocationRingChart(allocation)
                        if let top = p.topHolding, let w = p.topWeightPercent {
                            Text("Largest holding: \(top), \(Figures.percent(w)) of the priced portfolio.").zoroText(.detail)
                        }
                        ForEach(p.concentrationFlags, id: \.self) {
                            Label($0, systemImage: "exclamationmark.circle").zoroText(.detail).foregroundStyle(ZoroRole.attention.style)
                        }
                        if p.risk.status != "ok" {
                            Text("Risk figures need more history: \(p.risk.reason).").zoroText(.caption).foregroundStyle(.secondary)
                        } else if let vol = p.risk.annualVolatilityPercent {
                            Text("Yearly volatility about \(Figures.ratio(vol, places: 1))%.").zoroText(.caption)
                        }
                    }
                }
            }
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    Text("Holdings").zoroText(.heading)
                    ForEach(p.holdings) { h in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                                Text(h.symbol).zoroText(.body)
                                Text("\(Figures.quantity(h.quantity)) at \(Figures.money(h.averagePrice)) · \(h.exchange)")
                                    .zoroText(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: ZoroSpace.hair.value) {
                                Text(Figures.money(h.value, unknown: "No price")).zoroText(.amount)
                                if let pnl = h.pnl {
                                    Text(Figures.money(pnl, showsPlus: true)).zoroText(.caption)
                                        .foregroundStyle(pnl < 0 ? AnyShapeStyle(ZoroRole.critical.style) : AnyShapeStyle(ZoroRole.positive.style))
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            NotAdviceLine(text: p.disclaimer)
        }
    }
}
