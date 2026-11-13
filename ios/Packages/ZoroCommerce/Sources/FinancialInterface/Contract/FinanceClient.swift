import CommerceSupport
import Foundation
import ZoroCore

/// Filters for `GET /v1/finance/transactions`. Amounts are sent as decimal strings.
public struct TransactionFilters: Equatable, Sendable {
    public var period = "last_30_days"
    public var category: String?
    public var direction: TransactionOut.Direction?
    public var channel: String?
    public var search = ""
    public var minAmount: Decimal?
    public var maxAmount: Decimal?

    public init() {}

    public static let periods: [(key: String, title: String)] = [
        ("this_month", "This month"), ("last_month", "Last month"), ("last_30_days", "Last 30 days"),
        ("last_90_days", "Last 90 days"), ("this_year", "This year"),
    ]
    public static let channels = ["upi", "card", "neft", "imps", "atm", "cash", "other"]

    func query(cursor: String?, limit: Int) -> [URLQueryItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            URLQueryItem(name: "period", value: period),
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "direction", value: direction?.rawValue),
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "q", value: q.isEmpty ? nil : String(q.prefix(100))),
            URLQueryItem(name: "min_amount", value: minAmount.map(DecimalString.format)),
            URLQueryItem(name: "max_amount", value: maxAmount.map(DecimalString.format)),
            URLQueryItem(name: "cursor", value: cursor),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
    }
}

/// Typed client for `/v1/finance` (backend/app/finance/api.py).
public struct FinanceClient: Sendable {
    public let api: any ZoroAPI
    public let uploader: any FileUploading

    public init(api: any ZoroAPI, uploader: any FileUploading = UnavailableFileUploader()) {
        self.api = api
        self.uploader = uploader
    }

    public func summary(period: String = "this_month") async throws -> SpendingSummary {
        try await api.send(.get("/v1/finance/summary", query: [URLQueryItem(name: "period", value: period)]), as: SpendingSummary.self)
    }

    public func breakdown(period: String = "this_month") async throws -> CategoryBreakdown {
        try await api.send(.get("/v1/finance/categories/breakdown", query: [URLQueryItem(name: "period", value: period)]),
                           as: CategoryBreakdown.self)
    }

    public func incomeExpense(period: String = "this_year") async throws -> IncomeExpense {
        try await api.send(.get("/v1/finance/income-expense", query: [URLQueryItem(name: "period", value: period)]),
                           as: IncomeExpense.self)
    }

    public func transactions(_ filters: TransactionFilters, cursor: String?, limit: Int) async throws -> TransactionList {
        try await api.send(.get("/v1/finance/transactions", query: filters.query(cursor: cursor, limit: limit)),
                           as: TransactionList.self)
    }

    public func budgets() async throws -> BudgetStatus {
        try await api.send(.get("/v1/finance/budgets"), as: BudgetStatus.self)
    }

    public func setBudget(category: String, limit: Decimal) async throws -> BudgetStatus {
        try await api.send(.json(.put, "/v1/finance/budgets/\(APIRequest.segment(category))", body: BudgetIn(limit: limit)),
                           as: BudgetStatus.self)
    }

    public func recurring() async throws -> RecurringReport {
        try await api.send(.get("/v1/finance/recurring"), as: RecurringReport.self)
    }

    public func forecast(horizonDays: Int = 30) async throws -> CashflowForecast {
        try await api.send(.get("/v1/finance/forecast", query: [URLQueryItem(name: "horizon_days", value: String(horizonDays))]),
                           as: CashflowForecast.self)
    }

    public func alerts() async throws -> AlertList {
        try await api.send(.get("/v1/finance/alerts"), as: AlertList.self)
    }

    public func imports(limit: Int = 20) async throws -> [ImportStatus] {
        try await api.send(.get("/v1/finance/imports", query: [URLQueryItem(name: "limit", value: String(limit))]),
                           as: [ImportStatus].self)
    }

    public func importStatus(id: String) async throws -> ImportStatus {
        try await api.send(.get("/v1/finance/imports/\(APIRequest.segment(id))"), as: ImportStatus.self)
    }

    /// `POST /v1/finance/imports` (multipart: `file`, optional `account_name`).
    public func uploadStatement(_ file: UploadFile, accountName: String?) async throws -> ImportStatus {
        var fields: [(String, String)] = []
        if let name = accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            fields.append(("account_name", String(name.prefix(120))))
        }
        let request = MultipartRequest(path: "/v1/finance/imports", fields: fields, fileField: "file", file: file)
        return try await uploader.upload(request, as: ImportStatus.self)
    }
}
