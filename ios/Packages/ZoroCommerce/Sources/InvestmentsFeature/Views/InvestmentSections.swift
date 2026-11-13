import CommerceSupport
import SwiftUI
import ZoroCore
import ZoroDesign

// MARK: - Watchlists and unusual movements

struct WatchlistSection: View {
    @Bindable var model: WatchlistViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            if model.names.count > 1 {
                Picker("Watchlist", selection: $model.selected) { ForEach(model.names, id: \.self) { Text($0).tag($0) } }
                    .onChange(of: model.selected) { Task { await model.load() } }
            }
            HStack {
                TextField("Add a symbol, like INFY", text: $model.newSymbol).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.add() } }
                Button("Add") { Task { await model.add() } }.buttonStyle(.zoroSecondary).fixedSize()
            }
            if let notice = model.notice { NoticeLine(notice) }
            if let list = model.list, model.phase == .loaded {
                ZoroCard {
                    VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                        ForEach(list.items) { item in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                                    Text(item.symbol).zoroText(.body)
                                    Text(item.closeDay.map { "Close \($0.shortDisplay) from \(item.priceSource ?? "your data")" } ?? "No price data yet")
                                        .zoroText(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(Figures.money(item.lastClose, unknown: "")).zoroText(.amount)
                                    if let c = item.changePercent { Text(Figures.percent(c, places: 2, showsPlus: true)).zoroText(.caption) }
                                }
                                Button("Remove") { Task { await model.remove(item) } }.buttonStyle(.zoroLink)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            } else {
                PhaseStateView(model.phase, loading: "Loading watchlists.", empty: "Your watchlist is empty. Add a symbol above to follow it.") {
                    Task { await model.load() }
                }
            }
            if let m = model.movements {
                ZoroSectionHeader("Unusual movements", detail: "Checked \(m.checked) symbols")
                if m.movements.isEmpty {
                    Text("Nothing moved unusually in the latest bars.").zoroText(.detail).foregroundStyle(.secondary)
                }
                ForEach(m.movements) { mv in
                    VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                        Text("\(mv.symbol) \(mv.returnPercent >= 0 ? "+" : ZoroMoney.minus)\(Figures.ratio(abs(mv.returnPercent), places: 1))% on \(mv.day.shortDisplay)")
                            .zoroText(.body)
                        ForEach(mv.reasons, id: \.self) { Text($0).zoroText(.caption).foregroundStyle(.secondary) }
                        Text("Close \(Figures.money(mv.close)), from \(mv.source)").zoroText(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !m.missingData.isEmpty {
                    Text("No recent prices for \(m.missingData.joined(separator: ", ")).").zoroText(.caption).foregroundStyle(.secondary)
                }
                NotAdviceLine(text: m.disclaimer)
            }
        }
        .task { await model.load() }
    }
}

// MARK: - Analysis

struct AnalysisSection: View {
    @Bindable var model: StockAnalysisViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            HStack {
                TextField("Symbol, like INFY", text: $model.symbol).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.analyse() } }
                Button("Analyse") { Task { await model.analyse() } }.buttonStyle(.zoroSecondary).fixedSize()
            }
            switch model.phase {
            case .idle:
                ZoroStateView(.empty, message: "Enter a symbol to see what your price data says about it, section by section.")
            case .loaded:
                if let a = model.analysis { StockAnalysisView(analysis: a, sections: model.orderedSections) }
            default:
                PhaseStateView(model.phase, loading: "Running seven analysts on your data.", empty: "") { Task { await model.analyse() } }
            }
        }
    }
}

/// Shared by the screen and the `stock_analysis` card.
public struct StockAnalysisView: View {
    let analysis: StockAnalysis
    let sections: [AnalystSection]

