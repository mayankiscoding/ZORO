import Foundation
import Testing
import ZoroCore
@testable import LifeSupport

@Suite("LifeFormat")
struct LifeFormatTests {
    @Test func countsUseIndianGrouping() {
        #expect(LifeFormat.count(0) == "0")
        #expect(LifeFormat.count(8421) == "8,421")
        #expect(LifeFormat.count(123_456) == "1,23,456")
        #expect(LifeFormat.count(-1500) == "\u{2212}1,500")
    }

    @Test func numbersDropTrailingZeros() {
        #expect(LifeFormat.number(6.1) == "6.1")
        #expect(LifeFormat.number(412.0) == "412")
        #expect(LifeFormat.number(5.02, places: 2) == "5.02")
        #expect(LifeFormat.number(5.0, places: 2) == "5")
        #expect(LifeFormat.number(6.75, places: 1) == "6.8")
        #expect(LifeFormat.number(7010.25, places: 1) == "7,010.3")
        #expect(LifeFormat.number(123456.0) == "1,23,456")
        #expect(LifeFormat.number(.nan) == "Not known")
        #expect(LifeFormat.number(-0.04, places: 1) == "0")
    }

    @Test func signedPercentUsesTypographicMinus() {
        #expect(LifeFormat.signedPercent(20.1) == "+20.1%")
        #expect(LifeFormat.signedPercent(-5.6) == "\u{2212}5.6%")
        #expect(LifeFormat.signedPercent(0.01) == "0%")
    }

    @Test func paceAndClock() {
        #expect(LifeFormat.pace(secondsPerKm: 384.5) == "6:25")
        #expect(LifeFormat.pace(secondsPerKm: 300) == "5:00")
        #expect(LifeFormat.clock(seconds: 65) == "1:05")
        #expect(LifeFormat.clock(seconds: 3723) == "1:02:03")
        #expect(LifeFormat.clock(seconds: -4) == "0:00")
    }

    @Test func days() throws {
        let day = try #require(CalendarDate("2026-11-03"))
        #expect(LifeFormat.shortDay(day) == "3 Nov")
        #expect(LifeFormat.fullDay(day) == "3 Nov 2026")
    }

    @Test func momentIsTimeToday() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let now = try #require(ZoroJSON.parseDate("2026-11-13T18:00:00+05:30"))
        let earlier = try #require(ZoroJSON.parseDate("2026-11-13T16:12:00+05:30"))
        let other = try #require(ZoroJSON.parseDate("2026-11-12T16:12:00+05:30"))
        #expect(LifeFormat.moment(earlier, now: now, timeZone: zone).lowercased().contains("4:12"))
        #expect(LifeFormat.moment(other, now: now, timeZone: zone) == "12 Nov")
    }
}

@Suite("ScreenFailure")
struct ScreenFailureTests {
    @Test func unreachableServerIsDisconnected() {
        for error in [ZoroError.transport("x"), .timeout, .notPaired, .unauthorized] {
            let f = ScreenFailure.from(error, subject: "your photos")
            #expect(f.kind == .disconnected)
            #expect(f.message.contains("ZORO server"))
        }
    }

    @Test func permissionNotGrantedNamesTheKey() {
        let body = ErrorBody(code: "permission_not_granted:health.read", message: "Allow it")
        let f = ScreenFailure.from(ZoroError.http(status: 403, body: body), subject: "x")
        #expect(f.kind == .error)
        #expect(f.message == "Allow health.read in Security and privacy, then try again.")
    }

    @Test func serverMessageGetsAFullStopAndAHint() {
        let f = ScreenFailure.from(ZoroError.http(status: 500, body: ErrorBody(code: "boom", message: "Spotify did not answer", retryable: true)), subject: "x")
        #expect(f.message == "Spotify did not answer. Try again in a moment.")
        #expect(f.retryable)
    }

    @Test func unknownErrorsStillSayWhatToDo() {
        struct Odd: Error {}
        #expect(ScreenFailure.from(Odd(), subject: "your music").message == "Could not load your music. Try again.")
        #expect(ScreenFailure.from(ZoroError.decoding("x"), subject: "your music").retryable == false)
    }

    @Test func loadableAccessors() {
        let l: Loadable<Int> = .loaded(3)
        #expect(l.value == 3)
        #expect(Loadable<Int>.loading.isLoading)
        #expect(Loadable<Int>.failed(ScreenFailure(kind: .error, message: "m")).failure?.message == "m")
    }
}
