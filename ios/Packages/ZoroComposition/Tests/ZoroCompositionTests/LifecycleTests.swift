import FitnessFeature
import Foundation
import Testing
import ZoroAppUI
import ZoroCore
@testable import ZoroComposition

final class FakeIndexing: PhotoIndexing, @unchecked Sendable {
    var status: MediaAuthorization
    private(set) var starts = 0
    private(set) var stops = 0
    init(_ status: MediaAuthorization) { self.status = status }
    func authorizationStatus() async -> MediaAuthorization { status }
    func startIndexing() async { starts += 1 }
    func stopIndexing() async { stops += 1 }
}

final class FakeSync: FitnessSyncing, @unchecked Sendable {
    private(set) var calls = 0
    var fail = false
    func syncNow() async throws -> FitnessSyncResult {
        calls += 1
        if fail { throw ZoroError.transport("offline") }
        return try ZoroJSON.decoder().decode(FitnessSyncResult.self, from: Fixture.data("fitness_sync_out"))
    }
}

struct FakeHealth: HealthDataProviding {
    var auth: HealthAuthorization
    func authorization() async -> HealthAuthorization { auth }
    func requestAuthorization() async throws {}
    func dailySummary(for day: Date) async throws -> HealthDailySummary { throw ZoroError.notPaired }
    func weeklySummary(weekContaining day: Date) async throws -> HealthWeeklySummary { throw ZoroError.notPaired }
    func workouts(in interval: DateInterval, limit: Int) async throws -> [WorkoutSummary] { [] }
    func dataFreshness() async throws -> [HealthDataFreshness] { [] }
}

final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_900_000_000)
}

@Suite("Polite foreground work")
struct ForegroundWorkTests {
    @Test("Indexing starts only with Photos access and stops in the background")
    func photoIndexing() async {
        let allowed = FakeIndexing(.limited)
        let work = ForegroundWork(fitness: nil, health: FakeHealth(auth: .unavailable), photos: allowed)
        let report = await work.appBecameActive()
        #expect(report.photoIndexingStarted)
        await work.appMovedToBackground()
        #expect(allowed.starts == 1 && allowed.stops == 1)

        let denied = FakeIndexing(.denied)
        let none = await ForegroundWork(fitness: nil, health: FakeHealth(auth: .unavailable), photos: denied).appBecameActive()
        #expect(!none.photoIndexingStarted)
        #expect(denied.starts == 0)
    }

    @Test("Fitness syncs once per interval, only after Health was requested, and retries after a failure")
    func fitnessThrottle() async {
        let clock = Clock()
        let sync = FakeSync()
        let work = ForegroundWork(fitness: sync, health: FakeHealth(auth: .requested), photos: nil, now: { clock.now })
        #expect(await work.appBecameActive().fitnessSynced)
        clock.now += 60
        #expect(!(await work.appBecameActive().fitnessSynced))
        clock.now += ForegroundWork.fitnessInterval
        sync.fail = true
        #expect(!(await work.appBecameActive().fitnessSynced))
        sync.fail = false
        #expect(await work.appBecameActive().fitnessSynced)
        #expect(sync.calls == 3)

        let neverAsked = FakeSync()
        _ = await ForegroundWork(fitness: neverAsked, health: FakeHealth(auth: .notDetermined), photos: nil).appBecameActive()
        #expect(neverAsked.calls == 0)
    }
}

#if os(macOS)
@Suite("Mac approved folders")
struct FolderStoreTests {
    @Test("Folders persist as bookmarks, get contract-safe refs and drop when deleted")
    func bookmarks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zoro-folders-\(UUID().uuidString)")
        let docs = root.appendingPathComponent("My Documents")
        let other = root.appendingPathComponent("my documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = InMemoryBookmarkStorage()

        let store = SecurityScopedFolderStore(storage: storage, securityScoped: false)
        let first = try await store.add(docs)
        #expect(first.ref == "my-documents")
        #expect(SecurityScopedFolderStore.ref(for: other, existing: [first.ref]) == "my-documents-2")
        #expect(SecurityScopedFolderStore.ref(for: URL(fileURLWithPath: "/तस्वीरें"), existing: []) == "folder")

        let reopened = SecurityScopedFolderStore(storage: storage, securityScoped: false)
        let folders = await reopened.approvedFolders()
        #expect(folders.map(\.ref) == ["my-documents"])
        #expect(folders.first?.url.standardizedFileURL.path == docs.standardizedFileURL.path)

        try FileManager.default.removeItem(at: docs)
        #expect(await SecurityScopedFolderStore(storage: storage, securityScoped: false).approvedFolders().isEmpty)
    }
}
#endif

@Suite("Full service graph")
@MainActor
struct ApplicationTests {
    func configuration() -> CompositionConfiguration {
        CompositionConfiguration(
            platform: .running, storage: .inMemory,
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("zoro-app-\(UUID().uuidString)"),
            serverURL: URL(string: "https://127.0.0.1:9"), assumePaired: true, deviceName: "Test device",
            startsDeviceChannel: false, defaultsSuite: "zoro.tests.\(UUID().uuidString)")
    }

    @Test("make() wires every service, registers every screen and announces only registered tools")
    func buildsGraph() async throws {
        let app = await ZoroApplication.make(configuration())
        #expect(app.shell.isPaired)
        #expect(app.shell.sections.registeredSections == Set(AppSection.allCases))
        #expect(Registrations.cardKinds.allSatisfy { app.shell.cards.hasRenderer(for: $0) })
        #expect(app.api.endpoint.current?.host == "127.0.0.1")
        #expect(app.photoService != nil)

        let registered = Set(await app.deviceActions.supportedTools)
        #expect(registered.contains("device.photos.search"))
        #expect(registered.contains("device.music.control"))
        let hello = await app.helloTools()
        #expect(Set(hello).isSubset(of: registered))
        #if os(macOS)
        #expect(registered.contains("mac.file.search"))
        #expect(registered.contains("mac.applescript.run"))
        #expect(!registered.contains { $0.hasPrefix("ios.") })
        #expect(!registered.contains("device.health.query"))
        #endif

        // Approvals in feature packages go through the shell's sheet, not the unavailable stub.
        #expect(!(app.services.approvals is UnavailableService))
        #expect(app.services.deviceActions is CompositeDeviceActionExecutor)
    }

    @Test("An unreachable server leaves the app usable and says so")
    func unreachableServer() async {
        let app = await ZoroApplication.make(configuration())
        await app.inbox.refresh()
        switch app.inbox.phase {
        case .disconnected, .failed: break
        default: Issue.record("expected a disconnected or error state, got \(app.inbox.phase)")
        }
        await app.movedToBackground()
    }
}
