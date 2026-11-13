import Foundation
import Testing
import ZoroCore
@testable import CommerceSupport

private struct Amounts: Codable, Equatable {
    @WireDecimal var amount: Decimal
    @WireDecimalOptional var fee: Decimal?
    var day: CalendarDay?
}

@Suite("Wire types")
struct WireTypeTests {
    private func decode(_ json: String) throws -> Amounts {
        try ZoroJSON.decoder().decode(Amounts.self, from: Data(json.utf8))
    }

    @Test func decimalsComeFromStringsExactly() throws {
        let a = try decode(#"{"amount":"0.10","fee":"1234567890.05","day":"2026-11-13"}"#)
        #expect(a.amount == Decimal(string: "0.1"))
        #expect(a.fee == Decimal(string: "1234567890.05"))
        #expect(a.day == CalendarDay(year: 2026, month: 11, day: 13))
        // 0.1 + 0.2 is exact in Decimal.
        #expect(a.amount + Decimal(string: "0.2")! == Decimal(string: "0.3"))
    }

    @Test func missingAndNullOptionalsAreNil() throws {
        #expect(try decode(#"{"amount":"5"}"#).fee == nil)
        #expect(try decode(#"{"amount":"5","fee":null}"#).fee == nil)
    }

    @Test func numbersAndJunkAreRejected() {
        #expect(throws: (any Error).self) { try decode(#"{"amount":5.5}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"amount":"five"}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"amount":"1","day":"2026-13-01"}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"amount":"1","day":"13/11/2026"}"#) }
    }

    @Test func roundTripsAsStrings() throws {
        let data = try ZoroJSON.encoder().encode(Amounts(amount: Decimal(string: "12.50")!, fee: nil, day: CalendarDay("2026-01-02")))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == #"{"amount":"12.5","day":"2026-01-02","fee":null}"#)
    }

    @Test func calendarDayOrderingAndDisplay() throws {
        let a = try #require(CalendarDay("2026-11-01"))
        let b = try #require(CalendarDay("2026-11-13"))
        #expect(a < b)
        #expect(b.display == "13 Nov 2026")
        #expect(b.shortDisplay == "13 Nov")
    }
}

@Suite("Money and figure formatting")
struct FiguresTests {
    @Test func rupees() {
        #expect(Figures.money(Decimal(string: "1234567.5")!) == "₹12,34,567.50")
        #expect(Figures.money(Decimal(string: "-800")!) == "\u{2212}₹800.00")
        #expect(Figures.money(Decimal(string: "0.005")!) == "₹0.01")
        #expect(Figures.money(nil as Decimal?) == "Not known")
        #expect(Figures.money(Decimal(string: "56.5")!, style: .compact) == "₹56.50")
    }

    @Test func percents() {
        #expect(Figures.percent(Decimal(string: "84.04")!) == "84.0%")
        #expect(Figures.percent(Decimal(string: "-8.91")!, places: 2) == "\u{2212}8.91%")
        #expect(Figures.percent(Decimal(string: "3.39")!, places: 1, showsPlus: true) == "+3.4%")
        #expect(Figures.percent(Decimal(0)) == "0.0%")
        #expect(Figures.percent(Decimal(string: "12")!, places: 0) == "12%")
    }

    @Test func ratiosAndQuantities() {
        #expect(Figures.ratio(-14.234) == "\u{2212}14.23")
        #expect(Figures.ratio(nil) == "Not enough data")
        #expect(Figures.ratio(.nan) == "Not enough data")
        #expect(Figures.ratio(-0.001) == "0.00")
        #expect(Figures.quantity(Decimal(string: "2.50")!) == "2.5")
    }
}

@Suite("Multipart and failures")
struct MultipartAndFailureTests {
    @Test func multipartBodyLayout() {
        let file = UploadFile(filename: "my \"statement\".csv", data: Data("a,b\n1,2".utf8), mimeType: "text/csv")
        let request = MultipartRequest(path: "/v1/finance/imports", fields: [("account_name", "Savings")],
                                       fileField: "file", file: file, boundary: "B")
        let text = String(decoding: request.body, as: UTF8.self)
        #expect(request.contentType == "multipart/form-data; boundary=B")
        #expect(text == "--B\r\nContent-Disposition: form-data; name=\"account_name\"\r\n\r\nSavings\r\n"
            + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"my %22statement%22.csv\"\r\n"
            + "Content-Type: text/csv\r\n\r\na,b\n1,2\r\n--B--\r\n")
    }

    @Test func unavailableUploaderFailsTyped() async {
        let request = MultipartRequest(path: "/x", fields: [], fileField: "file",
                                       file: UploadFile(filename: "a.csv", data: Data(), mimeType: "text/csv"))
        await #expect(throws: ZoroError.self) { _ = try await UnavailableFileUploader().upload(request) }
    }

    @Test func failureMapping() {
        #expect(ScreenFailure.from(ZoroError.notPaired, subject: "x").kind == .disconnected)
        #expect(ScreenFailure.from(ZoroError.transport("down"), subject: "x").kind == .disconnected)
        #expect(ScreenFailure.from(ZoroError.unauthorized, subject: "x").kind == .disconnected)
        let permission = ScreenFailure.from(
            ZoroError.http(status: 403, body: ErrorBody(code: "permission_not_granted:finance.read", message: "m")), subject: "x")
        #expect(permission.message == "Allow finance.read in Security and privacy, then try again.")
        let server = ScreenFailure.from(
            ZoroError.http(status: 503, body: ErrorBody(code: "no_price_data", message: "No bars for TESTA", retryable: false)), subject: "x")
        #expect(server.message == "No bars for TESTA. Try again in a moment.")
        #expect(server.retryable)
        let decoding = ScreenFailure.from(ZoroError.decoding("bad"), subject: "your basket")
        #expect(decoding.kind == .error)
        #expect(!decoding.retryable)
        #expect(ScreenFailure.from(CocoaError(.fileReadUnknown), subject: "it").message == "Could not load it. Try again.")
    }
}
