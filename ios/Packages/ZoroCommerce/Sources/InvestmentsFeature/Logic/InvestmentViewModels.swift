import CommerceSupport
import Foundation
import Observation
import ZoroCore
import ZoroDesign

/// Portfolio: allocation, profit and loss, concentration, plus CSV holdings import.
@MainActor
@Observable
public final class PortfolioViewModel {
    public enum ImportState: Equatable, Sendable {
        case idle, importing, done(String), failed(String)
    }

    public private(set) var phase: ScreenPhase = .idle
    public private(set) var portfolio: PortfolioSummary?
    public private(set) var performance: PerformanceReport?
    public private(set) var importState: ImportState = .idle

    @ObservationIgnored private let client: InvestmentsClient

    public init(client: InvestmentsClient) { self.client = client }

    public func load() async {
        if portfolio == nil { phase = .loading }
        do {
            let p = try await client.portfolio()
            portfolio = p
            performance = try? await client.performance()
            phase = p.holdings.isEmpty ? .empty : .loaded
        } catch {
            phase = .failed(ScreenFailure.from(error, subject: "your portfolio"))
        }
    }

    /// Allocation by current value; unpriced holdings are left out (and listed separately).
    public var allocation: [CategoryValue] {
        (portfolio?.holdings ?? []).compactMap { h in h.value.map { CategoryValue(label: h.symbol, amount: $0) } }
    }

    public var pnlRole: ZoroRole? {
        guard let p = portfolio else { return nil }
        return p.pnl < 0 ? .critical : (p.pnl > 0 ? .positive : nil)
    }

    /// "Priced 2 of 3 holdings. No price for BSE:TESTC, so totals leave it out."
    public var coverageLine: String? {
        guard let p = portfolio else { return nil }
        if p.unpriced.isEmpty { return "All \(p.holdingsCount) holdings priced." }
        return "Priced \(p.pricedCount) of \(p.holdingsCount) holdings. No price for \(p.unpriced.joined(separator: ", ")), so totals leave \(p.unpriced.count == 1 ? "it" : "them") out."
    }

    public var concentrationLine: String? {
        guard let p = portfolio else { return nil }
        if let top = p.topHolding, let w = p.topWeightPercent {
            let effective = p.effectiveHoldings.map { " Spread is like \(Figures.quantity($0)) equal holdings." } ?? ""
            return "Largest: \(top) at \(Figures.percent(w)).\(effective)"
        }
        return nil
    }

    public func importHoldings(filename: String, data: Data) async {
        guard (filename as NSString).pathExtension.lowercased() == "csv" else {
            importState = .failed("Choose a CSV file exported from your broker.")
            return
        }
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
            importState = .failed(data.isEmpty ? "That file is empty. Export it again, then choose it." : "That file is over 10 MB. Export fewer rows, then choose it.")
            return
        }
        importState = .importing
        do {
            let result = try await client.importHoldings(UploadFile(filename: filename, data: data, mimeType: "text/csv"))
            importState = .done("Imported \(result.imported) \(result.imported == 1 ? "holding" : "holdings"). They replace your earlier CSV holdings.")
            await load()
        } catch {
            if case ZoroError.http(_, let body?) = error, body.code == "csv_invalid" {
                let lines = body.detail?["errors"].flatMap { value -> [String]? in
                    guard case .array(let items) = value else { return nil }
                    return items.compactMap { item in
                        guard case .object(let o) = item, case .number(let line)? = o["line"], case .string(let m)? = o["message"] else { return nil }
                        return "line \(Int(line)): \(m)"
                    }
                } ?? []
                let detail = lines.isEmpty ? "" : " (\(lines.prefix(3).joined(separator: "; ")))"
                importState = .failed("The CSV has rows ZORO cannot read\(detail). Nothing was imported; fix them and try again.")
            } else {
                importState = .failed(ScreenFailure.from(error, subject: "the holdings file").message)
            }
        }
    }
}

/// Watchlists and unusual movements.
@MainActor
@Observable
public final class WatchlistViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var names: [String] = []
    public var selected = "default"
    public private(set) var list: WatchlistOut?
    public private(set) var movements: UnusualMovementsOut?
    public private(set) var notice: String?
    public var newSymbol = ""

    @ObservationIgnored private let client: InvestmentsClient

    public init(client: InvestmentsClient) { self.client = client }

    public func load() async {
        phase = .loading
        do {
            names = try await client.watchlists()
            if !names.contains(selected), let first = names.first { selected = first }
            list = names.isEmpty ? nil : try await client.watchlist(selected)
            movements = try? await client.unusualMovements()
            phase = (list?.items.isEmpty ?? true) ? .empty : .loaded
        } catch {
            phase = .failed(ScreenFailure.from(error, subject: "your watchlists"))
        }
    }

    /// Symbols: 1-32 of A-Z 0-9 & - _ . (the server's rule).
    public nonisolated static func normalise(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789&-_.")
        guard (1...32).contains(s.count), s.allSatisfy({ allowed.contains($0) }) else { return nil }
        return s
    }

    public func add() async {
        guard let symbol = Self.normalise(newSymbol) else {
            notice = "Enter a symbol like INFY: letters and digits only."
            return
        }
        do {
            let out = try await client.watchlistAdd(selected, WatchlistAddIn(symbol: symbol))
            notice = out.added ? "Added \(out.symbol) to \(out.listName)." : "\(out.symbol) is already on \(out.listName)."
            newSymbol = ""
            await load()
        } catch {
            notice = ScreenFailure.from(error, subject: "the watchlist").message
        }
    }

    public func remove(_ item: WatchItemView) async {
        do {
            try await client.watchlistRemove(selected, exchange: item.exchange, symbol: item.symbol)
            await load()
        } catch {
            notice = ScreenFailure.from(error, subject: "the watchlist").message
        }
    }
}

