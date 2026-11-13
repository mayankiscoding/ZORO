import CommerceSupport
import Foundation
import Observation
import ZoroCore
import ZoroDesign

/// The month at a glance: summary, categories, income against expenses, forecast and alerts.
/// The summary decides the screen's phase; the other parts fail on their own without hiding it.
@MainActor
@Observable
public final class FinanceDashboardViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var summary: SpendingSummary?
    public private(set) var breakdown: CategoryBreakdown?
    public private(set) var incomeExpense: IncomeExpense?
    public private(set) var forecast: CashflowForecast?
    public private(set) var alerts: [FinanceAlert] = []
    /// Parts that could not load, by name, with the sentence to show in their place.
    public private(set) var partFailures: [String: String] = [:]

    @ObservationIgnored private let client: FinanceClient

    public init(client: FinanceClient) { self.client = client }

    public static let readOnlyNotice =
        "Read-only. ZORO reads statements you import; it cannot move money, pay bills or see your bank logins."

    public func load() async {
        if summary == nil { phase = .loading }
        async let s = client.summary()
        async let b = client.breakdown()
        async let ie = client.incomeExpense()
        async let f = client.forecast()
        async let a = client.alerts()
        var failures: [String: String] = [:]
        do {
            summary = try await s
        } catch {
            phase = .failed(ScreenFailure.from(error, subject: "your finance summary"))
            return
        }
        do { breakdown = try await b } catch { failures["categories"] = ScreenFailure.from(error, subject: "categories").message }
        do { incomeExpense = try await ie } catch { failures["income"] = ScreenFailure.from(error, subject: "income and expenses").message }
        do { forecast = try await f } catch { failures["forecast"] = ScreenFailure.from(error, subject: "the forecast").message }
        do { alerts = try await a.alerts } catch { failures["alerts"] = ScreenFailure.from(error, subject: "alerts").message }
        partFailures = failures
        let hasMoney = (summary?.transactions ?? 0) > 0 || (incomeExpense?.months.contains { $0.income != 0 || $0.expense != 0 } ?? false)
        phase = hasMoney ? .loaded : .empty
    }

    public var categoryValues: [CategoryValue] {
        (breakdown?.categories ?? summary?.topCategories ?? []).map { CategoryValue(label: $0.name, amount: $0.amount) }
    }

    /// Monthly net as a trend line (one point per month, mid-month).
    public var netTrend: [TrendPoint] {
        (incomeExpense?.months ?? []).compactMap { row in
            guard let day = CalendarDay(row.month + "-15") else { return nil }
            return TrendPoint(date: day.date(), amount: row.net)
        }
    }

    /// "₹6,500.00 to ₹9,100.00, most likely ₹7,649.00".
    public var forecastRange: String? {
        guard let f = forecast else { return nil }
        return "\(Figures.money(f.outflowLow)) to \(Figures.money(f.outflowHigh)), most likely \(Figures.money(f.expectedOutflow))"
    }
}

/// Transactions with filters, search and cursor pagination. Pages are appended without duplicates;
/// changing a filter starts again from the first page and ignores answers to the old query.
@MainActor
@Observable
public final class TransactionsViewModel {
    public var filters = TransactionFilters()
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var items: [TransactionOut] = []
    public private(set) var totalCount = 0
    public private(set) var totalDebit: Decimal = 0
    public private(set) var totalCredit: Decimal = 0
    public private(set) var periodLabel = ""
    public private(set) var isLoadingMore = false
    public private(set) var loadMoreError: String?

    @ObservationIgnored private var nextCursor: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let client: FinanceClient
    @ObservationIgnored private let pageSize: Int

    public init(client: FinanceClient, pageSize: Int = 50) {
        self.client = client
        self.pageSize = pageSize
    }

    public var hasMore: Bool { nextCursor != nil }

    public var minAmountText = "" { didSet { filters.minAmount = DecimalString.parse(minAmountText.replacingOccurrences(of: ",", with: "")) } }
    public var maxAmountText = "" { didSet { filters.maxAmount = DecimalString.parse(maxAmountText.replacingOccurrences(of: ",", with: "")) } }

