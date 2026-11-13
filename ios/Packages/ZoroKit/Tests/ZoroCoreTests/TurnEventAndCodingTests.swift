import Foundation
import Testing
@testable import ZoroCore

@Suite("Turn events")
struct TurnEventTests {
    @Test func everyVariantDecodesFromPythonFixtures() throws {
        let events = try #require(Fixtures.json("turn_events") as? [[String: Any]])
        var seen: Set<String> = []
        for raw in events {
            let event = try ZoroJSON.decoder().decode(TurnEvent.self, from: Fixtures.encode(raw))
            #expect(event.type == raw["type"] as? String)
            seen.insert(event.type)
            let again = try ZoroJSON.decoder().decode(TurnEvent.self, from: ZoroJSON.encoder().encode(event))
            #expect(again == event)
        }
        #expect(seen.isSuperset(of: TurnEvent.knownTypes))
        #expect(seen.count == TurnEvent.knownTypes.count + 1)
    }

    @Test func specificVariantsCarryTheirPayload() throws {
        let events = try #require(Fixtures.json("turn_events") as? [[String: Any]])
        let decoded = try events.map { try ZoroJSON.decoder().decode(TurnEvent.self, from: Fixtures.encode($0)) }
        var matched = 0
        for event in decoded {
            switch event {
            case .turnStarted(let e): #expect(e.privacyMode == .cloudIntelligence); matched += 1
            case .route(let e): #expect(e.engine == .cloudModel && e.agents == [.security]); matched += 1
            case .agentStarted(let e): #expect(e.agent == .security); matched += 1
            case .agentFinished(let e): #expect(e.durationMs == 42); matched += 1
            case .toolStarted(let e): #expect(e.risk == .critical); matched += 1
            case .toolFinished(let e): #expect(e.summary == "summary-value"); matched += 1
            case .textDelta(let e): #expect(e.text == "text-value"); matched += 1
            case .card(let e): #expect(e.card.payload["selected_product_ref"] == "prod_1"); matched += 1
            case .approvalRequired(let e): #expect(e.approval.level == .biometric); matched += 1
            case .deviceAction(let e): #expect(e.action.args["count"] == 2); matched += 1
            case .turnSuspended(let e): #expect(e.reason == .deviceAction); matched += 1
            case .turnCompleted(let e): #expect(e.usage.costUsd == Decimal(string: "1234.50")); matched += 1
            case .error(let e): #expect(e.code == "code-value"); matched += 1
            case .unknown(let type, let payload):
                #expect(type == "future_event_kind")
                #expect(payload["some_field"] == 1)
                matched += 1
            }
        }
        #expect(matched == 14)
    }

    @Test func sseEventNameFillsMissingType() throws {
        let event = try TurnEvent.decode(eventName: "text_delta", data: Data(#"{"text":"नमस्ते"}"#.utf8))
        #expect(event == .textDelta(TextDelta(text: "नमस्ते")))
        #expect(throws: ZoroError.self) { try TurnEvent.decode(eventName: nil, data: Data(#"{"text":"x"}"#.utf8)) }
        #expect(throws: (any Error).self) { try TurnEvent.decode(eventName: "text_delta", data: Data("[1]".utf8)) }
    }

    @Test func terminalEvents() {
        #expect(TurnEvent.turnSuspended(TurnSuspended(turnId: "t", reason: .approval)).isTerminal)
        #expect(!TurnEvent.textDelta(TextDelta(text: "a")).isTerminal)
    }
}

@Suite("Coding")
struct CodingTests {
    @Test func parsesDatesWithAndWithoutFractions() throws {
        let base = try #require(ZoroJSON.parseDate("2026-11-12T09:30:15Z"))
        #expect(base.timeIntervalSince1970 == 1_794_475_815)
        let micro = try #require(ZoroJSON.parseDate("2026-11-12T09:30:15.123456Z"))
        #expect(abs(micro.timeIntervalSince(base) - 0.123456) < 0.000_001)
        let ist = try #require(ZoroJSON.parseDate("2026-11-12T15:00:15+05:30"))
        #expect(ist == base)
        let compactOffset = try #require(ZoroJSON.parseDate("2026-11-12T04:30:15-0500"))
        #expect(compactOffset == base)
        #expect(ZoroJSON.parseDate("2026-11-12T09:30:15") == nil)  // naive datetimes are rejected
        #expect(ZoroJSON.parseDate("2026-13-12T09:30:15Z") == nil)
        #expect(ZoroJSON.parseDate("not a date") == nil)
    }

    @Test func formatsDates() throws {
        let base = Date(timeIntervalSince1970: 1_794_475_815)
        #expect(ZoroJSON.formatDate(base) == "2026-11-12T09:30:15Z")
        #expect(ZoroJSON.formatDate(base.addingTimeInterval(0.25)) == "2026-11-12T09:30:15.250Z")
        #expect(ZoroJSON.isoSeconds(base.addingTimeInterval(0.9)) == "2026-11-12T09:30:15Z")
    }

    @Test func jsonValueKeepsTypes() throws {
        let value = try ZoroJSON.decoder().decode(JSONValue.self, from: Data(#"{"a":true,"b":1,"c":"1","d":null,"e":[false]}"#.utf8))
        #expect(value["a"] == .bool(true))
        #expect(value["b"] == .number(1))
        #expect(value["c"] == .string("1"))
        #expect(value["d"] == .null)
        #expect(value["e"]?[0] == .bool(false))
    }

    @Test func redactsSensitiveText() {
        let out = ZoroLog.redact("mail a@b.com pay me@okhdfc call +91 98765 43210 pan ABCDE1234F Bearer abc.def")
        #expect(!out.contains("a@b.com") && !out.contains("98765") && !out.contains("ABCDE1234F") && !out.contains("abc.def"))
        #expect(!out.contains("me@okhdfc"))
    }

    @Test func unavailableServicesFailWithTypedErrors() async {
        let services = ZoroServices.unavailable
        await #expect(throws: ZoroError.notPaired) { try await services.api.capabilities() }
        await #expect(throws: ZoroError.self) { try await services.photos.search(PhotoQuery(text: "beach")) }
        let request = DeviceActionRequest(actionId: "a1", tool: "ios.alarm.create", risk: .medium, expiresAt: Date())
        let result = await services.deviceActions.execute(request)
        #expect(!result.ok && result.errorCode == "unsupported")
    }

    @Test func zoroErrorRetryability() {
        #expect(ZoroError.http(status: 503, body: nil).isRetryable)
        #expect(!ZoroError.http(status: 400, body: nil).isRetryable)
        #expect(ZoroError.wrap(URLError(.timedOut)) == .timeout)
        #expect(ZoroError.wrap(CancellationError()) == .cancelled)
    }
}
