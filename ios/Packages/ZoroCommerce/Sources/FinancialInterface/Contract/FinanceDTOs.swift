import CommerceSupport
import Foundation
import ZoroCore

// Codable mirrors of backend/app/finance/schemas.py and periods.py. Money is `Decimal` from decimal
// strings; dates are `CalendarDay`. Finance is read-only by default: only budgets and categories change.

public struct FinancePeriod: Codable, Sendable, Hashable {
    public var key: String
    public var start: CalendarDay
    public var end: CalendarDay
    public var labelEn: String
    public var labelHi: String
    public var labelHinglish: String

    enum CodingKeys: String, CodingKey {
        case key, start, end, labelEn = "label_en", labelHi = "label_hi", labelHinglish = "label_hinglish"
    }
}

public struct RowIssue: Codable, Sendable, Hashable {
    public var line: Int
    public var reason: String
}

public struct ImportStatus: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case completed, partial, failed }
    public var id: String
    public var filename: String
    public var fileKind: String
    public var sourceKind: String
    public var profile: String
    public var accountId: String?
    public var accountName: String?
    public var status: Status
    public var rowsTotal: Int
    public var rowsImported: Int
    public var rowsDuplicate: Int
    public var rowsReconciled: Int
    public var rowsSkipped: Int
    public var rowsError: Int
    /// ok | mismatch | not_available
    public var balanceCheck: String
    public var message: String
    public var errors: [RowIssue]
    public var periodStart: CalendarDay?
    public var periodEnd: CalendarDay?
    public var createdAt: Date
    public var alreadyImported: Bool

    enum CodingKeys: String, CodingKey {
        case id, filename, fileKind = "file_kind", sourceKind = "source_kind", profile, accountId = "account_id"
        case accountName = "account_name", status, rowsTotal = "rows_total", rowsImported = "rows_imported"
        case rowsDuplicate = "rows_duplicate", rowsReconciled = "rows_reconciled", rowsSkipped = "rows_skipped"
        case rowsError = "rows_error", balanceCheck = "balance_check", message, errors, periodStart = "period_start"
        case periodEnd = "period_end", createdAt = "created_at", alreadyImported = "already_imported"
    }
}

public struct TransactionOut: Codable, Sendable, Hashable, Identifiable {
    public enum Direction: String, Codable, Sendable, CaseIterable { case debit, credit }
    public var id: String
    public var accountId: String
    public var date: CalendarDay
    public var narration: String
    public var counterparty: String
    public var channel: String
    public var direction: Direction
    @WireDecimal public var amount: Decimal
    @WireDecimalOptional public var balance: Decimal?
    public var category: String
    public var categorySource: String
    public var confidence: Int
    public var sourceFile: String
    public var duplicateOf: String?

    enum CodingKeys: String, CodingKey {
        case id, accountId = "account_id", date, narration, counterparty, channel, direction, amount, balance, category
        case categorySource = "category_source", confidence, sourceFile = "source_file", duplicateOf = "duplicate_of"
    }
}

public struct TransactionList: Codable, Sendable, Equatable {
    public var period: FinancePeriod
    @WireDecimal public var totalDebit: Decimal
    @WireDecimal public var totalCredit: Decimal
    /// Matching rows on the server (may exceed `items.count`).
    public var count: Int
    public var items: [TransactionOut]
    public var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case period, totalDebit = "total_debit", totalCredit = "total_credit", count, items, nextCursor = "next_cursor"
    }
}

public struct CategoryTotal: Codable, Sendable, Hashable {
    public var category: String
    public var name: String
    @WireDecimal public var amount: Decimal
    public var count: Int
    @WireDecimal public var sharePct: Decimal

    enum CodingKeys: String, CodingKey { case category, name, amount, count, sharePct = "share_pct" }
}

public struct SpendingSummary: Codable, Sendable, Equatable {
    public var period: FinancePeriod
    public var category: String?
    public var categoryName: String?
    @WireDecimal public var spent: Decimal
    @WireDecimal public var received: Decimal
    @WireDecimal public var net: Decimal
    public var transactions: Int
    public var topCategories: [CategoryTotal]

    enum CodingKeys: String, CodingKey {
        case period, category, categoryName = "category_name", spent, received, net, transactions
        case topCategories = "top_categories"
    }
}

