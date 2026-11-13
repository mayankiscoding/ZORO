#if os(macOS)
import Foundation
import PhotosFeature
import ZoroCore

/// Mac answers for the questions the composition root asks per platform.
enum PlatformHooks {
    /// The Mac has no Health data; screens show the typed "unavailable" state.
    static func health() -> any HealthDataProviding { UnavailableService() }
    /// Messages composing is an iPhone tool.
    static func canComposeMessages() -> Bool { false }
    /// The Mac has no limited-library picker; the Photos screen shows Settings instructions instead.
    static func limitedLibraryPresenter() -> any LimitedLibraryPresenting { UnavailableLimitedLibraryPresenter() }
}

/// In-memory bookmarks for tests and the smoke test.
final class InMemoryBookmarkStorage: BookmarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func load() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func save(_ data: Data) { lock.lock(); self.data = data; lock.unlock() }
}
#endif
