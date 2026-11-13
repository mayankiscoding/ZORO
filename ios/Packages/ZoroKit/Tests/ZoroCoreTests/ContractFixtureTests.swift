import Foundation
import Testing
@testable import ZoroCore

/// Fixtures are generated from the real Pydantic models (Scripts/generate_fixtures.py).
enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name), options: [.fragmentsAllowed])
    }

    static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }
}

/// Decodes, re-encodes and decodes again: the Swift model must reproduce itself exactly.
private func roundTrip<T: Codable & Equatable>(_ type: T.Type) -> @Sendable (Data) throws -> Void {
    { data in
        let decoded = try ZoroJSON.decoder().decode(T.self, from: data)
        let again = try ZoroJSON.decoder().decode(T.self, from: ZoroJSON.encoder().encode(decoded))
        #expect(decoded == again, "\(T.self) did not survive a round trip")
    }
}

/// Swift mirror for every Python ZModel. A new Python model without an entry here fails the test.
private let mirrors: [String: @Sendable (Data) throws -> Void] = [
    "AgentFinished": roundTrip(AgentFinished.self), "AgentStarted": roundTrip(AgentStarted.self),
    "ApprovalDecision": roundTrip(ApprovalDecision.self), "ApprovalRequest": roundTrip(ApprovalRequest.self),
    "ApprovalRequired": roundTrip(ApprovalRequired.self), "AuditRecord": roundTrip(AuditRecord.self),
    "Capability": roundTrip(Capability.self), "CardEvent": roundTrip(CardEvent.self),
    "ChallengeRequest": roundTrip(ChallengeRequest.self), "ChallengeResponse": roundTrip(ChallengeResponse.self),
    "ClientContext": roundTrip(ClientContext.self), "ConversationSummary": roundTrip(ConversationSummary.self),
    "CostRow": roundTrip(CostRow.self), "CostSummary": roundTrip(CostSummary.self),
    "DeviceActionEvent": roundTrip(DeviceActionEvent.self), "DeviceActionRequest": roundTrip(DeviceActionRequest.self),
    "DeviceActionResult": roundTrip(DeviceActionResult.self), "DeviceInfo": roundTrip(DeviceInfo.self),
    "DeviceRevoke": roundTrip(DeviceRevoke.self), "ErrorBody": roundTrip(ErrorBody.self),
    "KillSwitchUpdate": roundTrip(KillSwitchUpdate.self), "LabelValue": roundTrip(LabelValue.self),
    "LiveSessionGrant": roundTrip(LiveSessionGrant.self), "MemoryCategorySetting": roundTrip(MemoryCategorySetting.self),
    "MemoryCreate": roundTrip(MemoryCreate.self), "MemoryDeleteCategoryRequest": roundTrip(MemoryDeleteCategoryRequest.self),
    "MemoryExportRequest": roundTrip(MemoryExportRequest.self), "MemoryPatch": roundTrip(MemoryPatch.self),
    "MemoryRecord": roundTrip(MemoryRecord.self), "MemorySettings": roundTrip(MemorySettings.self),
    "Message": roundTrip(Message.self), "ModelRouteInfo": roundTrip(ModelRouteInfo.self), "Money": roundTrip(Money.self),
    "Page[ConversationSummary]": roundTrip(Page<ConversationSummary>.self),
    "Page[MemoryRecord]": roundTrip(Page<MemoryRecord>.self), "PairRequest": roundTrip(PairRequest.self),
    "PairResponse": roundTrip(PairResponse.self), "PermissionGrant": roundTrip(PermissionGrant.self),
    "PermissionUpdate": roundTrip(PermissionUpdate.self), "PrivacyModeUpdate": roundTrip(PrivacyModeUpdate.self),
    "ResumeRequest": roundTrip(ResumeRequest.self), "RouteDecided": roundTrip(RouteDecided.self),
    "SecurityState": roundTrip(SecurityState.self), "SignedProof": roundTrip(SignedProof.self),
    "TTSRequest": roundTrip(TTSRequest.self), "TextDelta": roundTrip(TextDelta.self),
    "TokenRequest": roundTrip(TokenRequest.self), "TokenResponse": roundTrip(TokenResponse.self),
    "ToolFinished": roundTrip(ToolFinished.self), "ToolStarted": roundTrip(ToolStarted.self),
    "TurnCompleted": roundTrip(TurnCompleted.self), "TurnError": roundTrip(TurnError.self),
    "TurnInput": roundTrip(TurnInput.self), "TurnRequest": roundTrip(TurnRequest.self),
    "TurnStarted": roundTrip(TurnStarted.self), "TurnSuspended": roundTrip(TurnSuspended.self),
    "UICard": roundTrip(UICard.self), "UsageSummary": roundTrip(UsageSummary.self), "VoiceConfig": roundTrip(VoiceConfig.self),
    "VoiceEngineStatus": roundTrip(VoiceEngineStatus.self), "VoiceOption": roundTrip(VoiceOption.self),
    "VoiceSettings": roundTrip(VoiceSettings.self),
]

