import Foundation
import NativeActionBroker
import SystemFeatures
import Testing
import ZoroAppUI
import ZoroCore
import ZoroDesign
@testable import ZoroComposition

@Suite("Approvals outside a turn")
@MainActor
struct ApprovalInboxTests {
    let now = Date()

    func decisionResponse(_ id: String, approved: Bool) -> Data {
        Data(#"{"approval_id":"\#(id)","owner":"automation","approved":\#(approved),"status":"running","events":[]}"#.utf8)
    }

    @Test("A pushed approval opens the sheet and the signed answer goes to the decision route")
    func pushedApprovalIsAnswered() async {
        let api = FakeAPI()
        api.responses["/v1/approvals/apr_1/decision"] = decisionResponse("apr_1", approved: true)
        let approvals = FakeApprovals()
        let inbox = ApprovalInbox(api: api, approvals: approvals)

        await inbox.receive(approvalRequest("apr_1", now: now))

        #expect(approvals.asked == ["apr_1"])
        #expect(api.requests.map(\.path) == ["/v1/approvals/apr_1/decision"])
        #expect(inbox.pending.isEmpty)
        #expect(inbox.lastOutcome == "Approved. Sending now.")
    }

    @Test("Declining is still signed and sent; nothing is left waiting")
    func declineIsSent() async {
        let api = FakeAPI()
        api.responses["/v1/approvals/apr_2/decision"] = decisionResponse("apr_2", approved: false)
        let approvals = FakeApprovals()
        approvals.approve = false
        let inbox = ApprovalInbox(api: api, approvals: approvals)
        await inbox.receive(approvalRequest("apr_2", now: now))
        #expect(inbox.lastOutcome == "Declined. Nothing was sent.")
        #expect(inbox.pending.isEmpty)
    }

    @Test("Dismissing the sheet keeps the approval waiting and sends nothing")
    func dismissKeepsItWaiting() async {
        let api = FakeAPI()
        let approvals = FakeApprovals()
        approvals.error = .userCancelled
        let inbox = ApprovalInbox(api: api, approvals: approvals)
        await inbox.receive(approvalRequest("apr_3", now: now))
        #expect(api.requests.isEmpty)
        #expect(inbox.pending.map(\.approvalId) == ["apr_3"])
    }

    @Test("An expired push is ignored; an answer already given elsewhere is cleared")
    func expiredAndConflict() async {
        let api = FakeAPI()
        api.errors["/v1/approvals/apr_5/decision"] = .http(status: 409, body: nil)
        let inbox = ApprovalInbox(api: api, approvals: FakeApprovals())
        await inbox.receive(approvalRequest("apr_4", expiresIn: -1, now: now))
        #expect(inbox.pending.isEmpty)
        await inbox.receive(approvalRequest("apr_5", now: now))
        #expect(inbox.pending.isEmpty)
        #expect(inbox.lastOutcome == "This was already answered on another device.")
    }

    @Test("A failed send keeps it waiting with a sentence that says what to do")
    func networkFailureKeepsItWaiting() async {
        let api = FakeAPI()
        api.errors["/v1/approvals/apr_6/decision"] = .transport("offline")
        let inbox = ApprovalInbox(api: api, approvals: FakeApprovals())
        await inbox.receive(approvalRequest("apr_6", now: now))
        #expect(inbox.pending.map(\.approvalId) == ["apr_6"])
        #expect(inbox.lastOutcome == "Your answer didn't reach the server. Check the connection and answer again.")
    }

    @Test("Refresh lists waiting approvals soonest first and drops expired ones")
    func refreshSortsAndFilters() async {
        let api = FakeAPI()
        api.pending = [approvalRequest("late", expiresIn: 300, now: now), approvalRequest("gone", expiresIn: -5, now: now),
                       approvalRequest("soon", expiresIn: 30, now: now)]
        let inbox = ApprovalInbox(api: api, approvals: FakeApprovals())
        await inbox.refresh()
        #expect(inbox.phase == .loaded)
        #expect(inbox.pending.map(\.approvalId) == ["soon", "late"])
    }

    @Test("Refresh says disconnected when not paired or unreachable")
    func refreshDisconnected() async {
        let api = FakeAPI()
        api.pendingError = .notPaired
        let inbox = ApprovalInbox(api: api, approvals: FakeApprovals())
        await inbox.refresh()
        guard case .disconnected(let message) = inbox.phase else {
            Issue.record("expected disconnected, got \(inbox.phase)")
            return
        }
        #expect(message.contains("Pair it in Settings"))
        api.pendingError = .transport("timed out")
        await inbox.refresh()
        #expect(inbox.phase == .disconnected("Can't reach your ZORO server. Check that your Mac is awake and on Tailscale."))
    }
}

@Suite("Registrations")
@MainActor
struct RegistrationTests {
    @Test("All fifteen sections and every dedicated card kind are registered")
    func everythingRegistered() throws {
        let services = ZoroServices.unavailable
        let shell = ZoroAppShell.make(
            services: services, clientContext: ClientContext(platform: .macos), pairing: NoPairing(), isPaired: false)
        let system = SystemFeaturesContainer(services: services, conversations: shell.home.conversation)
        let inbox = ApprovalInbox(api: FakeAPI(), approvals: FakeApprovals())
        Registrations.registerSections(in: shell.sections, shell: shell, system: system, inbox: inbox)
        Registrations.registerCards(in: shell.cards)

        #expect(shell.sections.registeredSections == Set(AppSection.allCases))
        #expect(AppSection.allCases.count == 15)
        for kind in Registrations.cardKinds {
            #expect(shell.cards.hasRenderer(for: kind), "no renderer for \(kind)")
        }
        #expect(!shell.cards.hasRenderer(for: "sources"))  // falls back to the generic card
    }
}

struct NoPairing: ServerPairing {
    func createKeys() async throws {}
    func pair(serverURL: URL, code: String) async throws -> PairResponse { throw ZoroError.notPaired }
}

@Suite("Device actions")
struct DeviceActionTests {
    struct FixedExecutor: DeviceActionExecuting {
        let tools: [String]
        let label: String
        var supportedTools: [String] { tools }
        func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
            .failure(request, code: .failed, message: label)
        }
    }

