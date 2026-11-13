import ConversationManager
import Foundation
import SwiftUI
import Testing
import ZoroCore
@testable import SystemFeatures

@MainActor
@Suite("Composition")
struct ContainerTests {
    func container(prefs: InMemoryPreferences = InMemoryPreferences()) -> SystemFeaturesContainer {
        let services = ZoroServices.unavailable
        let manager = ConversationManager(
            api: services.api, approvals: services.approvals, deviceActions: services.deviceActions, clientContext: ClientContext(platform: .macos))
        return SystemFeaturesContainer(services: services, conversations: manager, preferences: prefs)
    }

    @Test func anUnpairedAppShowsDisconnectedOnEveryNetworkScreen() async {
        let c = container()
        await c.memory.load()
        await c.integrations.load()
        await c.deviceControl.load()
        await c.security.load()
        await c.audit.load()
        await c.cost.load()
        await c.history.load()
        await c.settings.load()
        #expect(c.memory.phase.isDisconnected)
        #expect(c.integrations.phase.isDisconnected)
        #expect(c.deviceControl.phase.isDisconnected)
        #expect(c.security.phase.isDisconnected)
        #expect(c.audit.phase.isDisconnected)
        #expect(c.cost.phase.isDisconnected)
        #expect(c.history.phase.isDisconnected)
        #expect(c.settings.connection == .notPaired)
        for phase in [c.memory.phase, c.integrations.phase, c.security.phase] {
            #expect(phase.failure?.message == SystemCopy.notPaired)
            #expect(phase.failure?.retryable == false)
        }
    }

    @Test func proofRequiredActionsRefuseOnAnUnpairedApp() async {
        let c = container()
        c.memory.requestDeleteCategory(.profile)
        await c.memory.confirmDeleteCategory()
        #expect(c.memory.notice?.kind == .failure)
        await c.memory.exportMemory(category: nil)
        #expect(c.memory.export == nil)
    }

    @Test func appearanceMapsToAColourSchemeAndPersists() {
        let prefs = InMemoryPreferences()
        let c = container(prefs: prefs)
        #expect(c.preferredColorScheme == nil)
        c.settings.setAppearance(.dark)
        #expect(c.preferredColorScheme == .dark)
        c.settings.setAppearance(.light)
        #expect(c.preferredColorScheme == .light)
        #expect(container(prefs: prefs).preferredColorScheme == .light)
    }

    @Test func screensHaveSentenceCaseTitlesAndExplanations() {
        #expect(SystemScreen.youSections == [.memory, .integrations, .deviceControl, .security, .settings])
        #expect(SystemScreen.activitySections == [.activity, .history])
        for screen in SystemScreen.allCases {
            #expect(!screen.title.isEmpty && !screen.detail.isEmpty && !screen.symbol.isEmpty)
            #expect(screen.title != screen.title.uppercased())
            #expect(!screen.detail.contains("!"))
        }
    }

    @Test func viewsCanBeBuiltFromTheContainer() {
        let c = container()
        _ = YouTabView(container: c)
        _ = ActivityTabView(container: c)
        for screen in SystemScreen.allCases { _ = SystemScreenView(screen, container: c) }
    }
}
