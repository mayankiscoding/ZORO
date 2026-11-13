import Foundation
import Testing
import ZoroCore
@testable import SystemFeatures

@MainActor
@Suite("Memory view model")
struct MemoryTests {
    func make(
        records: [MemoryRecord] = [memory("m1"), memory("m2", "Prefers Hindi")], review: [MemoryRecord] = [],
        next: String? = nil, identity: FakeIdentity = FakeIdentity(), settings: MemorySettings = memorySettings()
    ) -> (MemoryViewModel, FakeAPI, FakeIdentity) {
        let api = FakeAPI()
        api.on("GET /v1/memory/settings") { _ in settings }
        api.on("GET /v1/memory") { request in
            let status = request.query.first { $0.name == "status" }?.value
            let cursor = request.query.first { $0.name == "cursor" }?.value
            if status == "pending_review" { return Page(items: review, nextCursor: nil) }
            if cursor == "p2" { return Page(items: [memory("m3", "Third")], nextCursor: nil) }
            return Page(items: records, nextCursor: next)
        }
        let vm = MemoryViewModel(api: api, identity: identity)
        return (vm, api, identity)
    }

    // MARK: states

    @Test func loadShowsRecordsSettingsAndReviewCount() async {
        let (vm, _, _) = make(review: [memory("r1", status: .pendingReview)])
        #expect(vm.phase == .idle)
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.records.map(\.id) == ["m1", "m2"])
        #expect(vm.settings?.categories.count == MemoryCategory.allCases.count)
        #expect(vm.reviewCount == 1)
    }

    @Test func loadShowsEmptyWithASentenceThatSaysWhatIsGoingOn() async {
        let (vm, _, _) = make(records: [])
        await vm.load()
        #expect(vm.phase == .empty)
        #expect(vm.emptyMessage == "ZORO hasn't saved anything about you yet.")
    }

    @Test func emptyMessageNamesASwitchedOffCategory() async {
        let (vm, _, _) = make(records: [], settings: memorySettings(enabled: false))
        await vm.load()
        #expect(vm.emptyMessage.contains("switched off"))
    }

    @Test func loadErrorIsFailedWithRetry() async {
        let api = FakeAPI()
        api.on("GET /v1/memory/settings") { _ in throw ZoroError.http(status: 500, body: nil) }
        api.on("GET /v1/memory") { _ in throw ZoroError.http(status: 500, body: nil) }
        let vm = MemoryViewModel(api: api, identity: FakeIdentity())
        await vm.load()
        guard case .failed(let failure) = vm.phase else { Issue.record("expected failed, got \(vm.phase)"); return }
        #expect(failure.retryable)
    }

    @Test func loadWhenUnreachableIsDisconnected() async {
        let api = FakeAPI()  // every request throws .transport
        let vm = MemoryViewModel(api: api, identity: FakeIdentity())
        await vm.load()
        #expect(vm.phase.isDisconnected)
        #expect(vm.phase.failure?.message == SystemCopy.unreachable)
    }

    @Test func loadWhenNotPairedIsDisconnectedAndNotRetryable() async {
        let api = FakeAPI()
        api.on("GET /v1/memory/settings") { _ in throw ZoroError.notPaired }
        api.on("GET /v1/memory") { _ in throw ZoroError.notPaired }
        let vm = MemoryViewModel(api: api, identity: FakeIdentity())
        await vm.load()
        #expect(vm.phase.isDisconnected)
        #expect(vm.phase.failure?.retryable == false)
    }

    // MARK: navigation, pagination, search

    @Test func selectingReviewQueueLoadsPendingItems() async {
        let (vm, _, _) = make(review: [memory("r1", status: .pendingReview), memory("r2", status: .pendingReview)])
        await vm.load()
        await vm.select(.reviewQueue)
        #expect(vm.section == .reviewQueue)
        #expect(vm.records.map(\.id) == ["r1", "r2"])
    }

    @Test func loadMoreAppendsTheNextPage() async {
        let (vm, api, _) = make(next: "p2")
        await vm.load()
        #expect(vm.hasMore)
        await vm.loadMore()
        #expect(vm.records.map(\.id) == ["m1", "m2", "m3"])
        #expect(!vm.hasMore)
        let cursors = api.sent(.get, "/v1/memory").compactMap { $0.query.first { $0.name == "cursor" }?.value }
        #expect(cursors == ["p2"])
    }

    @Test func searchShowsResultsAndEmptyQueryClearsThem() async {
        let (vm, api, _) = make()
        api.on("GET /v1/memory/search") { _ in ListOrPageBox.items([memory("s1", "Chai without sugar")]) }
        await vm.load()
        vm.searchText = "chai"
        await vm.search()
        #expect(vm.visibleRecords.map(\.id) == ["s1"])
        vm.searchText = "  "
        await vm.search()
        #expect(vm.searchResults == nil)
        #expect(vm.visibleRecords.map(\.id) == ["m1", "m2"])
    }

    @Test func searchFailureKeepsTheListAndSaysSo() async {
        let (vm, _, _) = make()
        await vm.load()  // search has no handler: transport error
        vm.searchText = "chai"
        await vm.search()
        #expect(vm.searchResults == nil)
        #expect(vm.notice?.kind == .failure)
        #expect(vm.notice?.text.hasPrefix("Search didn't happen.") == true)
    }

    // MARK: edits

    @Test func correctReplacesTheRecord() async {
        let (vm, api, _) = make()
        api.on("PATCH /v1/memory/m1") { _ in memory("m1", "Likes masala chai") }
        await vm.load()
        await vm.correct(vm.records[0], to: "  Likes masala chai ")
        #expect(vm.records[0].text == "Likes masala chai")
        #expect(vm.notice == .success("Corrected."))
        let body = String(data: api.sent(.patch, "/v1/memory/m1")[0].body ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"verified\":true"))
    }

    @Test func correctWithEmptyTextIsRefusedWithoutARequest() async {
        let (vm, api, _) = make()
        await vm.load()
        await vm.correct(vm.records[0], to: "   ")
        #expect(api.sent(.patch, "/v1/memory/m1").isEmpty)
        #expect(vm.notice?.kind == .failure)
    }

    @Test func correctOnAReadOnlyMemoryIsRefused() async {
        let (vm, api, _) = make(records: [memory("m1", editable: false)])
        await vm.load()
        await vm.correct(vm.records[0], to: "New text")
        #expect(api.sent(.patch, "/v1/memory/m1").isEmpty)
        #expect(vm.notice?.text.contains("can't be edited") == true)
    }

    @Test func correctFailureKeepsTheOldText() async {
        let (vm, api, _) = make()
        api.on("PATCH /v1/memory/m1") { _ in throw ZoroError.http(status: 500, body: nil) }
        await vm.load()
        await vm.correct(vm.records[0], to: "Something else")
        #expect(vm.records[0].text == "Likes chai")
        #expect(vm.notice?.kind == .failure)
        #expect(vm.busyIds.isEmpty)
    }

    @Test func verifyStampsTheRecord() async {
        let (vm, api, _) = make()
        let verified: MemoryRecord = {
            var r = memory("m1")
            r.lastVerifiedAt = t0
            return r
        }()
        api.on("PATCH /v1/memory/m1") { _ in verified }
        await vm.load()
        await vm.verify(vm.records[0])
        #expect(vm.records[0].lastVerifiedAt == t0)
        #expect(vm.notice == .success("Verified."))
    }

    @Test func keepingAReviewItemRemovesItFromTheQueue() async {
        let pending = memory("r1", status: .pendingReview)
        let (vm, api, _) = make(review: [pending])
        api.on("PATCH /v1/memory/r1") { _ in memory("r1", status: .active) }
        await vm.load()
        await vm.select(.reviewQueue)
        await vm.keep(vm.records[0])
        #expect(vm.records.isEmpty)
        #expect(vm.reviewCount == 0)
        #expect(vm.phase == .empty)
    }

    @Test func deleteRemovesAtOnceAndRestoresOnFailure() async {
        let (vm, api, _) = make()
        api.on("DELETE /v1/memory/m1") { _ in throw ZoroError.timeout }
        await vm.load()
        let first = vm.records[0]
        await vm.delete(first)
        #expect(vm.records.map(\.id) == ["m1", "m2"], "the row comes back in its place when the server refuses")
        #expect(vm.notice?.kind == .failure)
    }

    @Test func deleteSuccessLeavesTheRowGoneAndMovesToEmpty() async {
        let (vm, api, _) = make(records: [memory("m1")])
        api.on("DELETE /v1/memory/m1") { _ in () }
        await vm.load()
        await vm.delete(vm.records[0])
        #expect(vm.records.isEmpty)
        #expect(vm.phase == .empty)
        #expect(vm.notice == .success("Deleted."))
    }

    // MARK: category switches and retention

    @Test func switchingACategoryOffUpdatesSettings() async {
        let (vm, api, _) = make()
        let updated = Locked<MemorySettings?>(nil)
        api.on("PUT /v1/memory/settings") { request in
            let decoded = try ZoroJSON.decoder().decode(MemorySettings.self, from: request.body ?? Data())
            updated.withLock { $0 = decoded }
            return decoded
        }
        await vm.load()
        await vm.setEnabled(false, for: .financial)
        #expect(vm.setting(for: .financial)?.enabled == false)
        #expect(updated.get?.categories.first { $0.category == .financial }?.enabled == false)
        #expect(vm.notice == .success("Money is off."))
    }

    @Test func settingsFailureRollsBack() async {
        let (vm, api, _) = make()
        api.on("PUT /v1/memory/settings") { _ in throw ZoroError.http(status: 500, body: nil) }
        await vm.load()
        await vm.setEnabled(false, for: .financial)
        #expect(vm.setting(for: .financial)?.enabled == true)
        #expect(vm.notice?.kind == .failure)
    }

    @Test func retentionMustBePositiveAndNilMeansKeepUntilDeleted() async {
        let (vm, api, _) = make()
        api.on("PUT /v1/memory/settings") { request in try ZoroJSON.decoder().decode(MemorySettings.self, from: request.body ?? Data()) }
        await vm.load()
        await vm.setRetention(days: 0, for: .episodic)
        #expect(api.sent(.put, "/v1/memory/settings").isEmpty)
        #expect(vm.notice?.kind == .failure)
        await vm.setRetention(days: 90, for: .episodic)
        #expect(vm.setting(for: .episodic)?.retentionDays == 90)
        await vm.setRetention(days: nil, for: .episodic)
        #expect(vm.setting(for: .episodic)?.retentionDays == nil)
    }

    // MARK: signed actions

    @Test func exportSignsThenSendsTheProof() async {
        let (vm, api, identity) = make()
        api.on("POST /v1/memory/export") { _ in Data("{\"records\":[]}".utf8) }
        await vm.load()
        await vm.exportMemory(category: .profile)
        #expect(identity.signed.get == [.exportMemory(.profile)])
        #expect(vm.export?.suggestedFilename == "zoro-memory-profile.json")
        let body = String(data: api.sent(.post, "/v1/memory/export")[0].body ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("signature_b64"))
    }

    @Test func exportWithoutAProofSendsNothing() async {
        let identity = FakeIdentity()
        identity.proofError = ZoroError.userCancelled
        let (vm, api, _) = make(identity: identity)
        await vm.load()
        await vm.exportMemory(category: nil)
        #expect(api.sent(.post, "/v1/memory/export").isEmpty)
        #expect(vm.export == nil)
    }

    @Test func exportWhenNotPairedSendsNothing() async {
        let identity = FakeIdentity()
        identity.id = nil
        let (vm, api, _) = make(identity: identity)
        await vm.load()
        await vm.exportMemory(category: nil)
        #expect(api.sent(.post, "/v1/memory/export").isEmpty)
        #expect(vm.notice?.text.contains("Export didn't happen") == true)
    }

    @Test func deleteCategoryNeedsAConfirmationThenAProof() async {
        let (vm, api, identity) = make()
        api.on("POST /v1/memory/categories/profile/delete") { _ in () }
        await vm.load()
        await vm.confirmDeleteCategory()  // nothing pending: nothing happens
        #expect(api.sent(.post, "/v1/memory/categories/profile/delete").isEmpty)
        vm.requestDeleteCategory(.profile)
        #expect(vm.pendingCategoryDelete == .profile)
        await vm.confirmDeleteCategory()
        #expect(identity.signed.get == [.deleteMemoryCategory(.profile)])
        #expect(api.sent(.post, "/v1/memory/categories/profile/delete").count == 1)
        #expect(vm.records.isEmpty)
        #expect(vm.phase == .empty)
        #expect(vm.pendingCategoryDelete == nil)
    }

    @Test func deleteCategoryWithoutAProofChangesNothing() async {
        let identity = FakeIdentity()
        identity.proofError = ZoroError.authenticationFailed("no match")
        let (vm, api, _) = make(identity: identity)
        await vm.load()
        vm.requestDeleteCategory(.profile)
        await vm.confirmDeleteCategory()
        #expect(api.sent(.post, "/v1/memory/categories/profile/delete").isEmpty)
        #expect(vm.records.count == 2)
        #expect(vm.notice?.kind == .failure)
        #expect(vm.pendingCategoryDelete == nil)
    }

    @Test func deleteCategoryServerFailureKeepsTheRecords() async {
        let (vm, api, _) = make()
        api.on("POST /v1/memory/categories/profile/delete") { _ in throw ZoroError.http(status: 403, body: ErrorBody(code: "forbidden", message: "Not allowed")) }
        await vm.load()
        vm.requestDeleteCategory(.profile)
        await vm.confirmDeleteCategory()
        #expect(vm.records.count == 2)
        #expect(vm.notice?.kind == .failure)
    }
}

/// The search route answers with a bare list or `{items: []}`; the fake returns the decoded wrapper.
enum ListOrPageBox {
    static func items(_ items: [MemoryRecord]) -> ListOrPage<MemoryRecord> {
        let data = try! ZoroJSON.encoder().encode(items)
        return try! ZoroJSON.decoder().decode(ListOrPage<MemoryRecord>.self, from: data)
    }
}
