import Foundation
import Testing
import ZoroCore
@testable import PhotoIntelligence

@Suite("Ranking and date filtering")
struct RankingTests {
    let ranker = PhotoRanker()
    let hat = LabelGroup(display: "cap", terms: SynonymLexicon.standard.expand("cap"))

    func candidate(
        _ id: String, _ captured: String = "2026-11-11T10:00:00+05:30", media: PhotoMediaKind = .photo,
        labels: [(String, Double)] = [], text: String = "", colours: [RegionColour] = [], similarity: Double? = nil
    ) -> RankingCandidate {
        RankingCandidate(
            assetId: id, capturedAt: date(captured), media: media,
            labels: labels.map { VisualLabel(name: $0.0, confidence: $0.1) }, text: text, colours: colours, similarity: similarity)
    }

    @Test("blue + cap beats cap only beats blue only; unrelated photos are dropped")
    func combinedSignals() {
        let blue = [RegionColour(region: .full, colour: .blue, fraction: 0.4)]
        let candidates = [
            candidate("blue-only", colours: blue),
            candidate("cap-only", labels: [("baseball_hat", 0.9)]),
            candidate("blue-cap", labels: [("baseball cap", 0.9)], colours: blue),
            candidate("nothing", labels: [("dog", 0.9)], colours: [RegionColour(region: .full, colour: .red, fraction: 0.8)]),
        ]
        let plan = SearchPlan(labelGroups: [hat], colours: [.blue])
        let ranked = ranker.rank(candidates, plan: plan)
        #expect(ranked.map(\.assetId) == ["blue-cap", "cap-only", "blue-only"])
        #expect(ranked[0].matched == ["label:baseball cap", "color:blue"])
        #expect(ranked[0].score > ranked[1].score && ranked[1].score > ranked[2].score)
        #expect(ranked.allSatisfy { (0...1).contains($0.score) })
    }

    @Test func higherConfidenceRanksHigher() {
        let plan = SearchPlan(labelGroups: [hat])
        let ranked = ranker.rank([candidate("weak", labels: [("hat", 0.3)]), candidate("strong", labels: [("hat", 0.95)])], plan: plan)
        #expect(ranked.map(\.assetId) == ["strong", "weak"])
    }

    @Test("a colour filling one grid cell still counts")
    func cellColour() {
        let plan = SearchPlan(colours: [.blue])
        let small = candidate("cell", colours: [RegionColour(region: .cell(row: 0, column: 0), colour: .blue, fraction: 0.8)])
        let ranked = ranker.rank([small], plan: plan)
        #expect(ranked.count == 1)
        #expect(ranked[0].score > 0.8)
        #expect(abs(ranker.colourScore(.blue, in: [RegionColour(region: .full, colour: .blue, fraction: 0.15)]) - 0.5) < 1e-9)
    }

    @Test func dateFilterIsHard() {
        let interval = DateInterval(start: date("2026-11-11T00:00:00+05:30"), end: date("2026-11-11T23:59:59+05:30"))
        let plan = SearchPlan(dateInterval: interval, labelGroups: [hat])
        let ranked = ranker.rank([
            candidate("in", "2026-11-11T18:00:00+05:30", labels: [("hat", 0.5)]),
            candidate("before", "2026-11-10T23:59:00+05:30", labels: [("hat", 0.99)]),
            candidate("after", "2026-11-12T00:00:01+05:30", labels: [("hat", 0.99)]),
            RankingCandidate(assetId: "undated", capturedAt: nil, media: .photo, labels: [VisualLabel(name: "hat", confidence: 1)]),
        ], plan: plan)
        #expect(ranked.map(\.assetId) == ["in"])
        #expect(ranked[0].matched.contains("date"))
    }

    @Test("only filters: everything inside them, newest first")
    func filtersOnly() {
        let plan = SearchPlan(media: .screenshot)
        let ranked = ranker.rank([
            candidate("old", "2026-11-01T10:00:00+05:30", media: .screenshot),
            candidate("photo", "2026-11-11T10:00:00+05:30", media: .photo),
            candidate("new", "2026-11-10T10:00:00+05:30", media: .screenshot),
        ], plan: plan)
        #expect(ranked.map(\.assetId) == ["new", "old"])
        #expect(ranked.allSatisfy { $0.score == 1 && $0.matched == ["media:screenshot"] })
    }

