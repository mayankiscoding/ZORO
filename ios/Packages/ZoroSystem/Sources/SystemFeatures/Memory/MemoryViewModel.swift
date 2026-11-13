import Foundation
import MemoryClient
import Observation
import ZoroCore

/// A memory export the app can save or share. The bytes are the server's export document, unchanged.
public struct MemoryExport: Equatable, Sendable {
    public var data: Data
    public var suggestedFilename: String
    public var category: MemoryCategory?
}

/// Personal memory: what ZORO has saved about the owner, by category, with a review queue for
/// sensitive items. Reads and edits go through `MemoryClient`. Export and "delete this category"
/// carry a signed proof; without one nothing is sent.
@MainActor
@Observable
public final class MemoryViewModel {
    public enum Section: Equatable, Sendable {
        case category(MemoryCategory)
        case reviewQueue
    }

    public private(set) var phase: ScreenPhase = .idle
    public private(set) var section: Section
    public private(set) var records: [MemoryRecord] = []
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false
    public private(set) var settings: MemorySettings?
    /// Number of memories waiting for review (first page only; "20+" when more exist).
    public private(set) var reviewCount = 0
    public private(set) var reviewCountHasMore = false
    public private(set) var notice: SystemNotice?
    public private(set) var export: MemoryExport?
    /// Set by `requestDeleteCategory`; the screen shows a confirmation naming the category.
    public private(set) var pendingCategoryDelete: MemoryCategory?
    /// Ids of records with a change in flight.
    public private(set) var busyIds: Set<String> = []
    public private(set) var isWorking = false

    public var searchText = ""
    /// nil when not searching.
    public private(set) var searchResults: [MemoryRecord]?
    public private(set) var isSearching = false

    @ObservationIgnored private let client: MemoryClient
    @ObservationIgnored private let authorizer: ProofAuthorizer
    @ObservationIgnored private var pages = PageAccumulator<MemoryRecord>(id: { $0.id })
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let pageSize: Int

    public init(api: any ZoroAPI, identity: any DeviceIdentityProviding, initial: Section = .category(.profile), pageSize: Int = 30) {
        client = MemoryClient(api: api)
        authorizer = ProofAuthorizer(identity: identity)
        section = initial
        self.pageSize = pageSize
    }

    // MARK: - Derived

    public var categories: [MemoryCategory] { MemoryCategory.allCases }

    public var selectedCategory: MemoryCategory? {
        if case .category(let c) = section { c } else { nil }
    }

    public var selectedSetting: MemoryCategorySetting? {
        guard let c = selectedCategory else { return nil }
        return setting(for: c)
    }

    public func setting(for category: MemoryCategory) -> MemoryCategorySetting? {
        settings?.categories.first { $0.category == category }
    }

    public var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What the list shows: search results while searching, otherwise the selected section.
    public var visibleRecords: [MemoryRecord] { searchResults ?? records }

    public var emptyMessage: String {
        if isSearchActive { return "Nothing matches that. Try different words." }
        switch section {
        case .reviewQueue: return "Nothing to review. ZORO asks you here before it keeps anything sensitive."
        case .category(let c):
            if let s = setting(for: c), !s.enabled { return "\(MemoryCopy.title(c)) is switched off, so ZORO isn't saving anything here." }
            return "ZORO hasn't saved anything about you yet."
        }
    }

    // MARK: - Loading

    public func load() async {
        phase = .loading
        notice = nil
        generation += 1
        let gen = generation
        let section = section
        let limit = pageSize
        do {
            async let settingsResult = client.settings()
            async let reviewResult = client.pendingReview(cursor: nil, limit: limit)
            let page: Page<MemoryRecord>
            let reviewPage: Page<MemoryRecord>
            switch section {
            case .reviewQueue:
                reviewPage = try await reviewResult
                page = reviewPage
            case .category(let c):
                page = try await client.list(category: c, status: .active, cursor: nil, limit: limit)
                reviewPage = try await reviewResult
            }
            let loadedSettings = try await settingsResult
            guard gen == generation else { return }
            settings = loadedSettings
            reviewCount = reviewPage.items.count
            reviewCountHasMore = reviewPage.nextCursor != nil
            pages.reset(with: page)
            publish()
            phase = records.isEmpty ? .empty : .loaded
        } catch {
            guard gen == generation, let next = SystemFailure.phase(for: error) else { return }
            phase = next
        }
    }

    public func select(_ newSection: Section) async {
        guard newSection != section else { return }
        section = newSection
        searchText = ""
        searchResults = nil
        pages.clear()
        publish()
        await load()
    }