    public init(analysis: StockAnalysis, sections: [AnalystSection]? = nil) {
        self.analysis = analysis
        self.sections = sections ?? analysis.sections
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            Text("\(analysis.symbol) on \(analysis.exchange)").zoroText(.heading)
            Label(analysis.freshness, systemImage: "clock").zoroText(.detail)
            Text("Data from \(analysis.dataSources.joined(separator: ", ")).").zoroText(.caption).foregroundStyle(.secondary)
            ForEach(sections) { s in
                ZoroCard {
                    VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                        HStack {
                            Text(s.title).zoroText(.heading)
                            if s.status != "ok" { ZoroCapsuleLabel(text: s.status == "rejected" ? "Rejected" : "Not available", role: .attention) }
                        }
                        if s.findings.isEmpty {
                            Text(s.reason.isEmpty ? "No findings." : "Not available: \(s.reason).").zoroText(.detail).foregroundStyle(.secondary)
                        }
                        ForEach(s.findings, id: \.self) { Text($0).zoroText(.zoroBody).fixedSize(horizontal: false, vertical: true) }
                        if !s.sources.isEmpty { Text("Sources: \(s.sources.joined(separator: ", "))").zoroText(.caption).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text(analysis.verification.passed ? "Every number was checked against your data (\(analysis.verification.numbersChecked) checked)."
                 : "Some statements failed the number check and were held back.")
                .zoroText(.caption).foregroundStyle(.secondary)
            NotAdviceLine(text: analysis.disclaimer)
        }
    }
}

// MARK: - Backtest and paper trades

struct BacktestSection: View {
    @Bindable var model: BacktestViewModel
    @State private var paperQuantity = 1

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            TextField("Symbol, like INFY", text: $model.symbol).textFieldStyle(.roundedBorder)
            Picker("Strategy", selection: $model.strategy) {
                ForEach(BacktestViewModel.strategies, id: \.id) { Text($0.title).tag($0.id) }
            }
            TextField("Starting capital in rupees", text: $model.capitalText).textFieldStyle(.roundedBorder)
            if let v = model.validationMessage { Text(v).zoroText(.caption).foregroundStyle(.secondary) }
            Button("Run backtest") { Task { await model.run() } }.buttonStyle(.zoroPrimary).disabled(model.validationMessage != nil)
            switch model.phase {
            case .loaded:
                if let r = model.result { results(r) }
            case .idle:
                EmptyView()
            default:
                PhaseStateView(model.phase, loading: "Replaying the strategy over your price history.", empty: "") { Task { await model.run() } }
            }
            ZoroSectionHeader("Paper trades", detail: "Practice only; nothing goes to a broker")
            Stepper("Quantity: \(paperQuantity)", value: $paperQuantity, in: 1...100_000)
            HStack {
                Button("Paper buy") { Task { await model.paperTrade(side: "buy", quantity: paperQuantity) } }.buttonStyle(.zoroSecondary)
                Button("Paper sell") { Task { await model.paperTrade(side: "sell", quantity: paperQuantity) } }.buttonStyle(.zoroSecondary)
            }
            if let n = model.paperNotice { NoticeLine(n) }
            if let book = model.book {
                ForEach(book.positions) { p in
                    FigureRow("\(p.symbol): \(p.quantity) at \(Figures.money(p.averageCost))", value: Figures.money(p.realisedPnl, showsPlus: true))
                }
                FigureRow("Charges paid", value: Figures.money(book.chargesPaid))
            }
        }
        .task { await model.loadBook() }
    }

    private func results(_ r: BacktestResult) -> some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                Text("\(r.symbol), \(r.start.display) to \(r.end.display)").zoroText(.heading)
                if model.equityCurve.count > 1 { TrendLineChart(model.equityCurve) }
                FigureRow("Ended with", value: Figures.money(r.finalEquity))
                FigureRow("Return", value: Figures.percent(r.totalReturnPercent, places: 2, showsPlus: true))
                FigureRow("Costs paid", value: Figures.money(r.totalCosts))
                FigureRow("Largest fall", value: "\(Figures.ratio(r.metrics.maxDrawdownPercent, places: 1))%")
                FigureRow("Sharpe ratio", value: Figures.ratio(r.metrics.sharpe))
                FigureRow("Estimated tax", value: Figures.money(r.taxEstimate.totalTax))
                Text("\(r.trades.count) trades over \(r.bars) daily bars. Charges from \(r.chargesSource), checked \(r.chargesVerifiedOn).")
                    .zoroText(.caption).foregroundStyle(.secondary)
                ForEach(r.assumptions, id: \.self) { Text($0).zoroText(.caption).foregroundStyle(.secondary) }
                NotAdviceLine(text: r.disclaimer)
            }
        }
    }
}

// MARK: - Order ticket

struct OrderTicketSection: View {
    @Bindable var model: OrderTicketViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            Text("ZORO prepares what to enter in your broker's app. It never places the order, and it asks for Face ID or Touch ID first.")
                .zoroText(.zoroBody).fixedSize(horizontal: false, vertical: true)
            TextField("Symbol, like INFY", text: $model.draft.symbol).textFieldStyle(.roundedBorder)
            Picker("Side", selection: $model.draft.side) { Text("Buy").tag("buy"); Text("Sell").tag("sell") }.pickerStyle(.segmented)
            Stepper("Quantity: \(model.draft.quantity)", value: $model.draft.quantity, in: 1...1_000_000)
            TextField("Limit price in rupees (empty for market)", text: $model.draft.limitPriceText).textFieldStyle(.roundedBorder)
            Picker("Broker", selection: $model.draft.broker) { Text("Kite").tag("kite"); Text("Dhan").tag("dhan"); Text("Other").tag("other") }
            if let v = model.draft.validationMessage { Text(v).zoroText(.caption).foregroundStyle(.secondary) }
            switch model.step {
            case .draft:
                Button("Prepare order ticket") { Task { await model.send() } }.buttonStyle(.zoroPrimary)
                    .disabled(model.draft.validationMessage != nil)
            case .working:
                ZoroStateView(.loading, message: "Asking ZORO to prepare the ticket.")
            case .awaitingApproval(let a):
                ZoroStateView(.loading, message: "Waiting for your approval: \(a.title).")
            case .done(let text):
                Text(text).zoroText(.zoroBody).fixedSize(horizontal: false, vertical: true)
                Button("Start a new ticket") { model.reset() }.buttonStyle(.zoroSecondary)
            case .declined:
                ZoroStateView(.empty, message: "You declined, so no ticket was prepared.", action: ZoroStateAction("Start again") { model.reset() })
            case .failed(let f):
                ZoroStateView(f.kind == .disconnected ? .disconnected : .error, message: f.message,
                              action: ZoroStateAction("Start again") { model.reset() })
            }
        }
    }
}
