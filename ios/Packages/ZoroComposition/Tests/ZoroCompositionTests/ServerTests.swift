import AgentClient
import CommerceSupport
import Foundation
import Testing
import ZoroCore
@testable import ZoroComposition

@Suite("Server contract")
struct ServerTests {
    @Test("ApprovalDecisionResult decodes the backend's automation answer")
    func decodesAutomationResult() throws {
        let result = try ZoroJSON.decoder().decode(ApprovalDecisionResult.self, from: Fixture.data("approval_decision_result_automation"))
        #expect(result.approvalId == "apr_1")
        #expect(result.owner == "automation")
        #expect(result.approved)
        #expect(result.status == "running")
        #expect(result.runId == "run_7")
        #expect(result.turnId == nil)
        #expect(result.events.isEmpty)
        #expect(result.result?["queued"] == .bool(true))
    }

    @Test("ApprovalDecisionResult decodes a resumed turn with its events")
    func decodesTurnResult() throws {
        let result = try ZoroJSON.decoder().decode(ApprovalDecisionResult.self, from: Fixture.data("approval_decision_result_turn"))
        #expect(result.owner == "turn")
        #expect(!result.approved)
        #expect(result.turnId == "turn_9")
        #expect(result.events.count == 1)
        #expect(result.events.first?["type"] == .string("turn_completed"))
    }

    @Test("A pushed approval_required frame decodes into ZoroCore's event")
    func decodesChannelFrame() throws {
        let frame = try ZoroJSON.decoder().decode(ApprovalRequired.self, from: Fixture.data("approval_required_frame"))
        #expect(frame.approval.approvalId == "apr_1")
        #expect(frame.approval.tainted)
        #expect(frame.approval.level == .confirm)
    }

    @Test("The decision goes to POST /v1/approvals/{id}/decision with the signed body")
    func decisionRequest() throws {
        let decision = ApprovalDecision(
            approvalId: "apr/1", approved: true, actionDigest: "abc", deviceId: "dev", signedAt: Date(timeIntervalSince1970: 0),
            signatureB64: "c2ln")
        let request = try APIRequest.approvalDecision(decision)
        #expect(request.method == .post)
        #expect(request.path == "/v1/approvals/apr%2F1/decision")
        let body = try #require(request.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["approval_id"] as? String == "apr/1")
        #expect(json["signature_b64"] as? String == "c2ln")
        #expect(request.contentType == nil)
    }

    @Test("Uploads keep the multipart content type, the bearer token and one re-authentication on 401")
    func multipartUploadReauthenticates() async throws {
        let transport = ScriptedTransport(statuses: [401, 200], body: Data(#"{"ok":true}"#.utf8))
        let tokens = CountingTokens()
        let client = ZoroAPIClient(baseURL: URL(string: "https://zoro.example.ts.net")!, transport: transport, tokens: tokens)
        let file = UploadFile(filename: "statement.csv", data: Data("date,amount\n".utf8), mimeType: "text/csv")
        let multipart = MultipartRequest(path: "/v1/finance/imports", fields: [("account", "hdfc")], fileField: "file", file: file, boundary: "b1")

        let data = try await APIFileUploader(api: client).upload(multipart)

        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        #expect(transport.seen.count == 2)
        let first = try #require(transport.seen.first)
        let last = try #require(transport.seen.last)
        #expect(first.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=b1")
        #expect(last.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=b1")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer token-2")
        #expect(last.httpBody == multipart.body)
        #expect(last.url?.path == "/v1/finance/imports")
    }

    @Test("A second 401 after re-authentication is reported, not retried again")
    func uploadFailsAfterSecondUnauthorized() async throws {
        let transport = ScriptedTransport(statuses: [401, 401])
        let client = ZoroAPIClient(baseURL: URL(string: "https://zoro.example.ts.net")!, transport: transport, tokens: CountingTokens())
        let multipart = MultipartRequest(
            path: "/v1/investments/holdings/import", fields: [], fileField: "file",
            file: UploadFile(filename: "h.csv", data: Data(), mimeType: "text/csv"))
        await #expect(throws: ZoroError.unauthorized) { try await APIFileUploader(api: client).upload(multipart) }
        #expect(transport.seen.count == 2)
    }

    @Test("JSON requests still say application/json")
    func jsonContentTypeUnchanged() async throws {
        let transport = ScriptedTransport(statuses: [200], body: Data("[]".utf8))
        let client = ZoroAPIClient(baseURL: URL(string: "https://zoro.example.ts.net")!, transport: transport, tokens: CountingTokens())
        try await client.send(try .json(.post, "/v1/turns/t/cancel", body: ["reason": "test"]))
        #expect(transport.seen.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("Before pairing every call is notPaired; after pairing it reaches the paired address")
    func serverBoundAPIFollowsEndpoint() async throws {
        let transport = ScriptedTransport(statuses: [200], body: Data(#"{"items":[]}"#.utf8))
        let endpoint = ServerEndpoint()
        let api = ServerBoundAPI(endpoint: endpoint, identity: UnavailableService(), transport: transport)
        await #expect(throws: ZoroError.notPaired) { _ = try await api.capabilities() }
        var streamError: Error?
        do { for try await _ in api.startTurn(TurnRequest(input: TurnInput(text: "hi"), client: ClientContext(platform: .ios))) {} } catch { streamError = error }
        #expect((streamError as? ZoroError) == .notPaired)

        endpoint.set(URL(string: "https://home-mac.example.ts.net:8443")!)
        // The session needs a signed challenge; the unavailable identity cannot sign, so the call fails
        // before any authenticated request is sent: no request ever carries a missing token.
        await #expect(throws: (any Error).self) { _ = try await api.capabilities() }
        #expect(transport.seen.allSatisfy { $0.url?.host == "home-mac.example.ts.net" })
        #expect(try api.client().baseURL.absoluteString == "https://home-mac.example.ts.net:8443")
    }
}
