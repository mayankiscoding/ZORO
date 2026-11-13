import Foundation
import Testing
import ZoroCore
@testable import MemoryClient

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ v: Value) { value = v }
    func update<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
    var get: Value { update { $0 } }
}

/// Records every request and answers with scripted JSON bodies.
final class RecordingAPI: ZoroAPI, @unchecked Sendable {
    let requests = Box<[APIRequest]>([])
    let bodies: Box<[String]>
    init(_ bodies: [String] = []) { self.bodies = Box(bodies) }

    private func reply(_ request: APIRequest) throws -> Data {
        requests.update { $0.append(request) }
        guard let body = bodies.update({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw ZoroError.http(status: 500, body: nil) }
        return Data(body.utf8)
    }

    func send<Response: Decodable & Sendable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        try ZoroJSON.decoder().decode(Response.self, from: try reply(request))
    }
    func send(_ request: APIRequest) async throws { _ = try reply(request) }
    func sendRaw(_ request: APIRequest) async throws -> Data { try reply(request) }

    func pair(_ request: PairRequest) async throws -> PairResponse { throw ZoroError.busy }
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse { throw ZoroError.busy }
    func token(_ request: TokenRequest) async throws -> TokenResponse { throw ZoroError.busy }
    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func resumeTurn(id turnId: String, _ request: ResumeRequest) -> AsyncThrowingStream<TurnEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func cancelTurn(id turnId: String) async throws {}
    func conversations(cursor: String?, limit: Int?) async throws -> Page<ConversationSummary> { throw ZoroError.busy }
    func messages(conversationId: String, cursor: String?, limit: Int?) async throws -> Page<Message> { throw ZoroError.busy }
    func deleteConversation(id: String) async throws {}
    func pendingApprovals() async throws -> [ApprovalRequest] { [] }
    func securityState() async throws -> SecurityState { throw ZoroError.busy }
    func setPrivacyMode(_ update: PrivacyModeUpdate) async throws {}
    func setKillSwitch(_ update: KillSwitchUpdate) async throws {}
    func setPermission(key: String, _ update: PermissionUpdate) async throws {}
    func revokeDevice(id: String, _ revoke: DeviceRevoke) async throws {}
    func auditLog(cursor: String?, limit: Int?) async throws -> Page<AuditRecord> { throw ZoroError.busy }
    func capabilities() async throws -> [Capability] { [] }
    func costSummary(groupBy: CostGroupBy) async throws -> CostSummary { throw ZoroError.busy }
    func modelRoutes() async throws -> [ModelRouteInfo] { [] }
}

/// Records proofs it is asked to sign (no real keys).
actor FakeSigner: DeviceIdentityProviding {
    private(set) var signed: [(String, String, ProofKey)] = []
    func deviceId() async -> String? { "dev_1" }
    func pairRequest(pairingCode: String, deviceName: String, platform: DevicePlatform, capabilities: [String], appVersion: String?) async throws -> PairRequest { throw ZoroError.busy }
    func completePairing(_ response: PairResponse) async throws {}
    func signChallenge(nonce: String) async throws -> TokenRequest { throw ZoroError.busy }
    func signApproval(_ request: ApprovalRequest, approved: Bool, at date: Date) async throws -> ApprovalDecision { throw ZoroError.busy }
    func signProof(action: String, subject: String, key: ProofKey, at date: Date) async throws -> SignedProof {
        signed.append((action, subject, key))
        return SignedProof(deviceId: "dev_1", signedAt: date, signatureB64: "c2ln", key: key)
    }
    func unpair() async throws {}
}

private let record = #"{"id":"mem_1","category":"profile","text":"Prefers aisle seats","source":"user","confidence":0.9,"sensitivity":"personal","created_at":"2026-11-12T09:30:15Z"}"#
private let signedAt = Date(timeIntervalSince1970: 1_794_475_815)