public struct CategoryBreakdown: Codable, Sendable, Equatable {
    public var period: FinancePeriod
    public var direction: TransactionOut.Direction
    @WireDecimal public var total: Decimal
    public var transactions: Int
    public var categories: [CategoryTotal]
}

public struct MonthRow: Codable, Sendable, Hashable {
    /// YYYY-MM
    public var month: String
    @WireDecimal public var income: Decimal
    @WireDecimal public var expense: Decimal
    @WireDecimal public var net: Decimal
}

public struct IncomeExpense: Codable, Sendable, Equatable {
    public var period: FinancePeriod
    @WireDecimal public var income: Decimal
    @WireDecimal public var expense: Decimal
    @WireDecimal public var net: Decimal
    @WireDecimalOptional public var savingsRatePct: Decimal?
    public var months: [MonthRow]

    enum CodingKeys: String, CodingKey { case period, income, expense, net, savingsRatePct = "savings_rate_pct", months }
}

public struct RecurringItem: Codable, Sendable, Hashable {
    public var merchant: String
    public var merchantKey: String
    public var category: String
    public var direction: TransactionOut.Direction
    public var cadence: String
    @WireDecimal public var typicalAmount: Decimal
    @WireDecimal public var minAmount: Decimal
    @WireDecimal public var maxAmount: Decimal
    public var occurrences: Int
    public var firstDate: CalendarDay
    public var lastDate: CalendarDay
    public var nextExpected: CalendarDay
    public var isSubscription: Bool

    enum CodingKeys: String, CodingKey {
        case merchant, merchantKey = "merchant_key", category, direction, cadence, typicalAmount = "typical_amount"
        case minAmount = "min_amount", maxAmount = "max_amount", occurrences, firstDate = "first_date"
        case lastDate = "last_date", nextExpected = "next_expected", isSubscription = "is_subscription"
    }
}

public struct RecurringReport: Codable, Sendable, Equatable {
    public var asOf: CalendarDay
    public var items: [RecurringItem]
    @WireDecimal public var monthlyTotal: Decimal

    enum CodingKeys: String, CodingKey { case asOf = "as_of", items, monthlyTotal = "monthly_total" }
}

public struct BudgetStatusItem: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable { case ok, warning, exceeded }
    public var category: String
    public var name: String
    @WireDecimal public var limit: Decimal
    @WireDecimal public var spent: Decimal
    @WireDecimal public var remaining: Decimal
    @WireDecimal public var usedPct: Decimal
    public var state: State

    enum CodingKeys: String, CodingKey { case category, name, limit, spent, remaining, usedPct = "used_pct", state }
}

public struct BudgetStatus: Codable, Sendable, Equatable {
    public var period: FinancePeriod
    public var items: [BudgetStatusItem]
}

public struct BudgetIn: Codable, Sendable, Equatable {
    @WireDecimal public var limit: Decimal
    public init(limit: Decimal) { self.limit = limit }
}

public struct ForecastLine: Codable, Sendable, Hashable {
    public var label: String
    public var direction: TransactionOut.Direction
    @WireDecimal public var amount: Decimal
    public var basis: String
}

public struct CashflowForecast: Codable, Sendable, Equatable {
    public var asOf: CalendarDay
    public var horizonDays: Int
    public var start: CalendarDay
    public var end: CalendarDay
    @WireDecimal public var expectedOutflow: Decimal
    @WireDecimal public var outflowLow: Decimal
    @WireDecimal public var outflowHigh: Decimal
    @WireDecimal public var expectedInflow: Decimal
    @WireDecimal public var net: Decimal
    public var method: String
    public var lines: [ForecastLine]

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of", horizonDays = "horizon_days", start, end, expectedOutflow = "expected_outflow"
        case outflowLow = "outflow_low", outflowHigh = "outflow_high", expectedInflow = "expected_inflow", net, method, lines
    }
}

public struct FinanceAlert: Codable, Sendable, Hashable {
    public var kind: String
    public var message: String
    public var category: String?
    public var merchant: String?
    @WireDecimalOptional public var amount: Decimal?
    public var transactionIds: [String]
    public var date: CalendarDay?

    enum CodingKeys: String, CodingKey { case kind, message, category, merchant, amount, transactionIds = "transaction_ids", date }
}

public struct AlertList: Codable, Sendable, Equatable {
    public var asOf: CalendarDay
    public var alerts: [FinanceAlert]
    enum CodingKeys: String, CodingKey { case asOf = "as_of", alerts }
}
