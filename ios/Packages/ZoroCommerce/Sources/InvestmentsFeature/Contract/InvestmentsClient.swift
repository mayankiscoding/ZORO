import CommerceSupport
import Foundation
import ZoroCore

/// Typed client for `/v1/investments` (backend/app/investment/api.py). There is deliberately no order
/// route: an order ticket only comes from the CRITICAL `investment.prepare_order_ticket` tool in a turn,
/// behind a biometric approval, and the order itself is placed by the owner in the broker's app.
public struct InvestmentsClient: Sendable {
    public let api: any ZoroAPI
    public let uploader: any FileUploading

    public init(api: any ZoroAPI, uploader: any FileUploading = UnavailableFileUploader()) {
        self.api = api
        self.uploader = uploader
    }

    public func portfolio() async throws -> PortfolioSummary {
        try await api.send(.get("/v1/investments/portfolio"), as: PortfolioSummary.self)
    }

    public func performance() async throws -> PerformanceReport {
        try await api.send(.get("/v1/investments/portfolio/performance"), as: PerformanceReport.self)
    }

    /// `POST /v1/investments/holdings/import` (multipart `file`, `exchange`). Replaces the CSV holdings.
    public func importHoldings(_ file: UploadFile, exchange: String = "NSE") async throws -> ImportResult {
        let request = MultipartRequest(path: "/v1/investments/holdings/import", fields: [("exchange", exchange)],
                                       fileField: "file", file: file)
        return try await uploader.upload(request, as: ImportResult.self)
    }

    public func watchlists() async throws -> [String] {
        try await api.send(.get("/v1/investments/watchlists"), as: [String].self)
    }

    public func watchlist(_ name: String) async throws -> WatchlistOut {
        try await api.send(.get("/v1/investments/watchlists/\(APIRequest.segment(name))"), as: WatchlistOut.self)
    }

    public func watchlistAdd(_ name: String, _ body: WatchlistAddIn) async throws -> WatchlistAddOut {
        try await api.send(.json(.post, "/v1/investments/watchlists/\(APIRequest.segment(name))/items", body: body),
                           as: WatchlistAddOut.self)
    }

    public func watchlistRemove(_ name: String, exchange: String, symbol: String) async throws {
        try await api.send(.delete("/v1/investments/watchlists/\(APIRequest.segment(name))/items/\(APIRequest.segment(exchange))/\(APIRequest.segment(symbol))"))
    }

    public func unusualMovements(scope: String = "all") async throws -> UnusualMovementsOut {
        try await api.send(.get("/v1/investments/unusual-movements", query: [URLQueryItem(name: "scope", value: scope)]),
                           as: UnusualMovementsOut.self)
    }

    public func analysis(symbol: String, exchange: String = "NSE") async throws -> StockAnalysis {
        try await api.send(.get("/v1/investments/analysis/\(APIRequest.segment(symbol))",
                                query: [URLQueryItem(name: "exchange", value: exchange)]), as: StockAnalysis.self)
    }

    public func backtest(_ body: BacktestIn) async throws -> BacktestResult {
        var request = try APIRequest.json(.post, "/v1/investments/backtests", body: body)
        request.query = [URLQueryItem(name: "include_curve", value: "true")]
        return try await api.send(request, as: BacktestResult.self)
    }

    public func paperBook() async throws -> PaperBook {
        try await api.send(.get("/v1/investments/paper-trades"), as: PaperBook.self)
    }

    public func paperTrade(_ body: PaperTradeIn) async throws -> PaperTradeOut {
        try await api.send(.json(.post, "/v1/investments/paper-trades", body: body), as: PaperTradeOut.self)
    }
}
