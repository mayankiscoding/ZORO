import AppIntents
import Foundation
import SwiftUI
import Testing
import ZoroCore
@testable import ZoroAppUI

@Suite("Registries")
@MainActor
struct RegistryTests {
    @Test func sectionRegistry() {
        let registry = SectionRegistry()
        #expect(registry.registeredSections.isEmpty)
        #expect(!registry.isRegistered(.shopping))
        registry.register(.shopping) { Text("Shopping screen") }
        #expect(registry.isRegistered(.shopping))
        #expect(registry.registeredSections == [.shopping])
        _ = registry.view(for: .shopping)
        _ = registry.view(for: .finance)
        registry.unregister(.shopping)
        #expect(!registry.isRegistered(.shopping))
        #expect(SectionNotConnectedView.message(for: .finance).hasPrefix("Finance is not connected yet."))
    }

    @Test func cardRegistry() {
        let registry = CardRendererRegistry()
        #expect(!registry.hasRenderer(for: "product"))
        registry.register(kind: "product") { card in Text(card.title ?? "") }
        #expect(registry.hasRenderer(for: "product"))
        _ = registry.view(for: UICard(kind: "product"))
        _ = registry.view(for: UICard(kind: "unknown"))
        registry.unregister(kind: "product")
        #expect(!registry.hasRenderer(for: "product"))
    }

    @Test func fallbackRows() {
        let card = UICard(kind: "reminder_set", title: nil, payload: [
            "due_at": "2026-11-14 06:00", "listName": "Home", "done": false, "count": 3, "ratio": 0.5,
            "tags": ["a", "b"], "items": [["x": 1]], "meta": ["k": "v"], "note": nil, "empty": "",
        ])
        let model = GenericCardModel(card)
        #expect(model.title == "Reminder set")
        #expect(model.rows.map(\.label) == ["Count", "Done", "Due at", "Items", "List name", "Ratio", "Tags"])
        #expect(model.rows.map(\.value) == ["3", "No", "2026-11-14 06:00", "1 item", "Home", "0.5", "a and b"])
        #expect(model.hiddenCount == 3)
    }

    @Test func fallbackTitles() {
        #expect(GenericCardModel(UICard(kind: "x", title: " Basket ")).title == "Basket")
        #expect(GenericCardModel(UICard(kind: "x", title: "", payload: ["title": "From payload"])).title == "From payload")
        #expect(GenericCardModel(UICard(kind: "price_comparison")).title == "Price comparison")
    }

    @Test func fallbackKeepsMoneyStringsExactAndCapsRows() {
        var payload: JSONObject = ["total": "1234.50"]
        for i in 0..<20 { payload["field_\(String(format: "%02d", i))"] = .string("v\(i)") }
        let model = GenericCardModel(UICard(kind: "k", payload: payload))
        #expect(model.rows.count == GenericCardModel.maxRows)
        #expect(model.hiddenCount == 21 - GenericCardModel.maxRows)
        let only = GenericCardModel(UICard(kind: "k", payload: ["total": "1234.50"]))
        #expect(only.rows.first?.value == "1234.50")
    }

    @Test(arguments: [("delivery_fee", "Delivery fee"), ("unitPrice", "Unit price"), ("a.b-c", "A b c"), ("URL", "Url"), ("", "")])
    func humanise(key: String, expected: String) {
        #expect(GenericCardModel.humanise(key) == expected)
    }
}

@Suite("App Intents")
@MainActor
struct IntentTests {
    @Test func askParameter() {
        #expect(IntentRouting.askLink(phrase: "  add milk ") == .ask("add milk"))
        #expect(IntentRouting.askLink(phrase: "   ") == nil)
        #expect(IntentRouting.askLink(phrase: nil) == nil)
        let long = String(repeating: "क", count: AskLimits.maxPhraseLength + 1)
        #expect(IntentRouting.askLink(phrase: long) == .ask(String(long.prefix(AskLimits.maxPhraseLength))))
    }

    @Test func sectionParameter() {
        #expect(IntentRouting.sectionLink(.liveVoice) == .voice)
        #expect(IntentRouting.sectionLink(.finance) == .section(.finance))
        #expect(AppSection.caseDisplayRepresentations.count == AppSection.allCases.count)
    }

    @Test func inbox() {
        let inbox = IntentInbox()
        inbox.post(.voice)
        inbox.post(.section(.music))
        #expect(inbox.drain() == [.voice, .section(.music)])
        #expect(inbox.drain().isEmpty)
    }

