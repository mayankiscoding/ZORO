import CommerceSupport
import Foundation
import Testing
import ZoroCore
@testable import InvestmentsFeature

final class FakeUploader: FileUploading, @unchecked Sendable {
    let sent = Locked<[MultipartRequest]>([])
    let answer: @Sendable () throws -> Data
    init(_ answer: @escaping @Sendable () throws -> Data) { self.answer = answer }
    func upload(_ request: MultipartRequest) async throws -> Data {
        sent.withLock { $0.append(request) }
        return try answer()
    }
}

/// Signs nothing: returns a canned decision or throws, and records what it was asked.
final class FakeApprovals: ApprovalHandling, @unchecked Sendable {
    let asked = Locked<[ApprovalRequest]>([])
    let outcome: @Sendable (ApprovalRequest) throws -> ApprovalDecision
    init(_ outcome: @escaping @Sendable (ApprovalRequest) throws -> ApprovalDecision) { self.outcome = outcome }
    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        asked.withLock { $0.append(request) }
        return try outcome(request)
    }
}

/// A fake whose turn streams are scripted.
final class TurnAPI: FakeAPI, @unchecked Sendable {
    let started = Locked<[TurnRequest]>([])
    let resumed = Locked<[ResumeRequest]>([])
    var first: [TurnEvent] = []
    var afterResume: [TurnEvent] = []
    override func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        started.withLock { $0.append(request) }
        let events = first
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
    override func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        resumed.withLock { $0.append(request) }
        let events = afterResume
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}

@Suite("Investment DTOs decode backend fixtures")
struct InvestmentDTOTests {
    @Test func portfolioAndPerformance() throws {
        let p = try Fixture.decode(PortfolioSummary.self, "portfolio")
        #expect(p.value == Decimal(string: "1706.00"))
        #expect(p.holdings[2].value == nil)
        #expect(p.holdings[1].pnl == Decimal(-49))
        #expect(p.hhi == Decimal(string: "0.5851"))
        #expect(p.risk.status == "unavailable")
        #expect(p.unpriced == ["BSE:TESTC"])
        #expect(p.disclaimer.contains("not investment advice"))
        #expect(try Fixture.decode(PerformanceReport.self, "performance").points.count == 2)
    }

    @Test func researchBacktestPaper() throws {
        let a = try Fixture.decode(StockAnalysis.self, "analysis")
        #expect(a.sections.count == 7)
        #expect(a.facts[0].value == Decimal(string: "120.50"))
        #expect(a.lastBar == CalendarDay("2026-11-12"))
        let b = try Fixture.decode(BacktestResult.self, "backtest")
        #expect(b.params["fast"] == 20)
        #expect(b.totalCosts == Decimal(string: "845.20"))
        #expect(b.metrics.maxDrawdownPercent == -14.2)
        #expect(b.equityCurve.count == 2)
        let book = try Fixture.decode(PaperBook.self, "paper_book")
        #expect(book.trades[0].note.contains("nothing was sent"))
        let u = try Fixture.decode(UnusualMovementsOut.self, "unusual")
        #expect(u.movements[0].returnZ == 3.1)
        #expect(u.returnZThreshold == Decimal(string: "2.5"))
        let w = try Fixture.decode(WatchlistOut.self, "watchlist")
        #expect(w.items[1].lastClose == nil)
        #expect(try Fixture.decode(WatchlistAddOut.self, "watchlist_add").added)
    }

    @Test func cardsDecodeOrDegrade() throws {
        #expect(InvestmentCardDecoding.portfolio(try Fixture.card("card_portfolio"))?.holdingsCount == 3)
        #expect(InvestmentCardDecoding.analysis(try Fixture.card("card_stock_analysis"))?.symbol == "TESTA")
        #expect(InvestmentCardDecoding.portfolio(UICard(kind: "portfolio", payload: ["value": 12])) == nil)
        #expect(InvestmentCardDecoding.analysis(UICard(kind: "portfolio")) == nil)
    }
}

@Suite("Investment view models")
@MainActor
struct InvestmentViewModelTests {
    let api = FakeAPI()

