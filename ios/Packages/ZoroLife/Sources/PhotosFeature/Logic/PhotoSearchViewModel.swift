import Foundation
import LifeSupport
import Observation
import ZoroCore

public enum PhotoSearchPhase: Sendable, Equatable {
    /// Nothing searched yet: the invitation.
    case idle
    case searching
    case results
    case noResults
    case failed(ScreenFailure)
}

public enum IndexActionState: Sendable, Equatable {
    case idle
    case rebuilding
    case deleting
    case failed(String)
}

/// State and actions of the photo search screen: words in, real photos out, with how the words were understood, the index
/// status and the limited-library notice.
@MainActor @Observable
public final class PhotoSearchViewModel {
    public var queryText = ""
    public private(set) var phase: PhotoSearchPhase = .idle
    public private(set) var authorization: MediaAuthorization = .notDetermined
    public private(set) var hits: [PhotoHit] = []
    public private(set) var parsed: ParsedPhotoQuery?
    public private(set) var indexedCount = 0
    /// The owner shared only some photos (from the last search, or from the authorisation state).
    public private(set) var limitedLibrary = false
    public private(set) var nextCursor: String?
    public private(set) var isLoadingMore = false
    public private(set) var indexStatus = PhotoIndexStatus(state: .notStarted)
    public private(set) var indexAction: IndexActionState = .idle
    public private(set) var now: Date

    private let photos: any PhotoSearching
    private let parser: any PhotoQueryParsing
    private let picker: any LimitedLibraryPresenting
    private let timeZone: TimeZone
    private let clock: @Sendable () -> Date
    private let sleep: LifeSleep
    private let isMac: Bool

    public init(
        photos: any PhotoSearching, parser: any PhotoQueryParsing, picker: any LimitedLibraryPresenting = UnavailableLimitedLibraryPresenter(),
        timeZone: TimeZone = .current, isMac: Bool = Platform.isMac, clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping LifeSleep = LifeSleeper.real
    ) {
        self.isMac = isMac
        self.photos = photos
        self.parser = parser
        self.picker = picker
        self.timeZone = timeZone
        self.clock = clock
        self.sleep = sleep
        self.now = clock()
    }

    public convenience init(services: ZoroServices, picker: any LimitedLibraryPresenting, timeZone: TimeZone = .current) {
        self.init(photos: services.photos, parser: FallbackPhotoQueryParser(api: services.api), picker: picker, timeZone: timeZone)
    }

    // MARK: Derived

    public var chips: [PhotoQueryChip] { parsed.map { PhotoQueryChips.chips(for: $0.query) } ?? [] }

    public var understoodNote: String? {
        if case .device(let reason)? = parsed?.source { return reason }
        return nil
    }

    public var access: PhotoAccessPresentation? { PhotoAccessPresentation.presentation(authorization, isMac: isMac) }

    /// The limited-library notice shows for a limited authorisation, or when a search reported a partial library.
    public var showsLimitedNotice: Bool { authorization == .limited || (limitedLibrary && authorization == .authorized) }

    public var index: IndexPresentation { IndexPresenter.presentation(indexStatus, now: now, timeZone: timeZone) }

    public var canSearch: Bool {
        !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .searching
    }

    public var emptyMessage: String {
        indexedCount == 0
            ? "No photos are indexed yet. Build the index below, then search again."
            : "No photos matched. Try fewer words or a different date."
    }

    // MARK: Lifecycle

    public func onAppear() async {
        authorization = await photos.authorizationStatus()
        await refreshIndexStatus()
    }

    public func refreshIndexStatus() async {
        indexStatus = await photos.indexStatus()
        now = clock()
    }

    /// Polls the index status while it is indexing. Ends when indexing ends or the task is cancelled.
    public func monitorIndex() async {
        repeat {
            await refreshIndexStatus()
            guard indexStatus.state == .indexing else { return }
            try? await sleep(.seconds(2))
        } while !Task.isCancelled
    }

    // MARK: Access

    public func perform(_ action: PhotoAccessPresentation.Action) async {
        switch action {
        case .allowAccess:
            authorization = await photos.requestAuthorization()
        case .checkAgain:
            authorization = await photos.authorizationStatus()
        case .choosePhotos:
            _ = await picker.presentPicker()
            authorization = await photos.authorizationStatus()
            await refreshIndexStatus()
        }
    }

    // MARK: Search

    public func search() async {
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase != .searching else { return }
        phase = .searching
        if authorization == .notDetermined { authorization = await photos.requestAuthorization() }
        if authorization == .denied || authorization == .restricted || authorization == .notDetermined {
            phase = .failed(ScreenFailure(kind: .error, message: access?.message ?? "Photo access is off. Allow it, then search again.", retryable: false))
            return
        }
        do {
            let result = try await parser.parse(text, timeZone: timeZone)
            parsed = result
            apply(try await photos.search(result.query), appending: false)
        } catch {
            hits = []
            phase = .failed(Self.failure(for: error))
        }
    }

    /// Shows the next page of the same search.
    public func loadMore() async {
        guard let cursor = nextCursor, var query = parsed?.query, !isLoadingMore, phase == .results else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        query.cursor = cursor
        do {
            apply(try await photos.search(query), appending: true)
        } catch {
            phase = .failed(Self.failure(for: error))
        }
    }

    private func apply(_ result: PhotoSearchResult, appending: Bool) {
        if appending {
            let known = Set(hits.map(\.assetId))
            hits += result.hits.filter { !known.contains($0.assetId) }
        } else {
            hits = result.hits
        }
        indexedCount = result.indexedCount
        limitedLibrary = result.limitedLibrary
        nextCursor = result.nextCursor
        now = clock()
        phase = hits.isEmpty ? .noResults : .results
    }

    static func failure(for error: Error) -> ScreenFailure {
        if let invalid = error as? PhotoQuery.ValidationError {
            return ScreenFailure(kind: .error, message: "That search could not be read: \(invalid.reason). Change it and try again.")
        }
        return ScreenFailure.from(error, subject: "your photos")
    }

    // MARK: Index

    public func rebuildIndex() async {
        guard indexAction == .idle || isFailedAction else { return }
        indexAction = .rebuilding
        let poll = Task { await self.pollWhileRebuilding() }
        do {
            try await photos.rebuildIndex()
            indexAction = .idle
        } catch {
            indexAction = .failed(ScreenFailure.from(error, subject: "the photo index").message)
        }
        poll.cancel()
        await refreshIndexStatus()
    }

    private func pollWhileRebuilding() async {
        while indexAction == .rebuilding, !Task.isCancelled {
            await refreshIndexStatus()
            try? await sleep(.seconds(2))
        }
    }

    public func deleteIndex() async {
        guard indexAction == .idle || isFailedAction else { return }
        indexAction = .deleting
        do {
            try await photos.deleteIndex()
            indexAction = .idle
            hits = []
            parsed = nil
            nextCursor = nil
            indexedCount = 0
            phase = .idle
        } catch {
            indexAction = .failed(ScreenFailure.from(error, subject: "the photo index").message)
        }
        await refreshIndexStatus()
    }

    private var isFailedAction: Bool {
        if case .failed = indexAction { return true }
        return false
    }
}