    @Test func photoFilterExcludesScreenshotsButKeepsLivePhotos() {
        let ranked = ranker.rank(
            [candidate("s", media: .screenshot), candidate("l", media: .livePhoto), candidate("p", media: .photo)],
            plan: SearchPlan(media: .photo))
        #expect(Set(ranked.map(\.assetId)) == ["l", "p"])
    }

    @Test func requiredTextIsHardAndFreeTermsMatchTextOrLabels() {
        let plan = SearchPlan(freeTerms: ["airtel"], requiredText: ["invoice"])
        let ranked = ranker.rank([
            candidate("both", text: "airtel invoice november"),
            candidate("prefix", text: "invoices airtel"),
            candidate("missing", text: "airtel recharge"),
        ], plan: plan)
        #expect(ranked.map(\.assetId).sorted() == ["both", "prefix"])
        #expect(ranked.first { $0.assetId == "both" }?.matched == ["text:invoice", "text:airtel"])
    }

    @Test func embeddingSimilarityContributes() {
        let plan = SearchPlan(freeTerms: ["goa"], embeddingText: "goa beach trip")
        let ranked = ranker.rank([
            candidate("close", similarity: 0.33),
            candidate("far", similarity: 0.05),
            candidate("text", text: "goa"),
        ], plan: plan, embeddingAvailable: true)
        #expect(ranked.map(\.assetId) == ["close", "text"] || ranked.map(\.assetId) == ["text", "close"])
        #expect(ranked.first { $0.assetId == "close" }?.matched == ["similar"])
        // Without an embedder the similarity is ignored.
        #expect(ranker.rank([candidate("close", similarity: 0.33)], plan: plan).isEmpty)
    }

    @Test func tiesBreakByNewestThenId() {
        let plan = SearchPlan(labelGroups: [hat])
        let ranked = ranker.rank([
            candidate("b", "2026-11-10T10:00:00+05:30", labels: [("hat", 0.5)]),
            candidate("a", "2026-11-10T10:00:00+05:30", labels: [("hat", 0.5)]),
            candidate("c", "2026-11-11T10:00:00+05:30", labels: [("hat", 0.5)]),
        ], plan: plan)
        #expect(ranked.map(\.assetId) == ["c", "a", "b"])
    }

    @Test func hitLabelsAreTopConfidentOnes() {
        let ranked = ranker.rank(
            [candidate("x", labels: [("hat", 0.9), ("outdoor", 0.6), ("sky", 0.2)])], plan: SearchPlan(labelGroups: [hat]))
        #expect(ranked[0].labels == ["hat", "outdoor"])
    }

    @Test func requestDatesAreLocalWholeDays() throws {
        let request = try PhotoQuery(json: ["text": "x", "date_from": "2026-11-11", "date_to": "2026-11-11"], timeZone: ist)
        let interval = try #require(request.dateInterval(in: ist))
        #expect(interval.start == date("2026-11-11T00:00:00+05:30"))
        #expect(interval.contains(date("2026-11-11T23:59:59.5+05:30")))
        #expect(!interval.contains(date("2026-11-12T00:00:00+05:30")))
        #expect(!interval.contains(date("2026-11-10T23:59:59+05:30")))
        // A timestamp counts as its local calendar day (the contract sends calendar dates).
        let openEnded = try PhotoQuery(json: ["date_from": "2026-11-01T00:00:00Z"], timeZone: ist)
        #expect(openEnded.dateInterval(in: ist)?.start == date("2026-11-01T00:00:00+05:30"))
        #expect(openEnded.dateInterval(in: ist)?.end == .distantFuture)
    }

    @Test(arguments: [
        ["date_from": "2026-13-01"], ["date_from": "2026-02-30"], ["date_from": "2026-11-12", "date_to": "2026-11-01"],
        ["media": "video"], ["limit": 0], ["labels": "cap"], ["colors": [1]], ["text": 5],
    ] as [JSONObject])
    func malformedQueriesAreRejected(_ json: JSONObject) {
        #expect(throws: PhotoQuery.ValidationError.self) { try PhotoQuery(json: json, timeZone: ist) }
    }

    @Test func limitIsClamped() throws {
        #expect(try PhotoQuery(json: ["limit": 1000], timeZone: ist).limit == PhotoQuery.maximumLimit)
        #expect(try PhotoQuery(json: [:], timeZone: ist).limit == 30)
    }
}
