import CommerceSupport
import Foundation
import ZoroCore

// Codable mirrors of backend/app/investment (schemas.py, tool_models.py, research.py, verify.py,
// backtest.py, paper.py, api.py). Money and prices are `Decimal` from decimal strings; analytics ratios
// the server sends as floats stay `Double`. Every market value carries its source and time.

public struct HoldingView: Codable, Sendable, Hashable, Identifiable {
    public var symbol: String
    public var exchange: String
    @WireDecimal public var quantity: Decimal
    @WireDecimal public var averagePrice: Decimal
    @WireDecimal public var invested: Decimal
    @WireDecimalOptional public var lastPrice: Decimal?
    public var priceSource: String?
    public var priceAsOf: Date?
    @WireDecimalOptional public var value: Decimal?
    @WireDecimalOptional public var pnl: Decimal?
    @WireDecimalOptional public var pnlPercent: Decimal?
    @WireDecimalOptional public var weightPercent: Decimal?
    public var source: String

    public var id: String { "\(exchange):\(symbol)" }

    enum CodingKeys: String, CodingKey {
        case symbol, exchange, quantity, averagePrice = "average_price", invested, lastPrice = "last_price"
        case priceSource = "price_source", priceAsOf = "price_as_of", value, pnl, pnlPercent = "pnl_percent"
        case weightPercent = "weight_percent", source
    }
}

public struct RiskExposure: Codable, Sendable, Hashable {
    public var status: String
    public var reason: String
    public var annualVolatilityPercent: Double?
    public var var1dPercent: Double?
    @WireDecimalOptional public var var1dAmount: Decimal?
    public var observations: Int

    enum CodingKeys: String, CodingKey {
        case status, reason, annualVolatilityPercent = "annual_volatility_percent", var1dPercent = "var_1d_percent"
        case var1dAmount = "var_1d_amount", observations
    }
}

public struct PortfolioSummary: Codable, Sendable, Equatable {
    public var asOf: Date
    public var holdings: [HoldingView]
    public var holdingsCount: Int
    public var pricedCount: Int
    @WireDecimal public var invested: Decimal
    @WireDecimal public var value: Decimal
    @WireDecimal public var pnl: Decimal
    @WireDecimalOptional public var pnlPercent: Decimal?
    @WireDecimalOptional public var hhi: Decimal?
    @WireDecimalOptional public var effectiveHoldings: Decimal?
    public var concentrationFlags: [String]
    public var topHolding: String?
    @WireDecimalOptional public var topWeightPercent: Decimal?
    public var risk: RiskExposure
    public var sources: [String]
    public var unpriced: [String]
    public var disclaimer: String

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of", holdings, holdingsCount = "holdings_count", pricedCount = "priced_count", invested, value, pnl
        case pnlPercent = "pnl_percent", hhi, effectiveHoldings = "effective_holdings"
        case concentrationFlags = "concentration_flags", topHolding = "top_holding"
        case topWeightPercent = "top_weight_percent", risk, sources, unpriced, disclaimer
    }
}

public struct PerformancePoint: Codable, Sendable, Hashable {
    public var takenAt: Date
    @WireDecimal public var value: Decimal
    @WireDecimal public var invested: Decimal
    enum CodingKeys: String, CodingKey { case takenAt = "taken_at", value, invested }
}

public struct PerformanceReport: Codable, Sendable, Equatable {
    public var points: [PerformancePoint]
    @WireDecimalOptional public var change: Decimal?
    @WireDecimalOptional public var changePercent: Decimal?
    enum CodingKeys: String, CodingKey { case points, change, changePercent = "change_percent" }
}

public struct ImportResult: Codable, Sendable, Equatable {
    public var imported: Int
    public var updated: Int
    public var source: String
}

public struct WatchItemView: Codable, Sendable, Hashable, Identifiable {
    public var symbol: String
    public var exchange: String
    public var note: String
    public var addedAt: Date
    @WireDecimalOptional public var lastClose: Decimal?
    public var closeDay: CalendarDay?
    @WireDecimalOptional public var changePercent: Decimal?
    public var priceSource: String?

    public var id: String { "\(exchange):\(symbol)" }

    enum CodingKeys: String, CodingKey {
        case symbol, exchange, note, addedAt = "added_at", lastClose = "last_close", closeDay = "close_day"
        case changePercent = "change_percent", priceSource = "price_source"
    }
}

public struct WatchlistOut: Codable, Sendable, Equatable {
    public var listName: String
    public var items: [WatchItemView]
    enum CodingKeys: String, CodingKey { case listName = "list_name", items }
}

public struct WatchlistAddIn: Codable, Sendable, Equatable {
    public var symbol: String
    public var exchange: String
    public var note: String
    public init(symbol: String, exchange: String = "NSE", note: String = "") {
        self.symbol = symbol
        self.exchange = exchange
        self.note = note
    }
}

