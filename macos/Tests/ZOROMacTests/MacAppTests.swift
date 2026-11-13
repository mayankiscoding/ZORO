import Foundation
import Testing
import ZoroAppUI
import ZoroComposition
import ZoroCore
@testable import ZOROMac

@Suite("Mac companion")
@MainActor
struct MacAppTests {
    @Test("The smoke test builds the whole graph against an unreachable server")
    func smoke() async {
        #expect(await SmokeTest.run(outputDirectory: nil))
    }

    @Test("Approved folders can be added and removed from Settings' model")
    func folderSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zoro-mac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        final class Box: BookmarkStoring, @unchecked Sendable {
            var data: Data?
            func load() -> Data? { data }
            func save(_ data: Data) { self.data = data }
        }
        let model = FolderSettingsModel(store: SecurityScopedFolderStore(storage: Box(), securityScoped: false))
        await model.load()
        #expect(model.folders.isEmpty)
        #expect(model.phase == .loaded)
        await model.add(root)
        #expect(model.folders.count == 1)
        await model.remove(model.folders[0].ref)
        #expect(model.folders.isEmpty)
    }

    @Test("Notifications stay quiet in an unbundled build")
    func notifierUnbundled() async {
        let notifier = MacNotifier()
        #expect(!notifier.isAvailable)
        await notifier.requestPermission()
        #expect(notifier.status == .notDetermined)
    }
}
