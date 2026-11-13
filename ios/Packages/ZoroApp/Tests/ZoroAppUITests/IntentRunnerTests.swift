import Foundation
import Testing
import ZoroCore
@testable import ZoroAppUI

@Suite("Siri turn runner")
struct IntentRunnerTests {
    let request = IntentTurnRequest(text: "  How much did I spend on food last month?  ", language: .english)

    func runner(_ api: ScriptedTurnAPI, timeout: Duration = .seconds(5)) -> ZoroIntentTurnRunner {
        ZoroIntentTurnRunner(api: api, client: ClientContext(platform: .ios), timeout: timeout)
    }

    @Test func turnRequestIsMarkedAsSiriAndTrimmed() {
        let sent = runner(ScriptedTurnAPI()).turnRequest(for: IntentTurnRequest(text: " hi ", language: .hindi, privacyMode: .strictPrivate))
        #expect(sent.input.text == "hi")
        #expect(sent.input.modality == .voice)
        #expect(sent.input.languageHint == "hi")
        #expect(sent.conversationId == nil)
        #expect(sent.privacyMode == .strictPrivate)
        #expect(sent.client.appState["surface"] == "siri")
        let long = String(repeating: "a", count: AskLimits.maxPhraseLength + 50)
        #expect(runner(ScriptedTurnAPI()).turnRequest(for: IntentTurnRequest(text: long, language: .english)).input.text.count == AskLimits.maxPhraseLength)
    }

    @Test func answer() async {
        let card = UICard(kind: "spending_summary", title: "Food, October", payload: ["total": "4250.50"])
        let api = ScriptedTurnAPI(events: TurnScript.answer("You spent ₹4,250.50 on food last month.", cards: [card], classes: [.financial]))
        let outcome = await runner(api).run(request)
        #expect(outcome == .answer(IntentReply(
            text: "You spent ₹4,250.50 on food last month.", cards: [card], language: "en", dataClasses: [.financial],
            conversationId: "conv_1", turnId: "turn_1")))
        #expect(api.turns.all.count == 1)
        #expect(api.cancels.all.isEmpty)
    }

    @Test func suspendedForApprovalIsCancelledOnTheServer() async {
        let api = ScriptedTurnAPI(events: TurnScript.suspended(.approval))
        let outcome = await runner(api).run(request)
        guard case .suspended(.approval, let partial) = outcome else {
            Issue.record("expected an approval suspension, got \(outcome)")
            return
        }
        #expect(partial.conversationId == "conv_1")
        #expect(api.cancels.all == ["turn_1"])
    }

    @Test func suspendedForDeviceAction() async {
        let action = DeviceActionRequest(actionId: "a1", turnId: "turn_1", tool: "ios.alarm.create", risk: .low, expiresAt: Date())
        let api = ScriptedTurnAPI(events: [TurnScript.started, .deviceAction(DeviceActionEvent(action: action)),
                                           .turnSuspended(TurnSuspended(turnId: "turn_1", reason: .deviceAction))])
        let outcome = await runner(api).run(request)
        guard case .suspended(.deviceAction, _) = outcome else {
            Issue.record("expected a device-action suspension, got \(outcome)")
            return
        }
        #expect(api.cancels.all == ["turn_1"])
    }

    @Test func timeoutStopsTheTurn() async {
        let api = ScriptedTurnAPI(events: [TurnScript.started], hangs: true)
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await runner(api, timeout: .milliseconds(80)).run(request)
        #expect(outcome == .failed(.timeout))
        #expect(clock.now - start < .seconds(3))
        #expect(api.cancels.all == ["turn_1"])
    }

    @Test func offline() async {
        let api = ScriptedTurnAPI(error: ZoroError.transport("connection refused"))
        #expect(await runner(api).run(request) == .failed(.offline))
        let urlError = ScriptedTurnAPI(error: URLError(.notConnectedToInternet))
        #expect(await runner(urlError).run(request) == .failed(.offline))
    }

    @Test func serverErrorsAreTyped() async {
        let paused = ScriptedTurnAPI(events: [TurnScript.started, .error(TurnError(code: "kill_switch_active", message: "The kill switch is on."))])
        #expect(await runner(paused).run(request) == .failed(.paused))
        let failed = ScriptedTurnAPI(events: [.error(TurnError(code: "tool_timeout", message: "Finance took too long.", retryable: true))])
        #expect(await runner(failed).run(request) == .failed(.server(code: "tool_timeout", message: "Finance took too long.", retryable: true)))
        #expect(ZoroIntentTurnRunner.failure(for: ZoroError.notPaired) == .notPaired)
        #expect(ZoroIntentTurnRunner.failure(for: ZoroError.unauthorized) == .unauthorized)
        #expect(ZoroIntentTurnRunner.failure(for: ZoroError.http(status: 401, body: nil)) == .unauthorized)
        #expect(ZoroIntentTurnRunner.failure(for: ZoroError.http(status: 503, body: ErrorBody(code: "kill_switch_active", message: "On"))) == .paused)
        #expect(ZoroIntentTurnRunner.failure(for: CancellationError()) == .cancelled)
    }

    @Test func emptyOrTruncatedTurns() async {
        let empty = ScriptedTurnAPI(events: [TurnScript.started, TurnScript.completed()])
        #expect(await runner(empty).run(request) == .failed(.empty))
        let truncated = ScriptedTurnAPI(events: [TurnScript.started, .textDelta(TextDelta(text: "Half"))])
        guard case .failed(.server(code: "incomplete", _, true)) = await runner(truncated).run(request) else {
            Issue.record("expected an incomplete-turn failure")
            return
        }
        let blank = ScriptedTurnAPI(events: TurnScript.answer("ignored"))
        #expect(await runner(blank).run(IntentTurnRequest(text: "   ", language: .english)) == .failed(.empty))
        #expect(blank.turns.all.isEmpty)
    }

    @Test func cancellationIsHonoured() async {
        let api = ScriptedTurnAPI(events: [TurnScript.started], hangs: true)
        let r = runner(api, timeout: .seconds(30))
        let task = Task { await r.run(request) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == .failed(.cancelled))
        for _ in 0..<200 where api.cancels.all.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(api.cancels.all == ["turn_1"])
    }
}

