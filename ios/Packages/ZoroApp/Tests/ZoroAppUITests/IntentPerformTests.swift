import AppIntents
import Foundation
import Testing
import ZoroCore
@testable import ZoroAppUI

/// Everything that goes through the shared `ZoroIntentDependencies` registration runs one at a time.
@Suite("Intents with registered services", .serialized)
struct IntentPerformTests {
    func services(
        outcome: IntentTurnOutcome = .failed(.offline), language: ZoroLanguage = .english,
        conversations: [ConversationSummary] = [], api: ScriptedTurnAPI = ScriptedTurnAPI(), identity: ProofSigningIdentity = ProofSigningIdentity()
    ) -> (ZoroIntentServices, FixedRunner) {
        let runner = FixedRunner(outcome: outcome)
        var api = api
        api.conversationList = .success(conversations)
        let services = ZoroIntentServices(
            turns: runner, conversations: APIConversationListing(api: api),
            privacy: SignedPrivacyModeTightener(api: api, identity: identity), language: { language })
        return (services, runner)
    }

    /// Outside the system's perform flow an `@Dependency` must be set by hand, as the system would.
    func wired<I: AppIntent>(_ intent: I) -> I {
        var intent = intent
        switch intent {
        case var i as AskZoroIntent: i.dependencies = .shared; intent = i as! I
        case var i as CheckSpendingIntent: i.dependencies = .shared; intent = i as! I
        case var i as CompareBasketIntent: i.dependencies = .shared; intent = i as! I
        case var i as PlayMusicIntent: i.dependencies = .shared; intent = i as! I
        case var i as RememberThisIntent: i.dependencies = .shared; intent = i as! I
        default: break
        }
        return intent
    }

    @Test func askAnswersInTheBackground() async throws {
        let reply = IntentReply(text: "You spent ₹4,250.50 on food last month.", language: "en", dataClasses: [.financial])
        let (s, runner) = services(outcome: .answer(reply))
        ZoroIntents.register(s)
        _ = try await wired(AskZoroIntent(phrase: "  how much did I spend on food last month ")).perform()
        #expect(runner.requests.all == [IntentTurnRequest(text: "how much did I spend on food last month", language: .english)])
    }

    @Test func emptyAskRequestsAValue() async {
        let (s, runner) = services()
        ZoroIntents.register(s)
        await #expect(throws: (any Error).self) { _ = try await wired(AskZoroIntent(phrase: "   ")).perform() }
        #expect(runner.requests.all.isEmpty)
    }

    @Test func focusedIntentsSendTheirTurnText() async throws {
        let (s, runner) = services(outcome: .answer(IntentReply(text: "Done.")), language: .hindi)
        ZoroIntents.register(s)
        _ = try await wired(CheckSpendingIntent(period: .lastMonth, category: .food)).perform()
        _ = try await wired(CompareBasketIntent()).perform()
        _ = try await wired(PlayMusicIntent(query: "Kishore Kumar", onMac: true)).perform()
        _ = try await wired(RememberThisIntent(note: "गाड़ी B2 पर खड़ी है")).perform()
        #expect(runner.requests.all.map(\.text) == [
            "पिछले महीने खाने पर मैंने कितना खर्च किया?", "मेरी बास्केट की कीमतें सभी स्टोर में मिलाकर दिखाएँ।",
            "मेरे Mac पर Kishore Kumar चलाएँ।", "यह याद रखें: गाड़ी B2 पर खड़ी है",
        ])
        #expect(runner.requests.all.allSatisfy { $0.language == .hindi })
    }

    @Test func notConfiguredSaysSoWithoutCallingAnything() async {
        ZoroIntents.register(.notConfigured)
        let plan = await IntentTurnFlow.plan(text: "hello", services: ZoroIntentDependencies.shared.current)
        #expect(plan.dialog == "ZORO isn't ready for Siri yet. Open ZORO once, then try again.")
        #expect(await SwitchToPrivateModeIntent.dialog(services: .notConfigured) == plan.dialog)
    }

    @Test func privateModeTightensWithASignedProof() async {
        let api = ScriptedTurnAPI(security: .success(FakeAPI.state(.cloudIntelligence)))
        let identity = ProofSigningIdentity()
        let (s, _) = services(api: api, identity: identity)
        #expect(await SwitchToPrivateModeIntent.dialog(services: s) == "Private mode is on.")
        #expect(identity.signed.all == ["set_privacy_mode|strict_private"])
        #expect(api.privacyUpdates.all.map(\.mode) == [.strictPrivate])
    }

    @Test func privateModeAlreadyOnSendsNothing() async {
        let api = ScriptedTurnAPI(security: .success(FakeAPI.state(.strictPrivate)))
        let identity = ProofSigningIdentity()
        let (s, _) = services(language: .hindi, api: api, identity: identity)
        #expect(await SwitchToPrivateModeIntent.dialog(services: s) == "प्राइवेट मोड पहले से चालू है।")
        #expect(identity.signed.all.isEmpty)
        #expect(api.privacyUpdates.all.isEmpty)
    }

    @Test func privateModeFailures() async {
        let cancelled = services(identity: ProofSigningIdentity(signingError: .userCancelled)).0
        #expect(await SwitchToPrivateModeIntent.dialog(services: cancelled)
            == "Private mode wasn't changed. Switch it in Security and privacy in the ZORO app.")
        let foreign = services(identity: ProofSigningIdentity(signedBy: "dev_other")).0
        #expect(await SwitchToPrivateModeIntent.dialog(services: foreign).hasPrefix("Private mode wasn't changed."))
        let offline = services(api: ScriptedTurnAPI(security: .failure(.transport("down")))).0
        #expect(await SwitchToPrivateModeIntent.dialog(services: offline).hasPrefix("Can't reach your ZORO server."))
        let unpaired = services(identity: ProofSigningIdentity(id: nil)).0
        #expect(await SwitchToPrivateModeIntent.dialog(services: unpaired).hasPrefix("This device isn't connected"))
    }

    @Test func conversationQuery() async throws {
        let (s, _) = services(conversations: conversationSummaries())
        ZoroIntents.register(s)
        let query = ConversationEntityQuery()
        let suggested = try await query.suggestedEntities()
        #expect(suggested.map(\.id) == ["c1", "c2", "c3"])
        #expect(suggested[2].title == "Conversation with ZORO")
        #expect(try await query.entities(for: ["c2", "missing"]).map(\.id) == ["c2"])
        #expect(try await query.entities(matching: "cafe OCTOBER").map(\.id) == ["c2"])
        #expect(try await query.entities(matching: "basket").map(\.id) == ["c1"])
        #expect(try await query.entities(matching: "  ").count == 3)
    }

    @Test func conversationQueryBeforeRegistrationIsEmpty() async throws {
        ZoroIntents.register(.notConfigured)
        #expect(try await ConversationEntityQuery().suggestedEntities().isEmpty)
    }
}

