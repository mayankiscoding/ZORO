import CommerceSupport
import Foundation
import Testing
import ZoroCore
@testable import FinancialInterface

/// Records multipart requests and answers with a fixture or an error.
final class FakeUploader: FileUploading, @unchecked Sendable {
    let sent = Locked<[MultipartRequest]>([])
    let answer: @Sendable () throws -> Data
    init(_ answer: @escaping @Sendable () throws -> Data) { self.answer = answer }
    func upload(_ request: MultipartRequest) async throws -> Data {
        sent.withLock { $0.append(request) }
        return try answer()
    }
}

@Suite("Finance DTOs decode backend fixtures")
struct FinanceDTOTests {
    @Test func summaryAndAnalytics() throws {
        let s = try Fixture.decode(SpendingSummary.self, "summary")
        #expect(s.spent == Decimal(string: "7000.50"))
        #expect(s.period.start == CalendarDay(year: 2026, month: 11, day: 1))
        #expect(s.topCategories[0].sharePct == Decimal(60))
        let ie = try Fixture.decode(IncomeExpense.self, "income_expense")
        #expect(ie.savingsRatePct == Decimal(string: "91.8"))
        #expect(ie.months.map(\.month) == ["2026-10", "2026-11"])
        #expect(try Fixture.decode(CategoryBreakdown.self, "breakdown").categories.count == 2)
    }

    @Test func listsAndInsights() throws {
        let page = try Fixture.decode(TransactionList.self, "transactions_page1")
        #expect(page.nextCursor == "2")
        #expect(page.items[0].amount == Decimal(string: "100.25"))
        #expect(page.items[0].balance == nil)
        let budgets = try Fixture.decode(BudgetStatus.self, "budgets")
        #expect(budgets.items[1].state == .exceeded)
        #expect(budgets.items[1].remaining == Decimal(-800))
        let forecast = try Fixture.decode(CashflowForecast.self, "forecast")
        #expect(forecast.outflowLow < forecast.expectedOutflow && forecast.expectedOutflow < forecast.outflowHigh)
        #expect(try Fixture.decode(RecurringReport.self, "recurring").items[0].nextExpected == CalendarDay("2026-12-03"))
        let alerts = try Fixture.decode(AlertList.self, "alerts")
        #expect(alerts.alerts[1].transactionIds == ["tx-1", "tx-9"])
        #expect(alerts.alerts[0].date == nil)
        let failed = try Fixture.decode(ImportStatus.self, "import_failed")
        #expect(failed.status == .failed)
        #expect(failed.errors.first?.line == 2)
    }

    @Test func cardsDecodeEveryFinanceSummaryShape() throws {
        guard case .spending(let s)? = FinanceSummaryPayload.decode(try Fixture.card("card_finance_summary")) else {
            Issue.record("spending"); return
        }
        #expect(s.transactions == 12)
        guard case .incomeExpense? = FinanceSummaryPayload.decode(try Fixture.card("card_income_expense")) else { Issue.record("ie"); return }
        guard case .budgets? = FinanceSummaryPayload.decode(try Fixture.card("card_budgets")) else { Issue.record("budgets"); return }
        guard case .forecast? = FinanceSummaryPayload.decode(try Fixture.card("card_forecast")) else { Issue.record("forecast"); return }
        #expect(FinanceCardDecoding.transactions(try Fixture.card("card_transactions"))?.items.count == 2)
    }

    @Test func malformedCardsDegrade() {
        #expect(FinanceSummaryPayload.decode(UICard(kind: "finance_summary", payload: ["spent": 12.5])) == nil)
        #expect(FinanceSummaryPayload.decode(UICard(kind: "portfolio")) == nil)
        #expect(FinanceCardDecoding.transactions(UICard(kind: "transactions", payload: ["items": []])) == nil)
    }

    @Test func budgetEncodesAsDecimalString() throws {
        let text = String(decoding: try ZoroJSON.encoder().encode(BudgetIn(limit: Decimal(string: "5000.50")!)), as: UTF8.self)
        #expect(text == #"{"limit":"5000.5"}"#)
    }
}

@Suite("Finance view models")
@MainActor
struct FinanceViewModelTests {
    let api = FakeAPI()

