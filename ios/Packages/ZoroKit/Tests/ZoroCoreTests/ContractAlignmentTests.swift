import Foundation
import Testing
@testable import ZoroCore

private let ist = TimeZone(secondsFromGMT: 19_800)!

@Suite("Device contract alignment")
struct ContractAlignmentTests {
    // MARK: PhotoQuery

    @Test func photoQueryDecodesTheContractExample() throws {
        let json = #"""
            {"text":"photo from yesterday with my blue cap","date_from":"2026-11-11","date_to":"2026-11-11",
             "colors":["blue"],"labels":["cap","hat"],"contains_text":null,"media":"any","limit":30}
            """#
        let query = try ZoroJSON.decoder().decode(PhotoQuery.self, from: Data(json.utf8))
        #expect(query.dateFrom == CalendarDate(year: 2026, month: 11, day: 11))
        #expect(query.dateTo?.description == "2026-11-11")
        #expect(query.colors == ["blue"] && query.labels == ["cap", "hat"])
        #expect(query.containsText == nil && query.media == .any && query.limit == 30 && query.cursor == nil)
        let again = try ZoroJSON.decoder().decode(PhotoQuery.self, from: ZoroJSON.encoder().encode(query))
        #expect(again == query)
        let encoded = try #require(try JSONSerialization.jsonObject(with: ZoroJSON.encoder().encode(query)) as? [String: Any])
        #expect(Set(encoded.keys) == ["text", "date_from", "date_to", "colors", "labels", "contains_text", "media", "limit"])
    }

    @Test func photoQueryDefaultsAndPaging() throws {
        let query = try ZoroJSON.decoder().decode(PhotoQuery.self, from: Data(#"{"cursor":"30"}"#.utf8))
        #expect(query == PhotoQuery(cursor: "30"))
        #expect(query.json["cursor"] == "30")
        #expect(PhotoQuery(limit: 1000).limit == PhotoQuery.maximumLimit)
        #expect(PhotoQuery(limit: 0).limit == 1)
        #expect(PhotoQuery().isUnfiltered && !PhotoQuery(media: .screenshot).isUnfiltered)
    }

    @Test func photoQueryValidatesArguments() throws {
        let bad: [JSONObject] = [
            ["media": "video"], ["limit": -1], ["limit": "ten"], ["colors": "blue"], ["labels": [1]],
            ["date_from": "yesterday"], ["date_from": "2026-02-30"], ["date_from": "2026-11-12", "date_to": "2026-11-11"],
        ]
        for json in bad {
            #expect(throws: PhotoQuery.ValidationError.self, "\(json)") { try PhotoQuery(json: json, timeZone: ist) }
        }
        #expect(throws: DecodingError.self) { try ZoroJSON.decoder().decode(PhotoQuery.self, from: Data(#"{"date_from":"12/11/2026"}"#.utf8)) }
        // An ISO timestamp is taken as its local day in the owner's zone.
        let late = try PhotoQuery(json: ["date_from": "2026-11-10T20:00:00Z"], timeZone: ist)
        #expect(late.dateFrom?.description == "2026-11-11")
        #expect(try PhotoQuery(json: ["contains_text": ""], timeZone: ist).containsText == nil)
    }

    @Test func photoQueryDateIntervalCoversWholeLocalDays() throws {
        let query = PhotoQuery(dateFrom: CalendarDate("2026-11-11"), dateTo: CalendarDate("2026-11-12"))
        let range = try #require(query.dateInterval(in: ist))
        #expect(ZoroJSON.formatDate(range.start) == "2026-11-10T18:30:00Z")
        #expect(range.end < (ZoroJSON.parseDate("2026-11-12T18:30:00Z") ?? .distantPast))
        #expect(range.end > (ZoroJSON.parseDate("2026-11-12T18:29:59Z") ?? .distantFuture))
        let openEnded = try #require(PhotoQuery(dateFrom: CalendarDate("2026-11-01")).dateInterval(in: ist))
        #expect(openEnded.end == .distantFuture)
        #expect(PhotoQuery().dateInterval(in: ist) == nil)
    }

    @Test func mediaFilterAdmitsKinds() {
        #expect(PhotoQuery.Media.photo.admits(.livePhoto) && !PhotoQuery.Media.photo.admits(.screenshot))
        #expect(PhotoQuery.Media.screenshot.admits(.screenshot) && !PhotoQuery.Media.screenshot.admits(.photo))
        #expect(PhotoMediaKind.allCases.allSatisfy(PhotoQuery.Media.any.admits))
    }

    @Test func photoSearchResultDecodesSnakeCase() throws {
        let json = #"""
            {"hits":[{"asset_id":"A1","captured_at":"2026-11-11T18:30:05+05:30","score":0.82,"labels":["cap"],
              "matched":["label:cap","color:blue"],"media":"photo"},{"asset_id":"A2","score":0.4}],
             "indexed_count":1200,"limited_library":true,"next_cursor":"2"}
            """#
        let result = try ZoroJSON.decoder().decode(PhotoSearchResult.self, from: Data(json.utf8))
        #expect(result.hits.map(\.assetId) == ["A1", "A2"])
        #expect(result.hits[0].capturedAt == ZoroJSON.parseDate("2026-11-11T13:00:05Z"))
        #expect(result.hits[0].matched == ["label:cap", "color:blue"])
        #expect(result.hits[1].labels.isEmpty && result.hits[1].media == .photo && result.hits[1].capturedAt == nil)
        #expect(result.indexedCount == 1200 && result.limitedLibrary && result.nextCursor == "2")
        let again = try ZoroJSON.decoder().decode(PhotoSearchResult.self, from: ZoroJSON.encoder().encode(result))
        #expect(again == result)
    }

    @Test func indexStatusCanBePausedWithAReason() {
        let status = PhotoIndexStatus(state: .paused, indexedCount: 10, totalCount: 40, pausedReason: "low_power")
        #expect(status.state == .paused && status.pausedReason == "low_power" && status.failureReason == nil)
        #expect(PhotoIndexStatus.State.allCases.map(\.rawValue) == ["not_started", "indexing", "paused", "ready", "failed"])
    }

    @Test func calendarDateParsesOnlyRealDays() {
        #expect(CalendarDate("2026-11-13")?.description == "2026-11-13")
        #expect(CalendarDate("2024-02-29") != nil)
        for raw in ["2026-02-29", "2026-13-01", "2026-1-01", "20261113", "2026-11-13T00:00:00Z", ""] {
            #expect(CalendarDate(raw) == nil, "\(raw)")
        }
        #expect(CalendarDate("2026-11-12")! < CalendarDate("2026-11-13")!)
    }

    // MARK: Device action errors and approvals

    @Test func invalidArgumentsIsAContractErrorCode() {
        #expect(DeviceActionErrorCode(rawValue: "invalid_arguments") == .invalidArguments)
        #expect(Set(DeviceActionErrorCode.allCases.map(\.rawValue)) ==
            ["permission_denied", "unsupported", "user_cancelled", "invalid_arguments", "expired", "failed"])
        let request = DeviceActionRequest(actionId: "a", tool: "device.photos.search", risk: .low, expiresAt: Date())
        #expect(DeviceActionResult.failure(request, code: .invalidArguments).errorCode == "invalid_arguments")
    }

    @Test func approvalTaintedDefaultsToFalse() throws {
        let base = #""approval_id":"ap_1","tool":"comms.send_email","risk":"high","level":"confirm","title":"t","summary":"s","action_digest":"ab","expires_at":"2099-01-01T00:00:00Z""#
        let plain = try ZoroJSON.decoder().decode(ApprovalRequest.self, from: Data("{\(base)}".utf8))
        #expect(!plain.tainted)
        let tainted = try ZoroJSON.decoder().decode(ApprovalRequest.self, from: Data("{\(base),\"tainted\":true}".utf8))
        #expect(tainted.tainted)
        let again = try ZoroJSON.decoder().decode(ApprovalRequest.self, from: ZoroJSON.encoder().encode(tainted))
        #expect(again == tainted)
    }

    // MARK: Voice

    @Test func voiceOptionsCarryTheActivationMode() {
        #expect(VoiceSessionOptions().activation == nil)  // the saved setting applies
        #expect(VoiceSessionOptions(activation: .holdToTalk).activation?.rawValue == "hold_to_talk")
        let words = VoiceTranscript(text: "kal subah", isFinal: false, speaker: .owner, language: "hinglish")
        #expect(words.speaker == .owner && !words.isFinal)
    }

    @Test func unavailableServicesAnswerTheNewMembers() async {
        let service = UnavailableService()
        await service.finishListening()
        var count = 0
        for await _ in service.transcriptUpdates() { count += 1 }
        #expect(count == 0)
        await #expect(throws: ZoroError.self) { try await service.skipToNext() }
        await #expect(throws: ZoroError.self) { try await service.skipToPrevious() }
        await #expect(throws: ZoroError.self) { try await service.liveSession() }
    }
}