@Suite("Siri reply plan")
struct IntentReplyPlanTests {
    @Test func shortAnswerIsSpokenWithSnippet() {
        let card = UICard(kind: "spending_summary", title: "Food", payload: ["total": "4250.50", "currency": "INR", "period": "October"])
        let reply = IntentReply(text: "You spent ₹4,250.50 on food last month.", cards: [card], language: "en", dataClasses: [.financial], conversationId: "c")
        let plan = IntentReplyPlan.make(for: .answer(reply), askText: "q", owner: .hindi)
        #expect(plan.dialog == reply.text)
        #expect(plan.continuation == nil)
        #expect(plan.language == .english)
        #expect(plan.snippet == IntentSnippet(text: reply.text, cardTitle: "Food", cardLines: ["Currency: INR", "Period: October"]))
    }

    @Test func cardSummaryPrefersSummaryField() {
        let card = UICard(kind: "price_comparison", payload: ["summary": "Store A is lowest at ₹812.00", "total": "812.00"])
        let summary = IntentReplyPlan.cardSummary(card)
        #expect(summary.title == "Price comparison")
        #expect(summary.lines == ["Store A is lowest at ₹812.00"])
    }

    @Test func longReplyReadsTheFirstSentenceAndOpensTheConversation() {
        let text = "You spent ₹12,430.75 in total. " + String(repeating: "Detail line about a category. ", count: 25)
        let reply = IntentReply(text: text, language: "en", conversationId: "conv_9")
        let plan = IntentReplyPlan.make(for: .answer(reply), askText: "q", owner: .english)
        #expect(plan.dialog == "You spent ₹12,430.75 in total. The full answer is long, so it's in the ZORO app.")
        #expect(plan.continuation == IntentContinuation(reason: .longReply, handoff: .conversation("conv_9")))
        #expect(plan.snippet!.text.count == IntentReplyPlan.maxSnippetCharacters)
    }