    public func loadMore() async {
        guard !isLoadingMore, let cursor = pages.nextCursor, !isSearchActive else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let gen = generation
        let section = section
        do {
            let page: Page<MemoryRecord>
            switch section {
            case .reviewQueue: page = try await client.pendingReview(cursor: cursor, limit: pageSize)
            case .category(let c): page = try await client.list(category: c, status: .active, cursor: cursor, limit: pageSize)
            }
            guard gen == generation else { return }
            pages.append(page, requestedCursor: cursor)
            publish()
        } catch {
            if let n = SystemNotice.failed(error, action: "Loading more") { notice = n }
        }
    }

    /// Runs a search for the current text. Call after a short pause in typing; a newer call or a
    /// cancelled task leaves the previous results alone.
    public func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            isSearching = false
            return
        }
        isSearching = true
        defer { if searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query { isSearching = false } }
        do {
            let found = try await client.search(query, category: selectedCategory)
            guard !Task.isCancelled, searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            searchResults = found
        } catch {
            guard !Task.isCancelled else { return }
            if let n = SystemNotice.failed(error, action: "Search") { notice = n }
        }
    }

    // MARK: - Changes to one memory

    /// Corrects the text of a memory. Empty text is refused locally.
    public func correct(_ record: MemoryRecord, to text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice = .failure("A memory needs some text. Write what ZORO should remember, or delete it.")
            return
        }
        guard record.userEditable else {
            notice = .failure("This memory can't be edited. You can delete it.")
            return
        }
        guard trimmed != record.text else { return }
        await mutate(record.id, success: "Corrected.", failure: "Correcting") {
            try await self.client.patch(id: record.id, MemoryPatch(text: trimmed, verified: true))
        }
    }

    /// Marks a memory as still true.
    public func verify(_ record: MemoryRecord) async {
        await mutate(record.id, success: "Verified.", failure: "Verifying") {
            try await self.client.verify(id: record.id)
        }
    }

    /// Review queue: keep this memory (it becomes active and verified).
    public func keep(_ record: MemoryRecord) async {
        await mutate(record.id, success: "Kept.", failure: "Keeping it", removeFromQueueOnSuccess: true) {
            try await self.client.patch(id: record.id, MemoryPatch(status: .active, verified: true))
        }
    }

    /// Deletes one memory. The row leaves the list at once and comes back if the server refuses.
    public func delete(_ record: MemoryRecord) async {
        guard !busyIds.contains(record.id) else { return }
        busyIds.insert(record.id)
        defer { busyIds.remove(record.id) }
        let index = pages.items.firstIndex { $0.id == record.id } ?? 0
        pages.remove(id: record.id)
        searchResults?.removeAll { $0.id == record.id }
        publish()
        if record.status == .pendingReview { reviewCount = max(reviewCount - 1, 0) }
        updateEmptiness()
        do {
            try await client.delete(id: record.id)
            notice = .success("Deleted.")
        } catch {
            pages.insert(record, at: index)
            if record.status == .pendingReview { reviewCount += 1 }
            publish()
            updateEmptiness()
            notice = SystemNotice.failed(error, action: "Deleting") ?? .failure("Deleting didn't happen. Nothing was changed.")
        }
    }

    private func mutate(
        _ id: String, success: String, failure: String, removeFromQueueOnSuccess: Bool = false,
        _ operation: () async throws -> MemoryRecord
    ) async {
        guard !busyIds.contains(id) else { return }
        busyIds.insert(id)
        defer { busyIds.remove(id) }
        do {
            let updated = try await operation()
            if removeFromQueueOnSuccess {
                pages.remove(id: id)
                reviewCount = max(reviewCount - 1, 0)
            } else {
                pages.replace(updated)
            }
            if let i = searchResults?.firstIndex(where: { $0.id == id }) { searchResults?[i] = updated }
            publish()
            updateEmptiness()
            notice = .success(success)
        } catch {
            notice = SystemNotice.failed(error, action: failure)
        }
    }

    // MARK: - Settings per category

    public func setEnabled(_ enabled: Bool, for category: MemoryCategory) async {
        await updateSettings(failure: enabled ? "Switching it on" : "Switching it off", success: enabled ? "\(MemoryCopy.title(category)) is on." : "\(MemoryCopy.title(category)) is off.") { s in
            if let i = s.categories.firstIndex(where: { $0.category == category }) {
                s.categories[i].enabled = enabled
            } else {
                s.categories.append(MemoryCategorySetting(category: category, enabled: enabled))
            }
        }
    }

    /// nil keeps memories until you delete them. Zero or negative days are refused.
    public func setRetention(days: Int?, for category: MemoryCategory) async {
        if let days, days < 1 {
            notice = .failure("Choose at least 1 day, or keep memories until you delete them.")
            return
        }
        await updateSettings(failure: "Changing how long ZORO keeps it", success: days.map { "ZORO keeps \(MemoryCopy.title(category).lowercased()) for \($0) days." } ?? "ZORO keeps \(MemoryCopy.title(category).lowercased()) until you delete it.") { s in
            if let i = s.categories.firstIndex(where: { $0.category == category }) {
                s.categories[i].retentionDays = days
            } else {
                s.categories.append(MemoryCategorySetting(category: category, enabled: true, retentionDays: days))
            }
        }
    }

    private func updateSettings(failure: String, success: String, _ change: (inout MemorySettings) -> Void) async {
        guard var next = settings else {
            notice = .failure("Settings haven't loaded yet. Reload and try again.")
            return
        }
        let previous = next
        change(&next)
        settings = next
        do {
            settings = try await client.updateSettings(next)
            notice = .success(success)
        } catch {
            settings = previous
            notice = SystemNotice.failed(error, action: failure)
        }
    }

    // MARK: - Signed actions

    /// Exports one category, or everything when nil. Signs `export_memory`; without a proof nothing is sent.
    public func exportMemory(category: MemoryCategory?) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let proof = try await authorizer.proof(for: .exportMemory(category))
            let data = try await client.export(MemoryExportRequest(category: category, proof: proof))
            export = MemoryExport(data: data, suggestedFilename: "zoro-memory-\(category?.rawValue ?? "all").json", category: category)
            notice = .success("Export ready.")
        } catch {
            notice = SystemNotice.failed(error, action: "Export")
        }
    }

    public func clearExport() { export = nil }

    public func requestDeleteCategory(_ category: MemoryCategory) { pendingCategoryDelete = category }
    public func cancelDeleteCategory() { pendingCategoryDelete = nil }

    /// Deletes every memory in the pending category. Signs `delete_memory_category`; without a proof nothing is sent.
    public func confirmDeleteCategory() async {
        guard let category = pendingCategoryDelete, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let proof = try await authorizer.proof(for: .deleteMemoryCategory(category))
            try await client.deleteCategory(category, MemoryDeleteCategoryRequest(proof: proof))
            pendingCategoryDelete = nil
            if selectedCategory == category {
                pages.clear()
                publish()
                phase = .empty
            }
            searchResults = nil
            notice = .success("Deleted everything in \(MemoryCopy.title(category).lowercased()).")
        } catch {
            pendingCategoryDelete = nil
            notice = SystemNotice.failed(error, action: "Deleting \(MemoryCopy.title(category).lowercased())")
        }
    }

    public func dismissNotice() { notice = nil }

    // MARK: - Private

    private func publish() {
        records = pages.items
        hasMore = pages.hasMore
    }

    private func updateEmptiness() {
        if phase == .loaded || phase == .empty { phase = records.isEmpty ? .empty : .loaded }
    }
}