public struct WatchlistAddOut: Codable, Sendable, Equatable {
    public var symbol: String
    public var exchange: String
    public var listName: String
    public var added: Bool
    public var size: Int
    enum CodingKeys: String, CodingKey { case symbol, exchange, listName = "list_name", added, size }
}

public struct UnusualMovement: Codable, Sendable, Hashable, Identifiable {
    public var symbol: String
    public var exchange: String
    public var day: CalendarDay
    @WireDecimal public var close: Decimal
    public var returnPercent: Double
    public var returnZ: Double?
    public var volume: Int
    public var volumeZ: Double?
    public var reasons: [String]
    public var source: String

    public var id: String { "\(exchange):\(symbol):\(day)" }

    enum CodingKeys: String, CodingKey {
        case symbol, exchange, day, close, returnPercent = "return_percent", returnZ = "return_z", volume
        case volumeZ = "volume_z", reasons, source
    }
}

public struct UnusualMovementsOut: Codable, Sendable, Equatable {
    public var movements: [UnusualMovement]
    public var checked: Int
    public var missingData: [String]
    @WireDecimal public var returnZThreshold: Decimal
    @WireDecimal public var volumeZThreshold: Decimal
    public var window: Int
    public var disclaimer: String

    enum CodingKeys: String, CodingKey {
        case movements, checked, missingData = "missing_data", returnZThreshold = "return_z_threshold"
        case volumeZThreshold = "volume_z_threshold", window, disclaimer
    }
}

// MARK: - Analysis

public struct AnalystSection: Codable, Sendable, Hashable, Identifiable {
    /// fundamental | technical | news_sentiment | quantitative | risk | portfolio_manager | verification
    public var analyst: String
    public var title: String
    /// ok | unavailable | rejected
    public var status: String
    public var findings: [String]
    public var sources: [String]
    public var reason: String
    public var id: String { analyst }
}

public struct AnalysisFact: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    @WireDecimal public var value: Decimal
    public var unit: String
    public var source: String
    public var asOf: CalendarDay?
    enum CodingKeys: String, CodingKey { case key, label, value, unit, source, asOf = "as_of" }
}

public struct VerificationReport: Codable, Sendable, Hashable {
    public var passed: Bool
    public var numbersChecked: Int
    public var problems: [String]
    public var bannedPhrases: [String]
    enum CodingKeys: String, CodingKey { case passed, numbersChecked = "numbers_checked", problems, bannedPhrases = "banned_phrases" }
}

public struct Interpretation: Codable, Sendable, Hashable {
    public var status: String
    public var text: String?
    public var problems: [String]
}

public struct StockAnalysis: Codable, Sendable, Equatable {
    public var symbol: String
    public var exchange: String
    public var generatedAt: Date
    public var lastBar: CalendarDay?
    public var freshness: String
    public var dataSources: [String]
    public var sections: [AnalystSection]
    public var facts: [AnalysisFact]
    public var verification: VerificationReport
    public var interpretation: Interpretation
    public var disclaimer: String

    enum CodingKeys: String, CodingKey {
        case symbol, exchange, generatedAt = "generated_at", lastBar = "last_bar", freshness, dataSources = "data_sources"
        case sections, facts, verification, interpretation, disclaimer
    }
}

// MARK: - Backtests and paper trades

public struct BacktestIn: Codable, Sendable, Equatable {
    public var symbol: String
    public var exchange: String
    /// buy_and_hold | sma_crossover | rsi_mean_reversion | momentum
    public var strategy: String
    public var params: [String: Double]
    public var start: CalendarDay?
    public var end: CalendarDay?
    @WireDecimal public var initialCapital: Decimal
    @WireDecimal public var slippageBps: Decimal
    public var product: String

    public init(symbol: String, exchange: String = "NSE", strategy: String, params: [String: Double] = [:],
                start: CalendarDay? = nil, end: CalendarDay? = nil, initialCapital: Decimal, slippageBps: Decimal = 5,
                product: String = "delivery") {
        self.symbol = symbol
        self.exchange = exchange
        self.strategy = strategy
        self.params = params
        self.start = start
        self.end = end
        self.initialCapital = initialCapital
        self.slippageBps = slippageBps
        self.product = product
    }

    enum CodingKeys: String, CodingKey {
        case symbol, exchange, strategy, params, start, end, initialCapital = "initial_capital"
        case slippageBps = "slippage_bps", product
    }
}

public struct BacktestTrade: Codable, Sendable, Hashable {
    public var day: CalendarDay
    public var side: String
    public var quantity: Int
    @WireDecimal public var price: Decimal
    @WireDecimal public var charges: Decimal
    public var signalDay: CalendarDay
    enum CodingKeys: String, CodingKey { case day, side, quantity, price, charges, signalDay = "signal_day" }
}