    @Test func longHindiReplyWithoutConversationAsksAgain() {
        let text = String(repeating: "यह एक लंबा वाक्य है जिसमें बहुत सारी जानकारी है", count: 10)
        let reply = IntentReply(text: text, language: "hi")
        let plan = IntentReplyPlan.make(for: .answer(reply), askText: "पिछले महीने खाने पर मैंने कितना खर्च किया?", owner: .english)
        #expect(plan.dialog == "पूरा जवाब लंबा है, इसलिए वह ZORO ऐप में है।")
        #expect(plan.continuation?.handoff == .ask("पिछले महीने खाने पर मैंने कितना खर्च किया?"))
    }

    @Test func secretRepliesStayInTheApp() {
        let reply = IntentReply(text: "Your Wi-Fi password is …", language: "en", dataClasses: [.personal, .secret], conversationId: "c")
        let plan = IntentReplyPlan.make(for: .answer(reply), askText: "q", owner: .english)
        #expect(plan.dialog == "This answer has private details, so it's shown only in the ZORO app.")
        #expect(plan.snippet == nil)
        #expect(plan.continuation == IntentContinuation(reason: .privateReply, handoff: .conversation("c")))
        #expect(!plan.dialog.contains("password"))
    }

    @Test func sensitiveClassesNeedUnlock() {
        #expect(IntentPrivacy.needsUnlock([.financial]))
        #expect(IntentPrivacy.needsUnlock([.health]))
        #expect(IntentPrivacy.needsUnlock([.personal]))
        #expect(!IntentPrivacy.needsUnlock([.public]))
        #expect(IntentPrivacy.isAppOnly([.secret]))
        #expect(!IntentPrivacy.isAppOnly([.financial, .health]))
    }

    @Test func suspensionsContinueByAskingAgain() {
        let partial = IntentReply(text: "", conversationId: "c")
        let approval = IntentReplyPlan.make(for: .suspended(.approval, partial: partial), askText: "Send Asha the photos", owner: .english)
        #expect(approval.dialog == "This needs your approval. Approvals happen only in the ZORO app, so it continues there.")
        #expect(approval.continuation == IntentContinuation(reason: .suspended(.approval), handoff: .ask("Send Asha the photos")))
        let device = IntentReplyPlan.make(for: .suspended(.deviceAction, partial: partial), askText: "x", owner: .hindi)
        #expect(device.dialog == "इसके लिए आपके डिवाइस पर एक कदम पूरा होना है, इसलिए यह ZORO ऐप में जारी रहेगा।")
    }

    @Test func failuresAreSpokenInTheOwnersLanguage() {
        #expect(IntentReplyPlan.make(for: .failed(.offline), askText: "", owner: .english).dialog
            == "Can't reach your ZORO server. Check that your Mac is awake and on Tailscale.")
        #expect(IntentReplyPlan.make(for: .failed(.offline), askText: "", owner: .hindi).dialog
            == "आपके ZORO सर्वर से जुड़ नहीं पा रहे। देखें कि आपका Mac चालू है और Tailscale पर है।")
        #expect(IntentReplyPlan.make(for: .failed(.timeout), askText: "", owner: .hinglish).continuation == nil)
    }

    @Test(arguments: ["₹1,234.50 is the total.", "Total: 3.5 kg. Next"])
    func firstSentenceKeepsDecimals(text: String) {
        let first = IntentReplyPlan.firstSentence(of: text, limit: 150)
        #expect(first == (text.hasPrefix("₹") ? "₹1,234.50 is the total." : "Total: 3.5 kg."))
    }

    @Test func firstSentenceTooLong() {
        #expect(IntentReplyPlan.firstSentence(of: String(repeating: "word ", count: 60) + ".", limit: 150) == nil)
        #expect(IntentReplyPlan.firstSentence(of: "दूध जोड़ दिया। और कुछ?", limit: 150) == "दूध जोड़ दिया।")
    }
}