    @Test func dashboardLoadsAndToleratesAFailedPart() async {
        api.on("GET /v1/finance/summary", fixture: "summary")
        api.on("GET /v1/finance/categories/breakdown", fixture: "breakdown")
        api.on("GET /v1/finance/income-expense", fixture: "income_expense")
        api.on("GET /v1/finance/forecast", error: .http(status: 500, body: nil))
        api.on("GET /v1/finance/alerts", fixture: "alerts")
        let vm = FinanceDashboardViewModel(client: FinanceClient(api: api))
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.categoryValues.map(\.label) == ["Groceries", "Transport"])
        #expect(vm.netTrend.count == 2)
        #expect(vm.alerts.count == 2)
        #expect(vm.forecast == nil)
        #expect(vm.partFailures["forecast"] != nil)
        #expect(FinanceDashboardViewModel.readOnlyNotice.hasPrefix("Read-only."))
    }

    @Test func dashboardStates() async {
        api.on("GET /v1/finance/summary", error: .http(status: 403, body: ErrorBody(code: "permission_not_granted:finance.read", message: "m")))
        let vm = FinanceDashboardViewModel(client: FinanceClient(api: api))
        await vm.load()
        #expect(vm.phase.failure?.message == "Allow finance.read in Security and privacy, then try again.")

        api.on("GET /v1/finance/summary", error: .notPaired)
        await vm.load()
        #expect(vm.phase.failure?.kind == .disconnected)

        api.on("GET /v1/finance/summary") { _ in
            Data(#"{"period":{"key":"this_month","start":"2026-11-01","end":"2026-11-30","label_en":"this month","label_hi":"x","label_hinglish":"x"},"spent":"0","received":"0","net":"0","transactions":0,"top_categories":[]}"#.utf8)
        }
        await vm.load()
        #expect(vm.phase == .empty)
    }

    @Test func forecastRangeAndMethod() async {
        api.on("GET /v1/finance/summary", fixture: "summary")
        api.on("GET /v1/finance/forecast", fixture: "forecast")
        let vm = FinanceDashboardViewModel(client: FinanceClient(api: api))
        await vm.load()
        #expect(vm.forecastRange == "₹6,500.00 to ₹9,100.00, most likely ₹7,649.00")
        #expect(vm.forecast?.method.contains("trailing") == true)
    }

    @Test func transactionsPaginateWithoutDuplicates() async throws {
        api.on("GET /v1/finance/transactions") { request in
            let cursor = request.query.first { $0.name == "cursor" }?.value
            // Page two repeats tx-2 to prove de-duplication.
            if cursor == "2" {
                var page = try JSONSerialization.jsonObject(with: try Fixture.data("transactions_page2")) as! [String: Any]
                let first = (try JSONSerialization.jsonObject(with: try Fixture.data("transactions_page1")) as! [String: Any])["items"] as! [Any]
                page["items"] = [first[1]] + (page["items"] as! [Any])
                return try JSONSerialization.data(withJSONObject: page)
            }
            return try Fixture.data("transactions_page1")
        }
        let vm = TransactionsViewModel(client: FinanceClient(api: api), pageSize: 2)
        vm.filters.search = "  merchant "
        vm.minAmountText = "1,000.50"
        vm.filters.direction = .debit
        await vm.reload()
        #expect(vm.items.map(\.id) == ["tx-1", "tx-2"])
        #expect(vm.hasMore)
        let first = try #require(api.sent(.get, "/v1/finance/transactions").first)
        let q = Dictionary(first.query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(q["q"] == "merchant")
        #expect(q["min_amount"] == "1000.5")
        #expect(q["direction"] == "debit")
        #expect(q["limit"] == "2")
        #expect(q["cursor"] == nil)
        await vm.loadMore()
        #expect(vm.items.map(\.id) == ["tx-1", "tx-2", "tx-3"])
        #expect(!vm.hasMore)
        await vm.loadMore()
        #expect(api.sent(.get, "/v1/finance/transactions").count == 2)
        #expect(vm.totalCount == 3)
    }

    @Test func loadMoreFailureKeepsItems() async {
        api.on("GET /v1/finance/transactions", fixture: "transactions_page1")
        let vm = TransactionsViewModel(client: FinanceClient(api: api))
        await vm.reload()
        api.on("GET /v1/finance/transactions", error: .transport("down"))
        await vm.loadMore()
        #expect(vm.items.count == 2)
        #expect(vm.loadMoreError?.hasPrefix("Could not reach your ZORO server") == true)
    }

    @Test func emptyTransactionsInviteAnImport() async {
        api.on("GET /v1/finance/transactions") { _ in
            Data(#"{"period":{"key":"last_30_days","start":"2026-10-15","end":"2026-11-13","label_en":"the last 30 days","label_hi":"x","label_hinglish":"x"},"total_debit":"0","total_credit":"0","count":0,"items":[],"next_cursor":null}"#.utf8)
        }
        let vm = TransactionsViewModel(client: FinanceClient(api: api))
        await vm.reload()
        #expect(vm.phase == .empty)
        #expect(vm.emptyMessage.hasPrefix("No transactions yet. Import"))
        vm.filters.channel = "upi"
        #expect(vm.emptyMessage.hasPrefix("No transactions match"))
    }

    @Test func budgetsAndRecurring() async throws {
        api.on("GET /v1/finance/budgets", fixture: "budgets")
        api.on("PUT /v1/finance/budgets/groceries", fixture: "budgets")
        let budgets = BudgetsViewModel(client: FinanceClient(api: api))
        await budgets.load()
        #expect(BudgetsViewModel.stateLabel(budgets.items[1]).0 == "Over by ₹800.00")
        #expect(BudgetsViewModel.stateLabel(budgets.items[0]).0 == "84.0% used, close to the limit")
        await budgets.setBudget(category: "groceries", limitText: "abc")
        #expect(budgets.notice == "Enter a monthly limit in rupees, like 5000.")
        await budgets.setBudget(category: "groceries", limitText: "₹5,000")
        #expect(budgets.notice == "Monthly budget set to ₹5,000.00.")
        let body = String(decoding: try #require(api.sent(.put, "/v1/finance/budgets/groceries").first?.body), as: UTF8.self)
        #expect(body == #"{"limit":"5000"}"#)

        api.on("GET /v1/finance/recurring", fixture: "recurring")
        let recurring = RecurringViewModel(client: FinanceClient(api: api))
        await recurring.load()
        #expect(recurring.subscriptions.count == 1)
        #expect(RecurringViewModel.line(recurring.subscriptions[0]) == "Monthly, ₹649.00. Next expected 3 Dec.")
    }
}

@Suite("Statement import state machine")
@MainActor
struct StatementImportTests {
    let api = FakeAPI()

    @Test func validationRejectsBeforeUpload() {
        let uploader = FakeUploader { try Fixture.data("import_completed") }
        let vm = StatementImportViewModel(client: FinanceClient(api: api, uploader: uploader))
        vm.choose(filename: "old.xls", data: Data([1]))
        #expect(vm.state == .rejected("Old .xls workbooks cannot be read. Save it as .xlsx or .csv, then choose it again."))
        vm.choose(filename: "photo.png", data: Data([1]))
        #expect(vm.state == .rejected("Choose a PDF, CSV or Excel (.xlsx) statement."))
        vm.choose(filename: "empty.csv", data: Data())
        #expect(!vm.canUpload)
        vm.choose(filename: "huge.pdf", data: Data(count: StatementImportViewModel.maxBytes + 1))
        #expect(vm.state == .rejected("That file is over 20 MB. Download a shorter period, then choose it."))
        #expect(uploader.sent.get.isEmpty)
    }

    @Test func uploadFlowToFinished() async throws {
        let uploader = FakeUploader { try Fixture.data("import_completed") }
        let vm = StatementImportViewModel(client: FinanceClient(api: api, uploader: uploader))
        await vm.upload()  // nothing chosen: no-op
        #expect(vm.state == .idle)
        vm.accountName = "Savings"
        vm.choose(filename: "Statement.CSV", data: Data("date,amount\n".utf8))
        #expect(vm.canUpload)
        guard case .chosen(let file) = vm.state else { Issue.record("expected chosen"); return }
        #expect(file.mimeType == "text/csv")
        await vm.upload()
        guard case .finished(let status) = vm.state else { Issue.record("expected finished"); return }
        #expect(StatementImportViewModel.outcome(status) == "Imported 10 transactions; 2 already there.")
        #expect(vm.recent.first?.id == "imp-1")
        let request = try #require(uploader.sent.get.first)
        #expect(request.path == "/v1/finance/imports")
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains("name=\"account_name\"\r\n\r\nSavings\r\n"))
        #expect(body.contains("filename=\"Statement.CSV\""))
        vm.reset()
        #expect(vm.state == .idle)
    }

    @Test func uploadFailuresAndServerVerdicts() async throws {
        let unavailable = StatementImportViewModel(client: FinanceClient(api: api))
        unavailable.choose(filename: "s.pdf", data: Data([1]))
        await unavailable.upload()
        guard case .failed(let f) = unavailable.state else { Issue.record("expected failure"); return }
        #expect(f.message.hasPrefix("File upload is not available"))

        let tooLarge = FakeUploader { throw ZoroError.http(status: 413, body: ErrorBody(code: "payload_too_large", message: "Statements up to 20 MB are accepted.")) }
        let vm = StatementImportViewModel(client: FinanceClient(api: api, uploader: tooLarge))
        vm.choose(filename: "s.pdf", data: Data([1]))
        await vm.upload()
        #expect(vm.state.failureMessage == "Statements up to 20 MB are accepted. Try again in a moment.")

        let failed = try Fixture.decode(ImportStatus.self, "import_failed")
        #expect(StatementImportViewModel.outcome(failed) == "No transactions could be read. Check that it is a bank or card statement, then try another file.")
        var again = try Fixture.decode(ImportStatus.self, "import_completed")
        again.alreadyImported = true
        #expect(StatementImportViewModel.outcome(again) == "statement.csv was imported before, so nothing changed.")
    }
}

extension StatementImportViewModel.State {
    var failureMessage: String? {
        if case .failed(let f) = self { f.message } else { nil }
    }
}
