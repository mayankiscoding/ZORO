import Foundation
import Testing
import ZoroCore
@testable import ModelRouter

@Suite struct PhotoQueryParserTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var text: String
        var from: String?
        var to: String?
        var colors: [String] = []
        var labels: [String] = []
        var media: PhotoQuery.Media = .any
        var containsText: String? = nil
        var testDescription: String { text }
    }

    static let cases: [Case] = [
        Case(text: "photo from yesterday with my blue cap", from: "2026-11-12", to: "2026-11-12", colors: ["blue"], labels: ["cap", "hat"]),
        Case(text: "show me photos from today", from: "2026-11-13", to: "2026-11-13"),
        Case(text: "pictures from the day before yesterday", from: "2026-11-11", to: "2026-11-11"),
        Case(text: "photos from last week", from: "2026-11-02", to: "2026-11-08"),
        Case(text: "photos from this week", from: "2026-11-09", to: "2026-11-15"),
        Case(text: "photos from last month", from: "2026-10-01", to: "2026-10-31"),
        Case(text: "photos of my dog from october", from: "2026-10-01", to: "2026-10-31", labels: ["dog"]),
        Case(text: "photos from 12 november", from: "2026-11-12", to: "2026-11-12"),
        Case(text: "photos from november 5th", from: "2026-11-05", to: "2026-11-05"),
        Case(text: "photos from 20 december", from: "2025-12-20", to: "2025-12-20"),
        Case(text: "photos from last friday", from: "2026-11-06", to: "2026-11-06"),
        Case(text: "photos from last 3 days", from: "2026-11-10", to: "2026-11-13"),
        Case(text: "photos from last weekend", from: "2026-11-07", to: "2026-11-08"),
        Case(text: "photos from last year", from: "2025-01-01", to: "2025-12-31"),
        Case(text: "show photos of the beach", from: nil, to: nil, labels: ["beach", "sea"]),
        Case(text: "find screenshots from last week", from: "2026-11-02", to: "2026-11-08", media: .screenshot),
        Case(text: "red car photos", from: nil, to: nil, colors: ["red"], labels: ["car", "vehicle"]),
        Case(text: "kal ki photos dikhao", from: "2026-11-12", to: "2026-11-12"),
        Case(text: "parso ki tasveerein", from: "2026-11-11", to: "2026-11-11"),
        Case(text: "pichle hafte ki photos", from: "2026-11-02", to: "2026-11-08"),
        Case(text: "neeli topi wali photo", from: nil, to: nil, colors: ["blue"], labels: ["cap", "hat"]),
        Case(text: "kutte ki photos pichle mahine", from: "2026-10-01", to: "2026-10-31", labels: ["dog"]),
        Case(text: "पिछले हफ्ते की तस्वीरें दिखाओ", from: "2026-11-02", to: "2026-11-08"),
        Case(text: "कल की फोटो", from: "2026-11-12", to: "2026-11-12"),
        Case(text: "लाल कार की फोटो", from: nil, to: nil, colors: ["red"], labels: ["car", "vehicle"]),
        Case(text: "पिछले 3 दिन की फोटो", from: "2026-11-10", to: "2026-11-13"),
        Case(text: "screenshot of \"boarding pass\"", from: nil, to: nil, media: .screenshot, containsText: "boarding pass"),
        Case(text: "screenshot that says sale ends today", from: "2026-11-13", to: "2026-11-13", media: .screenshot, containsText: "sale ends"),
    ]

    @Test(arguments: PhotoQueryParserTests.cases) func parses(_ c: Case) {
        let query = Fixed.photoParser().parse(c.text)
        #expect(query.dateFrom?.description == c.from, "\(c.text): from \(String(describing: query.dateFrom))")
        #expect(query.dateTo?.description == c.to, "\(c.text): to \(String(describing: query.dateTo))")
        #expect(query.colors == c.colors, "\(c.text)")
        #expect(query.labels == c.labels, "\(c.text)")
        #expect(query.media == c.media, "\(c.text)")
        #expect(query.containsText == c.containsText, "\(c.text)")
        #expect(query.text == c.text)
        #expect(query.limit == 30)
    }

    @Test func jsonMatchesTheDeviceContractShape() {
        let json = Fixed.photoParser().parse("photo from yesterday with my blue cap").json
        #expect(Set(json.keys) == ["text", "date_from", "date_to", "colors", "labels", "contains_text", "media", "limit"])
        #expect(json["text"] == "photo from yesterday with my blue cap")
        #expect(json["date_from"] == "2026-11-12")
        #expect(json["date_to"] == "2026-11-12")
        #expect(json["colors"] == ["blue"])
        #expect(json["labels"] == ["cap", "hat"])
        #expect(json["contains_text"] == .null)
        #expect(json["media"] == "any")
        #expect(json["limit"] == 30)
    }

    @Test func jsonSurvivesTheContractCoding() throws {
        let json = Fixed.photoParser().parse("screenshots from last week").json
        let data = try ZoroJSON.encoder().encode(JSONValue.object(json))
        let back = try ZoroJSON.decoder().decode(JSONValue.self, from: data)
        #expect(back == .object(json))
    }

    @Test func unfilteredQueryIsRecognised() {
        #expect(Fixed.photoParser().parse("show my photos").isUnfiltered)
        #expect(!Fixed.photoParser().parse("photos from yesterday").isUnfiltered)
    }

    @Test func dateIntervalCoversWholeDaysInTheOwnersZone() throws {
        let query = Fixed.photoParser().parse("photos from last week")
        let range = try #require(query.dateInterval(in: Fixed.timeZone))
        #expect(ZoroJSON.formatDate(range.start) == "2026-11-01T18:30:00Z")  // 2 Nov 00:00 IST
        #expect(range.end.timeIntervalSince(try #require(ZoroJSON.parseDate("2026-11-08T18:30:00Z"))) < 0)  // before 9 Nov 00:00 IST
        #expect(range.end.timeIntervalSince(try #require(ZoroJSON.parseDate("2026-11-08T18:29:59Z"))) > 0)
        #expect(query.media == .any)
        let shot = Fixed.photoParser().parse("screenshots")
        #expect(shot.media == .screenshot)
        #expect(shot.dateInterval(in: Fixed.timeZone) == nil)
    }

    @Test func parsedQueryRoundTripsThroughContractCoding() throws {
        let query = Fixed.photoParser().parse("photo from yesterday with my blue cap")
        let decoded = try ZoroJSON.decoder().decode(PhotoQuery.self, from: ZoroJSON.encoder().encode(query))
        #expect(decoded == query)
        #expect(try PhotoQuery(json: query.json, timeZone: Fixed.timeZone) == query)
    }

    @Test func intentCarriesTheContractToolAndQuery() async throws {
        let intent = try #require(await Fixed.intent("show me photos from yesterday with my blue cap"))
        #expect(intent.name == "photos.search")
        #expect(intent.tool == "device.photos.search")
        let query = try #require(intent.slots["query"]?.objectValue)
        #expect(query["date_from"] == "2026-11-12")
        #expect(query["colors"] == ["blue"])
        #expect(query["media"] == "any")
        #expect(intent.confidence >= LocalIntentClassifier.minimumActionableConfidence)
    }
}
