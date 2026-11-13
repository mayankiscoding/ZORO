import Foundation
import Testing
@testable import ZoroAppUI

@Suite("Sections and tabs")
struct SectionTests {
    @Test func fifteenSectionsInFourTabs() {
        #expect(AppSection.allCases.count == 15)
        let inTabs = AppTab.allCases.flatMap(\.sections) + [.home, .liveVoice]
        #expect(Set(inTabs) == Set(AppSection.allCases))
        for tab in AppTab.allCases {
            for section in tab.sections { #expect(section.tab == tab) }
        }
        #expect(AppTab.spaces.sections == [.shopping, .finance, .investments, .fitness, .photos, .music])
        #expect(AppTab.you.sections == [.memory, .integrations, .deviceControl, .security, .settings])
    }

    @Test func sidebarHasEverySectionOnce() {
        let all = SidebarGroup.allCases.flatMap(\.sections)
        #expect(all.count == 15)
        #expect(Set(all) == Set(AppSection.allCases))
    }

    @Test(arguments: [
        ("shopping", AppSection.shopping), ("live-voice", .liveVoice), ("live_voice", .liveVoice), ("liveVoice", .liveVoice),
        ("Device Control", .deviceControl), ("devicecontrol", .deviceControl), ("privacy", .security), ("zoro", .home),
        ("agents", .activity), ("SETTINGS", .settings),
    ])
    func namesResolve(name: String, section: AppSection) {
        #expect(AppSection(name: name) == section)
    }

    @Test func unknownNameIsNil() {
        #expect(AppSection(name: "payments") == nil)
        #expect(AppSection(name: "") == nil)
    }

    @Test func copyIsSentenceCase() {
        for section in AppSection.allCases where section != .home {
            #expect(section.title != section.title.uppercased())
            #expect(!section.subtitle.isEmpty)
        }
    }
}

@Suite("Deep links")
struct DeepLinkTests {
    @Test func sectionLinks() throws {
        #expect(try DeepLink.parse(URL(string: "zoro://section/shopping")!) == .section(.shopping))
        #expect(try DeepLink.parse(URL(string: "ZORO://section/device-control")!) == .section(.deviceControl))
        #expect(try DeepLink.parse(URL(string: "zoro://section?name=security")!) == .section(.security))
        #expect(try DeepLink.parse(URL(string: "zoro://section/live-voice")!) == .voice)
    }

    @Test func voiceAndAskLinks() throws {
        #expect(try DeepLink.parse(URL(string: "zoro://voice")!) == .voice)
        #expect(try DeepLink.parse(URL(string: "zoro://ask?text=%20add%20milk%20")!) == .ask("add milk"))
        #expect(try DeepLink.parse(URL(string: "zoro://ask?q=hello")!) == .ask("hello"))
    }

    @Test func pairLink() throws {
        let link = try DeepLink.parse(URL(string: "zoro://pair?server=zoro.example.ts.net:8443&code=abcd-1234")!)
        guard case .pair(let pairing) = link else {
            Issue.record("expected a pair link")
            return
        }
        #expect(pairing.serverURL.absoluteString == "https://zoro.example.ts.net:8443")
        #expect(pairing.code == "ABCD1234")
    }

    @Test func failures() {
        #expect(throws: DeepLinkError.unsupportedScheme("https")) { try DeepLink.parse(URL(string: "https://zoro.app/section/shopping")!) }
        #expect(throws: DeepLinkError.unknownRoute("settings")) { try DeepLink.parse(URL(string: "zoro://settings")!) }
        #expect(throws: DeepLinkError.unknownSection("payments")) { try DeepLink.parse(URL(string: "zoro://section/payments")!) }
        #expect(throws: DeepLinkError.unknownSection("")) { try DeepLink.parse(URL(string: "zoro://section")!) }
        #expect(throws: DeepLinkError.missingText) { try DeepLink.parse(URL(string: "zoro://ask?text=%20")!) }
        #expect(throws: DeepLinkError.self) { try DeepLink.parse(URL(string: "zoro://pair?code=ABCD1234")!) }
        #expect(throws: DeepLinkError.self) { try DeepLink.parse(URL(string: "zoro://pair?server=ftp://x&code=ABCD1234")!) }
        #expect(throws: DeepLinkError.self) { try DeepLink.parse(URL(string: "zoro://pair?server=zoro.local&code=--")!) }
    }