private func body(_ request: APIRequest) throws -> [String: Any] {
    let data = try #require(request.body)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Memory client")
struct MemoryClientTests {
    @Test func listBuildsQuery() async throws {
        let api = RecordingAPI([#"{"items":[\#(record)],"next_cursor":"n2"}"#])
        let page = try await MemoryClient(api: api).list(category: .profile, status: .active, cursor: "c1", limit: 10)
        #expect(page.items.first?.text == "Prefers aisle seats" && page.nextCursor == "n2")
        let r = try #require(api.requests.get.first)
        #expect(r.method == .get && r.path == "/v1/memory" && r.requiresAuth)
        #expect(r.query.map(\.name) == ["category", "status", "cursor", "limit"])
        #expect(r.query.map(\.value) == ["profile", "active", "c1", "10"])
    }

    @Test func searchClampsAndSkipsEmptyQueries() async throws {
        let api = RecordingAPI(["[\(record)]"])
        let client = MemoryClient(api: api)
        #expect(try await client.search("   ").isEmpty)
        #expect(api.requests.get.isEmpty)
        let hits = try await client.search(" aisle ", category: .profile, limit: 1000)
        #expect(hits.count == 1)
        let r = try #require(api.requests.get.first)
        #expect(r.path == "/v1/memory/search")
        #expect(r.query == [URLQueryItem(name: "q", value: "aisle"), URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "category", value: "profile")])
    }

    @Test func createPatchDelete() async throws {
        let api = RecordingAPI([record, record, "{}"])
        let client = MemoryClient(api: api)
        _ = try await client.create(MemoryCreate(category: .profile, text: "Prefers aisle seats"))
        _ = try await client.patch(id: "mem/1", MemoryPatch(status: .archived))
        try await client.delete(id: "mem_1")
        let rs = api.requests.get
        #expect(rs.map(\.method) == [.post, .patch, .delete])
        #expect(rs.map(\.path) == ["/v1/memory", "/v1/memory/mem%2F1", "/v1/memory/mem_1"])
        #expect(try body(rs[0])["sensitivity"] as? String == "personal")
        #expect(try body(rs[1]) as NSDictionary == ["status": "archived"] as NSDictionary)
    }

    @Test func rejectsSecretsEmptyTextAndEmptyPatches() async {
        let api = RecordingAPI()
        let client = MemoryClient(api: api)
        await #expect(throws: ZoroError.self) { try await client.create(MemoryCreate(category: .profile, text: "pw", sensitivity: .secret)) }
        await #expect(throws: ZoroError.self) { try await client.create(MemoryCreate(category: .profile, text: "  ")) }
        await #expect(throws: ZoroError.self) { try await client.patch(id: "m", MemoryPatch()) }
        await #expect(throws: ZoroError.self) {
            try await client.updateSettings(MemorySettings(categories: [MemoryCategorySetting(category: .episodic, enabled: true, retentionDays: 0)], conversationRetentionDays: 30))
        }
        #expect(api.requests.get.isEmpty)
    }

    @Test func settingsRoundTrip() async throws {
        let json = #"{"categories":[{"category":"financial","enabled":false,"retention_days":null}],"conversation_retention_days":30}"#
        let api = RecordingAPI([json, json])
        let client = MemoryClient(api: api)
        let settings = try await client.settings()
        #expect(settings.categories.first?.enabled == false && settings.conversationRetentionDays == 30)
        _ = try await client.updateSettings(settings)
        let put = try #require(api.requests.get.last)
        #expect(put.method == .put && put.path == "/v1/memory/settings")
        #expect(try body(put)["conversation_retention_days"] as? Int == 30)
    }

    @Test func exportSignsProofWithApprovalKey() async throws {
        let api = RecordingAPI([#"{"records":[]}"#, #"{"records":[]}"#])
        let signer = FakeSigner()
        let client = MemoryClient(api: api)
        let data = try await client.export(signer: signer, at: signedAt)
        #expect(String(decoding: data, as: UTF8.self) == #"{"records":[]}"#)
        _ = try await client.export(category: .fitness, signer: signer, at: signedAt)
        let signed = await signer.signed
        #expect(signed.map(\.0) == ["export_memory", "export_memory"])
        #expect(signed.map(\.1) == ["all", "fitness"])
        #expect(signed.allSatisfy { $0.2 == .approval })
        let firstRequest = try #require(api.requests.get.first)
        let first = try body(firstRequest)
        #expect(first["category"] == nil)
        let proof = try #require(first["proof"] as? [String: Any])
        #expect(proof["signed_at"] as? String == "2026-11-12T09:30:15Z" && proof["key"] as? String == "approval")
        #expect(try body(api.requests.get[1])["category"] as? String == "fitness")
    }

    @Test func deleteCategorySignsAndPosts() async throws {
        let api = RecordingAPI(["{}"])
        let signer = FakeSigner()
        try await MemoryClient(api: api).deleteCategory(.financial, signer: signer, at: signedAt)
        #expect(await signer.signed.first?.0 == "delete_memory_category")
        #expect(await signer.signed.first?.1 == "financial")
        let r = try #require(api.requests.get.first)
        #expect(r.method == .post && r.path == "/v1/memory/categories/financial/delete")
        #expect(try body(r)["proof"] != nil)
    }

    @Test func serverFailureSurfaces() async {
        let client = MemoryClient(api: RecordingAPI([]))
        await #expect(throws: ZoroError.http(status: 500, body: nil)) { try await client.settings() }
    }
}
