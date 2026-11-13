// UNVERIFIED-ON-HOST
// Swift Testing unit tests for the iPhone app target (CLAUDE.md: Swift Testing only). They run only under
// Xcode with the app as test host; the same composition is covered by Swift Testing in ZoroComposition
// on the host.
#if os(iOS)
import Foundation
import Testing
import ZoroAppUI
import ZoroComposition
import ZoroCore

@MainActor
struct ZOROAppTests {
    private func makeApp() async -> ZoroApplication {
        await ZoroApplication.make(CompositionConfiguration(
            platform: .ios, storage: .inMemory,
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            serverURL: URL(string: "https://127.0.0.1:9"), assumePaired: true, deviceName: "Test iPhone",
            startsDeviceChannel: false, defaultsSuite: "app.zoro.xctest.\(UUID().uuidString)"))
    }

    @Test func launchBuildsEveryScreen() async {
        let app = await makeApp()
        #expect(app.shell.sections.registeredSections == Set(AppSection.allCases))
    }

    @Test func iPhoneAnnouncesPhoneToolsOnly() async {
        let app = await makeApp()
        let tools = await app.deviceActions.supportedTools
        #expect(tools.contains("device.health.query"))
        #expect(!tools.contains { $0.hasPrefix("mac.") })
        let hello = await app.helloTools()
        #expect(Set(hello).isSubset(of: Set(tools)))
    }

    @Test func homeKitIsNotAnnouncedWithoutTheEntitlementFlag() async {
        let app = await makeApp()
        let hello = await app.helloTools()
        #expect(!hello.contains("ios.home.run_scene"))
    }

    @Test func deepLinkOpensASection() async throws {
        let app = await makeApp()
        let url = try #require(URL(string: "zoro://section/finance"))
        #expect(app.handle(url))
        #expect(app.shell.navigation.selectedTab == .spaces)
    }
}
#endif