    public func reload() async {
        generation += 1
        let mine = generation
        phase = .loading
        nextCursor = nil
        do {
            let page = try await client.transactions(filters, cursor: nil, limit: pageSize)
            guard mine == generation else { return }
            items = page.items
            apply(page)
            phase = items.isEmpty ? .empty : .loaded
        } catch {
            guard mine == generation else { return }
            items = []
            phase = .failed(ScreenFailure.from(error, subject: "your transactions"))
        }
    }

    public func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, phase == .loaded else { return }
        let mine = generation
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            let page = try await client.transactions(filters, cursor: cursor, limit: pageSize)
            guard mine == generation else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            apply(page)
        } catch {
            loadMoreError = ScreenFailure.from(error, subject: "more transactions").message
        }
    }

    private func apply(_ page: TransactionList) {
        nextCursor = page.nextCursor
        totalCount = page.count
        totalDebit = page.totalDebit
        totalCredit = page.totalCredit
        periodLabel = page.period.labelEn
    }

    public var emptyMessage: String {
        filters == TransactionFilters()
            ? "No transactions yet. Import a bank or card statement to see them here."
            : "No transactions match these filters. Clear a filter or widen the period."
    }

    public func clearFilters() {
        filters = TransactionFilters()
        minAmountText = ""
        maxAmountText = ""
    }
}

/// Budgets this month, with setting a monthly limit (the one write besides categories).
@MainActor
@Observable
public final class BudgetsViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var items: [BudgetStatusItem] = []
    public private(set) var notice: String?
    public private(set) var isSaving = false

    @ObservationIgnored private let client: FinanceClient

    public init(client: FinanceClient) { self.client = client }

    public func load() async {
        phase = .loading
        do {
            items = try await client.budgets().items
            phase = items.isEmpty ? .empty : .loaded
        } catch {
            phase = .failed(ScreenFailure.from(error, subject: "your budgets"))
        }
    }

    public func setBudget(category: String, limitText: String) async {
        let cleaned = limitText.replacingOccurrences(of: "₹", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let limit = DecimalString.parse(cleaned), limit > 0, !cleaned.contains("e"), !cleaned.contains("E") else {
            notice = "Enter a monthly limit in rupees, like 5000."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let status = try await client.setBudget(category: category, limit: limit)
            for item in status.items {
                if let i = items.firstIndex(where: { $0.category == item.category }) { items[i] = item } else { items.append(item) }
            }
            phase = items.isEmpty ? .empty : .loaded
            notice = "Monthly budget set to \(Figures.money(limit))."
        } catch {
            notice = ScreenFailure.from(error, subject: "the budget").message
        }
    }

    public static func stateLabel(_ item: BudgetStatusItem) -> (String, ZoroRole?) {
        switch item.state {
        case .ok: ("\(Figures.percent(item.usedPct)) used", nil)
        case .warning: ("\(Figures.percent(item.usedPct)) used, close to the limit", .attention)
        case .exceeded: ("Over by \(Figures.money(-item.remaining))", .critical)
        }
    }
}

/// Recurring payments, with subscriptions listed first.
@MainActor
@Observable
public final class RecurringViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var report: RecurringReport?

    @ObservationIgnored private let client: FinanceClient

    public init(client: FinanceClient) { self.client = client }

    public func load() async {
        phase = .loading
        do {
            let r = try await client.recurring()
            report = r
            phase = r.items.isEmpty ? .empty : .loaded
        } catch {
            phase = .failed(ScreenFailure.from(error, subject: "recurring payments"))
        }
    }

    public var subscriptions: [RecurringItem] { report?.items.filter(\.isSubscription) ?? [] }
    public var otherRecurring: [RecurringItem] { report?.items.filter { !$0.isSubscription } ?? [] }

    public static func line(_ item: RecurringItem) -> String {
        let amount = item.minAmount == item.maxAmount ? Figures.money(item.typicalAmount)
            : "about \(Figures.money(item.typicalAmount)) (\(Figures.money(item.minAmount)) to \(Figures.money(item.maxAmount)))"
        return "\(item.cadence.capitalized), \(amount). Next expected \(item.nextExpected.shortDisplay)."
    }
}