/// Stock analysis: the seven analyst sections, freshness and the not-investment-advice line.
@MainActor
@Observable
public final class StockAnalysisViewModel {
    public var symbol = ""
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var analysis: StockAnalysis?

    @ObservationIgnored private let client: InvestmentsClient

    public init(client: InvestmentsClient) { self.client = client }

    public static let sectionOrder = ["fundamental", "technical", "news_sentiment", "quantitative", "risk", "portfolio_manager", "verification"]

    public func analyse() async {
        guard let s = WatchlistViewModel.normalise(symbol) else {
            phase = .failed(ScreenFailure(kind: .error, message: "Enter a symbol like INFY, then analyse.", retryable: false))
            return
        }
        phase = .loading
        do {
            analysis = try await client.analysis(symbol: s)
            phase = .loaded
        } catch {
            if case ZoroError.http(_, let body?) = error, body.code == "no_price_data" {
                phase = .failed(ScreenFailure(kind: .error, message: "There are no daily prices for \(s) yet. Import its price history as a CSV, then analyse again.", retryable: false))
            } else {
                phase = .failed(ScreenFailure.from(error, subject: "the analysis"))
            }
        }
    }

    /// Sections in the analysts' fixed order; missing ones are shown as not available.
    public var orderedSections: [AnalystSection] {
        guard let a = analysis else { return [] }
        return Self.sectionOrder.map { key in
            a.sections.first { $0.analyst == key }
                ?? AnalystSection(analyst: key, title: key.replacingOccurrences(of: "_", with: " ").capitalized,
                                  status: "unavailable", findings: [], sources: [], reason: "not returned by the server")
        }
    }
}

/// Backtest runner and paper trades.
@MainActor
@Observable
public final class BacktestViewModel {
    public var symbol = ""
    public var strategy = "sma_crossover"
    public var capitalText = "100000"
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var result: BacktestResult?
    public private(set) var book: PaperBook?
    public private(set) var paperNotice: String?

    @ObservationIgnored private let client: InvestmentsClient

    public init(client: InvestmentsClient) { self.client = client }

    public static let strategies: [(id: String, title: String)] = [
        ("buy_and_hold", "Buy and hold"), ("sma_crossover", "Moving-average crossover"),
        ("rsi_mean_reversion", "RSI mean reversion"), ("momentum", "Momentum"),
    ]

    public var validationMessage: String? {
        if WatchlistViewModel.normalise(symbol) == nil { return "Enter a symbol like INFY." }
        guard let c = DecimalString.parse(capitalText.replacingOccurrences(of: ",", with: "")), c > 0, c <= 10_000_000_000 else {
            return "Enter starting capital in rupees, like 100000."
        }
        return nil
    }

    public func run() async {
        guard validationMessage == nil, let s = WatchlistViewModel.normalise(symbol),
              let capital = DecimalString.parse(capitalText.replacingOccurrences(of: ",", with: "")) else { return }
        phase = .loading
        do {
            result = try await client.backtest(BacktestIn(symbol: s, strategy: strategy, initialCapital: capital))
            phase = .loaded
        } catch {
            phase = .failed(ScreenFailure.from(error, subject: "the backtest"))
        }
    }

    public var equityCurve: [TrendPoint] {
        (result?.equityCurve ?? []).map { TrendPoint(date: $0.day.date(), amount: $0.equity) }
    }

    public func loadBook() async {
        book = try? await client.paperBook()
    }

    public func paperTrade(side: String, quantity: Int) async {
        guard let s = WatchlistViewModel.normalise(symbol), (1...1_000_000).contains(quantity) else {
            paperNotice = "Enter a symbol and a quantity of at least 1."
            return
        }
        do {
            let t = try await client.paperTrade(PaperTradeIn(symbol: s, side: side, quantity: quantity))
            paperNotice = "Paper \(t.side) of \(t.quantity) \(t.symbol) at \(Figures.money(t.price)), charges \(Figures.money(t.charges)). \(t.note)"
            await loadBook()
        } catch {
            paperNotice = ScreenFailure.from(error, subject: "the paper trade").message
        }
    }
}