    @Test func portfolioPresentation() async {
        api.on("GET /v1/investments/portfolio", fixture: "portfolio")
        api.on("GET /v1/investments/portfolio/performance", fixture: "performance")
        let vm = PortfolioViewModel(client: InvestmentsClient(api: api))
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.allocation.map(\.label) == ["TESTA", "TESTB"])
        #expect(vm.pnlRole == .positive)
        #expect(vm.coverageLine == "Priced 2 of 3 holdings. No price for BSE:TESTC, so totals leave it out.")
        #expect(vm.concentrationLine == "Largest: TESTA at 70.6%. Spread is like 1.71 equal holdings.")
        #expect(vm.performance?.points.count == 2)
    }

    @Test func portfolioEmptyAndDisconnected() async {
        api.on("GET /v1/investments/portfolio") { _ in
            var p = try JSONSerialization.jsonObject(with: try Fixture.data("portfolio")) as! [String: Any]
            p["holdings"] = []
            return try JSONSerialization.data(withJSONObject: p)
        }
        let vm = PortfolioViewModel(client: InvestmentsClient(api: api))
        await vm.load()
        #expect(vm.phase == .empty)
        api.on("GET /v1/investments/portfolio", error: .transport("down"))
        let down = PortfolioViewModel(client: InvestmentsClient(api: api))
        await down.load()
        #expect(down.phase.failure?.kind == .disconnected)
    }

    @Test func holdingsImport() async throws {
        api.on("GET /v1/investments/portfolio", fixture: "portfolio")
        let ok = FakeUploader { try Fixture.data("import_result") }
        let vm = PortfolioViewModel(client: InvestmentsClient(api: api, uploader: ok))
        await vm.importHoldings(filename: "holdings.xlsx", data: Data([1]))
        #expect(vm.importState == .failed("Choose a CSV file exported from your broker."))
        await vm.importHoldings(filename: "holdings.csv", data: Data("symbol,qty\n".utf8))
        #expect(vm.importState == .done("Imported 3 holdings. They replace your earlier CSV holdings."))
        let body = String(decoding: try #require(ok.sent.get.first).body, as: UTF8.self)
        #expect(body.contains("name=\"exchange\"\r\n\r\nNSE"))

        let invalid = FakeUploader {
            throw ZoroError.http(status: 422, body: ErrorBody(code: "csv_invalid", message: "bad",
                detail: ["errors": [["line": 3, "message": "quantity is not a number"]]]))
        }
        let bad = PortfolioViewModel(client: InvestmentsClient(api: api, uploader: invalid))
        await bad.importHoldings(filename: "h.csv", data: Data([1]))
        #expect(bad.importState == .failed("The CSV has rows ZORO cannot read (line 3: quantity is not a number). Nothing was imported; fix them and try again."))
    }

    @Test func watchlistsAndMovements() async throws {
        api.on("GET /v1/investments/watchlists") { _ in Data(#"["default","banks"]"#.utf8) }
        api.on("GET /v1/investments/watchlists/default", fixture: "watchlist")
        api.on("GET /v1/investments/unusual-movements", fixture: "unusual")
        api.on("POST /v1/investments/watchlists/default/items", fixture: "watchlist_add")
        api.on("DELETE /v1/investments/watchlists/default/items/NSE/TESTA") { _ in Data(#"{"removed":true}"#.utf8) }
        let vm = WatchlistViewModel(client: InvestmentsClient(api: api))
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.movements?.movements.count == 1)
        vm.newSymbol = "bad symbol!"
        await vm.add()
        #expect(vm.notice == "Enter a symbol like INFY: letters and digits only.")
        vm.newSymbol = " testd "
        await vm.add()
        #expect(vm.notice == "Added TESTD to default.")
        let body = try JSONSerialization.jsonObject(with: try #require(api.sent(.post, "/v1/investments/watchlists/default/items").first?.body)) as? [String: Any]
        #expect(body?["symbol"] as? String == "TESTD")
        await vm.remove(try #require(vm.list?.items.first))
        #expect(api.sent(.delete, "/v1/investments/watchlists/default/items/NSE/TESTA").count == 1)
    }

    @Test func analysisSectionsAndNoData() async {
        api.on("GET /v1/investments/analysis/TESTA", fixture: "analysis")
        let vm = StockAnalysisViewModel(client: InvestmentsClient(api: api))
        vm.symbol = "testa"
        await vm.analyse()
        #expect(vm.orderedSections.map(\.analyst) == StockAnalysisViewModel.sectionOrder)
        #expect(vm.orderedSections[0].status == "unavailable")
        #expect(api.sent(.get, "/v1/investments/analysis/TESTA").first?.query.first?.value == "NSE")

        api.on("GET /v1/investments/analysis/NODATA", error: .http(status: 503, body: ErrorBody(code: "no_price_data", message: "none")))
        vm.symbol = "NODATA"
        await vm.analyse()
        #expect(vm.phase.failure?.message == "There are no daily prices for NODATA yet. Import its price history as a CSV, then analyse again.")
    }

    @Test func backtestAndPaperTrade() async throws {
        api.on("POST /v1/investments/backtests", fixture: "backtest")
        api.on("POST /v1/investments/paper-trades", fixture: "paper_trade")
        api.on("GET /v1/investments/paper-trades", fixture: "paper_book")
        let vm = BacktestViewModel(client: InvestmentsClient(api: api))
        #expect(vm.validationMessage == "Enter a symbol like INFY.")
        vm.symbol = "TESTA"
        vm.capitalText = "1,00,000"
        #expect(vm.validationMessage == nil)
        await vm.run()
        #expect(vm.phase == .loaded)
        #expect(vm.equityCurve.count == 2)
        let request = try #require(api.sent(.post, "/v1/investments/backtests").first)
        #expect(request.query.first { $0.name == "include_curve" }?.value == "true")
        let body = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: Any]
        #expect(body?["initial_capital"] as? String == "100000")
        #expect(body?["strategy"] as? String == "sma_crossover")
        await vm.paperTrade(side: "buy", quantity: 5)
        #expect(vm.paperNotice?.hasPrefix("Paper buy of 5 TESTA at ₹120.56, charges ₹1.20.") == true)
        #expect(vm.book?.positions.count == 1)
    }
}

@Suite("Order ticket handoff")
@MainActor
struct OrderTicketTests {
    private func approval() throws -> ApprovalRequest {
        try ZoroJSON.decoder().decode(ApprovalRequest.self, from: Data(#"{"approval_id":"ap-9","turn_id":"t-1","tool":"investment.prepare_order_ticket","risk":"critical","level":"biometric","title":"Order ticket for TESTA","summary":"BUY 5 TESTA","details":[],"action_digest":"abcd","expires_at":"2026-11-13T09:32:00Z"}"#.utf8))
    }

    nonisolated static func decision(_ approved: Bool) -> ApprovalDecision {
        try! ZoroJSON.decoder().decode(ApprovalDecision.self, from: Data(#"{"approval_id":"ap-9","approved":\#(approved),"action_digest":"abcd","device_id":"d-1","signed_at":"2026-11-13T09:31:00Z","signature_b64":"c2ln"}"#.utf8))
    }

    @Test func draftValidationAndSentence() {
        var d = OrderTicketDraft()
        #expect(d.validationMessage == "Enter a symbol like INFY.")
        d.symbol = "testa"
        d.quantity = 5
        #expect(d.validationMessage == nil)
        #expect(d.request == "Prepare an order ticket to buy 5 TESTA on NSE as a market order, delivery, for kite. Do not place it.")
        d.limitPriceText = "abc"
        #expect(d.validationMessage != nil)
        d.limitPriceText = "120.5"
        #expect(d.request.contains("a limit order at 120.5 rupees"))
    }

    @Test func approvedTicketResumesTheTurn() async throws {
        let api = TurnAPI()
        let request = try approval()
        api.first = [.turnStarted(TurnStarted(turnId: "t-1", conversationId: "c", privacyMode: .strictPrivate)),
                     .approvalRequired(ApprovalRequired(approval: request))]
        api.afterResume = [.textDelta(TextDelta(text: "Order ticket ready: BUY 5 TESTA. Place it yourself in Kite."))]
        let approvals = FakeApprovals { _ in OrderTicketTests.decision(true) }
        let vm = OrderTicketViewModel(api: api, approvals: approvals, platform: .ios)
        vm.draft.symbol = "TESTA"
        vm.draft.quantity = 5
        await vm.send()
        #expect(approvals.asked.get.map(\.approvalId) == ["ap-9"])
        #expect(api.resumed.get.first?.approval?.approved == true)
        #expect(vm.step == .done("Order ticket ready: BUY 5 TESTA. Place it yourself in Kite."))
        #expect(api.started.get.first?.input.text.contains("Do not place it.") == true)
    }

    @Test func cancelledOrDeclinedApprovalPreparesNothing() async throws {
        let api = TurnAPI()
        api.first = [.approvalRequired(ApprovalRequired(approval: try approval()))]
        let cancelled = OrderTicketViewModel(api: api, approvals: FakeApprovals { _ in throw ZoroError.userCancelled }, platform: .macos)
        cancelled.draft.symbol = "TESTA"
        await cancelled.send()
        #expect(cancelled.step == .declined)
        #expect(api.resumed.get.isEmpty)

        let declined = OrderTicketViewModel(api: api, approvals: FakeApprovals { _ in OrderTicketTests.decision(false) }, platform: .macos)
        declined.draft.symbol = "TESTA"
        await declined.send()
        #expect(declined.step == .declined)
        #expect(api.resumed.get.first?.approval?.approved == false)
    }

    @Test func invalidDraftSendsNothing() async {
        let api = TurnAPI()
        let vm = OrderTicketViewModel(api: api, approvals: FakeApprovals { _ in OrderTicketTests.decision(true) }, platform: .ios)
        await vm.send()
        #expect(api.started.get.isEmpty)
        #expect(vm.step == .draft)
    }
}