    @Test func longAskIsCut() throws {
        let long = String(repeating: "a", count: AskLimits.maxPhraseLength + 50)
        let link = try DeepLink.parse(DeepLink.ask(long).url)
        #expect(link == .ask(String(repeating: "a", count: AskLimits.maxPhraseLength)))
    }

    @Test func canonicalURLsRoundTrip() throws {
        let links: [DeepLink] = AppSection.allCases.filter { $0 != .liveVoice }.map { .section($0) } + [
            .voice, .ask("kal subah 6 baje alarm laga do"), .ask("दूध और अंडे"),
            .pair(PairingLink(serverURL: URL(string: "http://100.64.0.1:8000")!, code: "ABCD1234")),
        ]
        for link in links {
            #expect(try DeepLink.parse(link.url) == link)
        }
    }

    @Test func serverAddresses() {
        #expect(PairingLink.serverURL(from: "zoro.tailnet.ts.net")?.absoluteString == "https://zoro.tailnet.ts.net")
        #expect(PairingLink.serverURL(from: " http://192.168.1.5:8000 ")?.absoluteString == "http://192.168.1.5:8000")
        #expect(PairingLink.serverURL(from: "") == nil)
        #expect(PairingLink.serverURL(from: "not a url") == nil)
        #expect(PairingLink.serverURL(from: "ftp://host") == nil)
        #expect(PairingLink.normaliseCode(" ab cd-12_34 ") == "ABCD1234")
        #expect(PairingLink.normaliseCode("कोड12") == "12")
    }
}

@Suite("Navigation model")
@MainActor
struct NavigationModelTests {
    @Test func openPutsSectionInItsTabAndSidebar() {
        let nav = AppNavigation()
        nav.open(.finance)
        #expect(nav.selectedTab == .spaces)
        #expect(nav.spacesPath == [.finance])
        #expect(nav.sidebarSelection == .finance)
        nav.open(.history)
        #expect(nav.selectedTab == .activity)
        #expect(nav.activityPath == [.history])
        nav.open(.security)
        #expect(nav.selectedTab == .you && nav.youPath == [.security])
        nav.open(.liveVoice)
        #expect(nav.selectedTab == .zoro && nav.isLiveVoicePresented && nav.sidebarSelection == .home)
        nav.open(.home)
        #expect(!nav.isLiveVoicePresented)
    }

    @Test func urlHandling() {
        let nav = AppNavigation()
        #expect(nav.handle(URL(string: "zoro://section/music")!))
        #expect(nav.selectedTab == .spaces && nav.spacesPath == [.music])
        #expect(nav.handle(URL(string: "zoro://voice")!))
        #expect(nav.isLiveVoicePresented)
        #expect(nav.handle(URL(string: "zoro://ask?text=compare%20my%20basket")!))
        #expect(nav.pendingAsk == "compare my basket" && nav.selectedTab == .zoro && !nav.isLiveVoicePresented)
        #expect(nav.handle(URL(string: "zoro://pair?server=zoro.local&code=ABCD1234")!))
        #expect(nav.pendingPairing?.code == "ABCD1234")
        #expect(!nav.handle(URL(string: "zoro://section/nothing")!))
        #expect(nav.linkError == "ZORO has no section called \"nothing\".")
        nav.open(.memory)
        #expect(nav.linkError == nil)
    }

    @Test func restorationRoundTrip() {
        let nav = AppNavigation()
        nav.open(.photos)
        nav.open(.integrations)
        let data = nav.restoration.encoded()
        let restored = AppNavigation()
        restored.restore(NavigationRestoration.decode(data)!)
        #expect(restored.selectedTab == .you)
        #expect(restored.spacesPath == [.photos])
        #expect(restored.youPath == [.integrations])
        #expect(restored.sidebarSelection == .integrations)
    }

    @Test func restorationNeverReopensLiveVoiceOrForeignSections() {
        let nav = AppNavigation()
        nav.restore(NavigationRestoration(tab: .spaces, spacesPath: [.shopping, .security], sidebar: .liveVoice))
        #expect(!nav.isLiveVoicePresented)
        #expect(nav.sidebarSelection == .home)
        #expect(nav.spacesPath == [.shopping])
    }

    @Test func badRestorationDataIsIgnored() {
        #expect(NavigationRestoration.decode(nil) == nil)
        #expect(NavigationRestoration.decode(Data()) == nil)
        #expect(NavigationRestoration.decode(Data("{\"tab\":\"elsewhere\"}".utf8)) == nil)
    }
}