public struct BacktestMetrics: Codable, Sendable, Hashable {
    public var cagrPercent: Double?
    public var sharpe: Double?
    public var sortino: Double?
    public var maxDrawdownPercent: Double
    public var volatilityPercent: Double?
    public var winRatePercent: Double?
    public var roundTrips: Int
    public var turnover: Double
    public var exposurePercent: Double

    enum CodingKeys: String, CodingKey {
        case cagrPercent = "cagr_percent", sharpe, sortino, maxDrawdownPercent = "max_drawdown_percent"
        case volatilityPercent = "volatility_percent", winRatePercent = "win_rate_percent", roundTrips = "round_trips"
        case turnover, exposurePercent = "exposure_percent"
    }
}

public struct TaxEstimate: Codable, Sendable, Hashable {
    @WireDecimal public var shortTermGain: Decimal
    @WireDecimal public var longTermGain: Decimal
    @WireDecimal public var totalTax: Decimal
    public var isEstimate: Bool
    public var basis: String
    enum CodingKeys: String, CodingKey {
        case shortTermGain = "short_term_gain", longTermGain = "long_term_gain", totalTax = "total_tax"
        case isEstimate = "is_estimate", basis
    }
}

public struct EquityPoint: Codable, Sendable, Hashable {
    public var day: CalendarDay
    @WireDecimal public var equity: Decimal
}

public struct BacktestResult: Codable, Sendable, Equatable {
    public var symbol: String
    public var exchange: String
    public var strategy: String
    public var params: [String: Double]
    public var start: CalendarDay
    public var end: CalendarDay
    public var bars: Int
    @WireDecimal public var initialCapital: Decimal
    @WireDecimal public var finalEquity: Decimal
    @WireDecimal public var totalReturnPercent: Decimal
    @WireDecimal public var totalCosts: Decimal
    @WireDecimal public var slippageBps: Decimal
    public var product: String
    public var trades: [BacktestTrade]
    public var openQuantity: Int
    public var metrics: BacktestMetrics
    public var taxEstimate: TaxEstimate
    public var dataSource: String
    public var chargesSource: String
    public var chargesVerifiedOn: String
    public var assumptions: [String]
    public var fingerprint: String
    public var equityCurve: [EquityPoint]
    public var disclaimer: String

    enum CodingKeys: String, CodingKey {
        case symbol, exchange, strategy, params, start, end, bars, initialCapital = "initial_capital"
        case finalEquity = "final_equity", totalReturnPercent = "total_return_percent", totalCosts = "total_costs"
        case slippageBps = "slippage_bps", product, trades, openQuantity = "open_quantity", metrics
        case taxEstimate = "tax_estimate", dataSource = "data_source", chargesSource = "charges_source"
        case chargesVerifiedOn = "charges_verified_on", assumptions, fingerprint, equityCurve = "equity_curve", disclaimer
    }
}

public struct PaperTradeIn: Codable, Sendable, Equatable {
    public var symbol: String
    public var exchange: String
    public var side: String
    public var quantity: Int
    public var product: String
    public init(symbol: String, exchange: String = "NSE", side: String, quantity: Int, product: String = "delivery") {
        self.symbol = symbol
        self.exchange = exchange
        self.side = side
        self.quantity = quantity
        self.product = product
    }
}

public struct PaperTradeOut: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var symbol: String
    public var exchange: String
    public var side: String
    public var product: String
    public var quantity: Int
    @WireDecimal public var price: Decimal
    @WireDecimal public var charges: Decimal
    @WireDecimal public var referencePrice: Decimal
    public var priceSource: String
    public var priceAsOf: Date
    public var executedAt: Date
    public var note: String

    enum CodingKeys: String, CodingKey {
        case id, symbol, exchange, side, product, quantity, price, charges, referencePrice = "reference_price"
        case priceSource = "price_source", priceAsOf = "price_as_of", executedAt = "executed_at", note
    }
}

public struct PaperPosition: Codable, Sendable, Hashable, Identifiable {
    public var symbol: String
    public var exchange: String
    public var quantity: Int
    @WireDecimal public var averageCost: Decimal
    @WireDecimal public var realisedPnl: Decimal
    @WireDecimal public var chargesPaid: Decimal
    public var id: String { "\(exchange):\(symbol)" }
    enum CodingKeys: String, CodingKey {
        case symbol, exchange, quantity, averageCost = "average_cost", realisedPnl = "realised_pnl", chargesPaid = "charges_paid"
    }
}

public struct PaperBook: Codable, Sendable, Equatable {
    public var positions: [PaperPosition]
    public var trades: [PaperTradeOut]
    @WireDecimal public var realisedPnl: Decimal
    @WireDecimal public var chargesPaid: Decimal
    public var note: String
    enum CodingKeys: String, CodingKey { case positions, trades, realisedPnl = "realised_pnl", chargesPaid = "charges_paid", note }
}