    @Test func intentsPostToTheSharedInbox() async throws {
        _ = IntentInbox.shared.drain()
        _ = try await StartVoiceIntent().perform()
        _ = try await OpenSectionIntent(section: .photos).perform()
        // AskZoroIntent now answers in the background (IntentTests.swift); it posts only to continue in the app.
        #expect(IntentInbox.shared.drain() == [.voice, .section(.photos)])
    }

    @Test func intentsOpenTheApp() {
        #expect(!AskZoroIntent.openAppWhenRun)
        #expect(StartVoiceIntent.openAppWhenRun)
        #expect(OpenSectionIntent.openAppWhenRun)
    }

    @Test func shellAppliesIntentLinks() {
        let shell = makeShell()
        shell.inbox.post(.section(.security))
        shell.inbox.post(.ask("hello"))
        shell.drainIntents()
        #expect(shell.navigation.selectedTab == .zoro)
        #expect(shell.navigation.youPath == [.security])
        #expect(shell.navigation.pendingAsk == "hello")
    }

    @Test func pairLinkWhenAlreadyPairedIsRefused() {
        let shell = makeShell(isPaired: true)
        #expect(shell.handle(URL(string: "zoro://pair?server=zoro.local&code=ABCD1234")!))
        #expect(shell.navigation.linkError?.contains("already connected") == true)
    }

    func makeShell(isPaired: Bool = true, api: FakeAPI = FakeAPI()) -> ZoroAppShell {
        ZoroAppShell(
            home: makeHome(api: api), approvals: ApprovalSheetPresenter(biometrics: FakeBiometrics()),
            confirmations: DeviceActionConfirmationPresenter(),
            onboarding: OnboardingModel(pairing: FakePairing(), preferences: MemoryPreferences(), showsShortcutGuide: false),
            isPaired: isPaired, inbox: IntentInbox())
    }
}

@Suite("Handoff")
struct HandoffTests {
    @Test func roundTrip() {
        let activity = ConversationActivity.make(conversationId: "conv_1")
        #expect(activity.activityType == "app.zoro.conversation")
        #expect(activity.isEligibleForHandoff)
        #expect(!activity.isEligibleForSearch)
        #expect(activity.title == "Conversation with ZORO")
        #expect(ConversationActivity.parse(activity) == ConversationActivity.Continuation(conversationId: "conv_1", section: .home))
    }

    @Test func rejectsForeignOrEmptyActivities() {
        #expect(ConversationActivity.parse(NSUserActivity(activityType: "com.example.other")) == nil)
        let empty = NSUserActivity(activityType: ConversationActivity.type)
        #expect(ConversationActivity.parse(empty) == nil)
        empty.userInfo = ["conversation_id": "  "]
        #expect(ConversationActivity.parse(empty) == nil)
        empty.userInfo = ["conversation_id": "c", "section": "nowhere"]
        #expect(ConversationActivity.parse(empty)?.section == .home)
    }
}

@Suite("Opening a conversation from another device")
@MainActor
struct RemoteConversationTests {
    @Test func handoffAdoptsTheServersConversation() async {
        var api = FakeAPI()
        let at = Date(timeIntervalSince1970: 1_794_475_815)
        api.remoteMessages["conv_phone"] = [
            Message(id: "m1", role: .user, text: "Remind me to call Asha", createdAt: at),
            Message(id: "m2", role: .assistant, text: "When?", createdAt: at),
        ]
        let shell = makeShellForRemote(api: api)
        await shell.openConversation(id: "conv_phone")
        #expect(shell.home.conversation.conversationId == "conv_phone")
        #expect(shell.home.conversation.transcript.map(\.text) == ["Remind me to call Asha", "When?"])
        #expect(shell.continuationError == nil)
    }

    @Test func unknownConversationSaysSoAndKeepsTheCurrentOne() async {
        let shell = makeShellForRemote(api: FakeAPI())
        await shell.openConversation(id: "nowhere")
        #expect(shell.home.conversation.conversationId == nil)
        #expect(shell.continuationError == "The conversation couldn't be opened on this device.")
    }

    private func makeShellForRemote(api: FakeAPI) -> ZoroAppShell {
        ZoroAppShell(
            home: makeHome(api: api), approvals: ApprovalSheetPresenter(biometrics: FakeBiometrics()),
            confirmations: DeviceActionConfirmationPresenter(),
            onboarding: OnboardingModel(pairing: FakePairing(), preferences: MemoryPreferences(), showsShortcutGuide: false),
            isPaired: true, inbox: IntentInbox())
    }
}