    func request(_ tool: String) -> DeviceActionRequest {
        DeviceActionRequest(actionId: "a1", tool: tool, args: [:], risk: .low, expiresAt: Date().addingTimeInterval(60))
    }

    @Test("Each tool goes to the part that lists it; unknown tools are unsupported")
    func routesByTool() async {
        let composite = CompositeDeviceActionExecutor([
            FixedExecutor(tools: ["device.music.control"], label: "broker"),
            FixedExecutor(tools: ["device.photos.search"], label: "photos"),
        ])
        #expect(await composite.supportedTools == ["device.music.control", "device.photos.search"])
        #expect(await composite.execute(request("device.photos.search")).errorMessage == "photos")
        #expect(await composite.execute(request("device.music.control")).errorMessage == "broker")
        let unknown = await composite.execute(request("ios.home.run_scene"))
        #expect(unknown.errorCode == "unsupported")
    }

    @Test("Quick actions use real device-contract tool names for the platform")
    func quickActionsUseContractNames() {
        let contract = Set(DeviceToolName.allCases.map(\.rawValue))
        let phone = DeviceQuickActions.specs(for: .ios)
        let mac = DeviceQuickActions.specs(for: .macos)
        #expect(phone.allSatisfy { contract.contains($0.tool) })
        #expect(mac.allSatisfy { contract.contains($0.tool) })
        #expect(phone.contains { $0.tool == "ios.timer.start" && $0.args["seconds"] == .number(600) })
        #expect(!mac.contains { $0.tool.hasPrefix("ios.") })
        for spec in phone + mac {
            let tool = DeviceToolName(rawValue: spec.tool)!
            #expect(tool.platforms.contains(spec.tool.hasPrefix("ios.") ? .ios : .macos))
        }
    }
}

@Suite("Design adapters")
struct DesignAdapterTests {
    @Test("Privacy modes and approval levels map one to one")
    func enums() {
        #expect(DesignAdapters.privacyMode(.strictPrivate) == .strictPrivate)
        #expect(DesignAdapters.privacyMode(.cloudIntelligence) == .cloudIntelligence)
        #expect(DesignAdapters.approvalLevel(.biometric) == .biometric)
        #expect(DesignAdapters.approvalLevel(.confirm) == .confirm)
    }

    @Test("An approval keeps the server's summary, details and expiry; a tainted one leads with the warning")
    func approvalSummary() {
        let now = Date()
        let summary = DesignAdapters.approvalSummary(approvalRequest("a", expiresIn: 105, tainted: true, now: now))
        #expect(summary.action == "Turn off the lights.")
        #expect(summary.details.first?.value == "This came from a web page ZORO read. Check the details.")
        #expect(summary.details.last == ApprovalDetail(label: "Routine", value: "Evening"))
        #expect(summary.amount == nil)
        #expect(summary.expiryText(now: now) == "Expires in 1:45")
        let hindi = DesignAdapters.approvalSummary(approvalRequest("b", tainted: true, now: now), language: .hindi)
        #expect(hindi.details.first?.value == "यह ZORO के पढ़े किसी वेब पेज से आया है। जानकारी जाँच लें।")
    }

    @Test("Agent activity states map to the shared status words, in English and Hindi")
    func agentActivity() {
        let running = DesignAdapters.agentActivity(ConversationAgentActivity(agent: .shopping, task: "Comparing 3 stores"))
        #expect(running.status == .working)
        #expect(running.detail == "Comparing 3 stores")
        let waiting = DesignAdapters.agentActivity(ConversationAgentActivity(agent: .finance, task: ""), needsApproval: true)
        #expect(waiting.status == .needsYou)
        #expect(waiting.detail == nil)
        let failed = DesignAdapters.agentActivity(ConversationAgentActivity(agent: .finance, task: "x", state: .finished(ok: false, durationMs: 10)))
        #expect(failed.status == .failed)
        #expect(Copy.agentStatus(.needsYou, .hindi) == "आपकी मंज़ूरी चाहिए")
        #expect(Copy.privacyTitle(.strictPrivate, .hindi) == "प्राइवेट मोड")
        #expect(CopyLanguage(languageHint: "hi") == .hindi)
        #expect(CopyLanguage(languageHint: "hinglish") == .english)
    }
}

@Suite("Home context")
struct HomeContextTests {
    @Test("The basket suggestion appears only when the server has a basket with items")
    func basketCount() async throws {
        let api = FakeAPI()
        api.responses["/v1/shopping/baskets"] = try Fixture.data("basket_view_out")
        api.pending = [approvalRequest("x")]
        let context = await ShoppingHomeContext(api: api).suggestionContext()
        #expect(context.basketItemCount != nil)
        #expect(context.pendingApprovalCount == 1)

        api.responses["/v1/shopping/baskets"] = try Fixture.data("basket_view_empty")
        let empty = await ShoppingHomeContext(api: api).suggestionContext()
        #expect(empty.basketItemCount == nil)

        let offline = await ShoppingHomeContext(api: FakeAPI()).suggestionContext()
        #expect(offline == SuggestionContext(basketItemCount: nil, pendingApprovalCount: 0))
    }
}