/// Plain names and one-line explanations for memory categories.
public enum MemoryCopy {
    public static func title(_ category: MemoryCategory) -> String {
        switch category {
        case .profile: "About you"
        case .episodic: "Moments"
        case .financial: "Money"
        case .fitness: "Fitness"
        case .visual: "Photos and places"
        case .knowledge: "Things you taught ZORO"
        case .conversationState: "Conversation context"
        }
    }

    public static func detail(_ category: MemoryCategory) -> String {
        switch category {
        case .profile: "Name, language, habits and preferences."
        case .episodic: "Things that happened, with the date."
        case .financial: "Accounts and spending notes you shared."
        case .fitness: "Goals and activity notes. Fitness information only."
        case .visual: "What ZORO noted from your photos, on this iPhone."
        case .knowledge: "Facts and rules you asked ZORO to keep."
        case .conversationState: "What a conversation was about, so follow-ups make sense."
        }
    }

    public static func symbol(_ category: MemoryCategory) -> String {
        switch category {
        case .profile: "person"
        case .episodic: "clock.arrow.circlepath"
        case .financial: "indianrupeesign"
        case .fitness: "figure.run"
        case .visual: "photo"
        case .knowledge: "book"
        case .conversationState: "bubble.left.and.bubble.right"
        }
    }

    public static func sensitivityLabel(_ data: DataClass) -> String {
        switch data {
        case .public: "Public"
        case .personal: "Personal"
        case .sensitive: "Sensitive"
        case .financial: "Financial"
        case .health: "Health"
        case .secret: "Secret"
        }
    }
}