@Suite("Contract fixtures")
struct ContractFixtureTests {
    @Test func everyPythonModelHasASwiftMirror() throws {
        let models = try #require(Fixtures.json("models") as? [String: Any])
        #expect(Set(models.keys) == Set(mirrors.keys))
    }

    @Test func everyModelDecodesFullAndMinimalFixtures() throws {
        let models = try #require(Fixtures.json("models") as? [String: [String: Any]])
        for (name, variants) in models.sorted(by: { $0.key < $1.key }) {
            let check = try #require(mirrors[name], "missing Swift mirror for \(name)")
            for (variant, payload) in variants {
                let samples: [Any] = variant == "extra" ? (payload as? [Any] ?? []) : [payload]
                for sample in samples {
                    do {
                        try check(Fixtures.encode(sample))
                    } catch {
                        Issue.record("\(name).\(variant) failed to decode: \(error)")
                    }
                }
            }
        }
    }

    @Test func enumsMatchPythonExactly() throws {
        let python = try #require(Fixtures.json("enums") as? [String: [String]])
        #expect(Set(python.keys) == Set(ContractEnums.rawValues.keys))
        for (name, values) in python {
            #expect(ContractEnums.rawValues[name] == values, "\(name) drifted")
        }
    }

    @Test func moneyIsExactDecimal() throws {
        let models = try #require(Fixtures.json("models") as? [String: [String: Any]])
        let full = try Fixtures.encode(try #require(models["Money"]?["full"]))
        let money = try ZoroJSON.decoder().decode(Money.self, from: full)
        #expect(money.amount == Decimal(string: "1234.50"))
        let minimal = try Fixtures.encode(try #require(models["Money"]?["minimal"]))
        #expect(try ZoroJSON.decoder().decode(Money.self, from: minimal).currency == "INR")
        let tenPaise = try ZoroJSON.decoder().decode(Money.self, from: Data(#"{"amount":"0.10"}"#.utf8))
        #expect(tenPaise.amount * 10 == 1)
        let encoded = String(decoding: try ZoroJSON.encoder().encode(Money(amount: Decimal(string: "19.99")!)), as: UTF8.self)
        #expect(encoded == #"{"amount":"19.99","currency":"INR"}"#)
        // A float on the wire is rejected: money is never a binary floating-point number.
        #expect(throws: DecodingError.self) {
            try ZoroJSON.decoder().decode(Money.self, from: Data(#"{"amount":12.5}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try ZoroJSON.decoder().decode(Money.self, from: Data(#"{"amount":"12,50"}"#.utf8))
        }
    }

    @Test func payloadKeysAreNotRewritten() throws {
        let models = try #require(Fixtures.json("models") as? [String: [String: Any]])
        let card = try ZoroJSON.decoder().decode(UICard.self, from: Fixtures.encode(try #require(models["UICard"]?["full"])))
        #expect(card.payload["selected_product_ref"] == .string("prod_1"))
        #expect(card.payload["nested_key"]?["inner_key"]?[1] == .string("a"))
        #expect(card.payload["count"]?.intValue == 2)
    }

    @Test func defaultsApplyWhenKeysAreMissing() throws {
        let record = try ZoroJSON.decoder().decode(MemoryRecord.self, from: Data(#"""
            {"id":"m1","category":"profile","text":"t","source":"user","confidence":0.5,"sensitivity":"personal","created_at":"2026-11-12T09:30:15Z"}
            """#.utf8))
        #expect(record.status == .active && record.userEditable)
        let settings = try ZoroJSON.decoder().decode(VoiceSettings.self, from: Data("{}".utf8))
        #expect(settings == VoiceSettings())
        let ctx = try ZoroJSON.decoder().decode(ClientContext.self, from: Data(#"{"platform":"ios"}"#.utf8))
        #expect(ctx.locale == "en-IN" && ctx.timezone == "Asia/Kolkata" && ctx.appState.isEmpty)
    }

    @Test func unknownEnumValueFailsLoudly() {
        #expect(throws: DecodingError.self) {
            try ZoroJSON.decoder().decode(DeviceInfo.self, from: Data(#"{"device_id":"d","name":"n","platform":"android"}"#.utf8))
        }
    }

    @Test func nilOptionalsAreOmittedWhenEncoding() throws {
        let patch = MemoryPatch(status: .archived)
        let json = String(decoding: try ZoroJSON.encoder().encode(patch), as: UTF8.self)
        #expect(json == #"{"status":"archived"}"#)
    }
}