@Suite("Intent entities and inbox")
struct IntentEntityTests {
    @Test func sectionQuery() async throws {
        let query = SectionEntityQuery()
        let all = try await query.allEntities()
        #expect(all.count == AppSection.allCases.count - 1)
        #expect(!all.contains { $0.section == .liveVoice })
        #expect(try await query.entities(for: ["finance", "nowhere"]).map(\.section) == [.finance])
        #expect(SectionEntity(.security).id == "security")
    }

    @Test func conversationEntityFromSummary() {
        let at = Date(timeIntervalSince1970: 1_794_475_815)
        #expect(ConversationEntity(ConversationSummary(id: "x", title: " Plans ", updatedAt: at)) == ConversationEntity(id: "x", title: "Plans", updatedAt: at))
    }

    @Test @MainActor func inboxCarriesAConversation() {
        let inbox = IntentInbox()
        inbox.postConversation("  ")
        #expect(inbox.pendingConversationId == nil)
        IntentTurnFlow.post(.conversation("conv_9"), to: inbox)
        #expect(inbox.drain() == [.section(.home)])
        #expect(inbox.takeConversation() == "conv_9")
        #expect(inbox.takeConversation() == nil)
        IntentTurnFlow.post(.ask("Send Asha the photos"), to: inbox)
        IntentTurnFlow.post(.link(.voice), to: inbox)
        #expect(inbox.drain() == [.ask("Send Asha the photos"), .voice])
    }

    @Test func onlyNonSensitiveRepliesAreDonated() {
        #expect(ZoroIntentDiscovery.shouldDonate(replyDataClasses: [.public, .personal]))
        #expect(ZoroIntentDiscovery.shouldDonate(replyDataClasses: []))
        #expect(!ZoroIntentDiscovery.shouldDonate(replyDataClasses: [.financial]))
        #expect(!ZoroIntentDiscovery.shouldDonate(replyDataClasses: [.personal, .health]))
        #expect(!ZoroIntentDiscovery.shouldDonate(replyDataClasses: [.sensitive]))
    }

    @Test func authenticationPolicies() {
        #expect(AskZoroIntent.authenticationPolicy == .requiresAuthentication)
        #expect(CheckSpendingIntent.authenticationPolicy == .requiresAuthentication)
        #expect(CompareBasketIntent.authenticationPolicy == .requiresAuthentication)
        #expect(PlayMusicIntent.authenticationPolicy == .requiresAuthentication)
        #expect(RememberThisIntent.authenticationPolicy == .requiresAuthentication)
        #expect(SwitchToPrivateModeIntent.authenticationPolicy == .requiresAuthentication)
        #expect(OpenConversationIntent.authenticationPolicy == .requiresAuthentication)
        #expect(FindPhotoIntent.openAppWhenRun && StartVoiceIntent.openAppWhenRun)
    }
}
