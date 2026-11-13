import Foundation
import Testing
import ZoroCore
@testable import AgentClient

private let base = URL(string: "https://zoro.tailnet.example:8443/")!

private let securityStateJSON = """
    {"privacy_mode":"strict_private","kill_switch":false,"strict_allow_public_external":false,"biometric_for_high_risk":true,
     "session_expires_at":"2026-11-12T09:45:15Z","permissions":[],"devices":[]}
    """

@Suite("ZoroAPIClient")
struct APIClientTests {
    @Test func sendsBearerAndDecodes() async throws {
        let transport = ScriptedTransport([.response(200, securityStateJSON)])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        let state = try await client.securityState()
        #expect(state.privacyMode == .strictPrivate && state.biometricForHighRisk)
        let request = try #require(transport.requests.get.first)
        #expect(request.url?.absoluteString == "https://zoro.tailnet.example:8443/v1/security/state")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
    }

    @Test func reauthenticatesOnceOn401() async throws {
        let tokens = FakeTokens()
        let transport = ScriptedTransport([.response(401, ""), .response(200, securityStateJSON)])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: tokens)
        _ = try await client.securityState()
        #expect(transport.authorizations() == ["Bearer token-1", "Bearer token-2"])
        #expect(await tokens.invalidated == ["token-1"])
    }

    @Test func secondConsecutive401IsUnauthorized() async throws {
        let tokens = FakeTokens()
        let transport = ScriptedTransport([.response(401, ""), .response(401, ""), .response(200, securityStateJSON)])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: tokens)
        await #expect(throws: ZoroError.unauthorized) { try await client.securityState() }
        #expect(transport.requests.get.count == 2)  // exactly one retry
    }

    @Test func authEndpointsSendNoToken() async throws {
        let transport = ScriptedTransport([.response(200, #"{"nonce":"n1","expires_at":"2026-11-12T09:31:15Z"}"#)])
        let client = ZoroAPIClient(baseURL: base, transport: transport)
        let challenge = try await client.challenge(ChallengeRequest(deviceId: "dev_1"))
        #expect(challenge.nonce == "n1")
        let request = try #require(transport.requests.get.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpMethod == "POST")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == #"{"device_id":"dev_1"}"#)
    }

    @Test func protectedCallWithoutTokenProviderIsNotPaired() async {
        let client = ZoroAPIClient(baseURL: base, transport: ScriptedTransport([]))
        await #expect(throws: ZoroError.notPaired) { try await client.capabilities() }
    }

    @Test func errorBodyIsSurfaced() async throws {
        let transport = ScriptedTransport([.response(423, #"{"code":"kill_switch","message":"Kill switch is on","retryable":false}"#)])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        await #expect(throws: ZoroError.http(status: 423, body: ErrorBody(code: "kill_switch", message: "Kill switch is on"))) {
            try await client.securityState()
        }
    }

    @Test func malformedBodyIsDecodingError() async {
        let transport = ScriptedTransport([.response(200, "{}")])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        await #expect(throws: ZoroError.decoding("SecurityState")) { try await client.securityState() }
    }

    @Test func transportFailureIsWrapped() async {
        let transport = ScriptedTransport([.failure(URLError(.timedOut))])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        await #expect(throws: ZoroError.timeout) { try await client.securityState() }
    }

    @Test func listEndpointsAcceptArrayOrPage() async throws {
        let cap = #"{"id":"ios.alarm.create","title":"Alarms","domain":"device","status":"working_native"}"#
        let transport = ScriptedTransport([.response(200, "[\(cap)]"), .response(200, #"{"items":[\#(cap)],"next_cursor":null}"#)])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        #expect(try await client.capabilities().count == 1)
        #expect(try await client.capabilities().first?.status == .workingNative)
    }

    @Test func pathSegmentsAndQueriesAreEncoded() async throws {
        let transport = ScriptedTransport([.response(200, #"{"items":[],"next_cursor":null}"#)])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        _ = try await client.messages(conversationId: "conv/1 x", cursor: "c=2&x", limit: 20)
        let url = try #require(transport.requests.get.first?.url?.absoluteString)
        #expect(url.hasPrefix("https://zoro.tailnet.example:8443/v1/conversations/conv%2F1%20x/messages?"))
        #expect(url.contains("limit=20"))
        #expect(!url.contains("c=2&x"))
    }

    // MARK: - Turn streams

    @Test func startTurnStreamsTypedEvents() async throws {
        let transport = ScriptedTransport([
            .stream(200, [
                "event: turn_started\r\ndata: {\"type\":\"turn_started\",\"turn_id\":\"t1\",\"conversation_id\":\"c1\",\"privacy_mode\":\"strict_private\"}\r\n\r\n",
                ": keep-alive\r\n\r\nevent: text_delta\r\ndata: {\"type\":\"text_delta\",\"te",
                "xt\":\"Hello\"}\r\n\r",
                "\nevent: turn_completed\ndata: {\"turn_id\":\"t1\",\"message_id\":\"m1\",\"language\":\"en\",\"data_classes\":[\"personal\"],\"cloud_voice_allowed\":false,\"usage\":{}}\n\n",
            ])
        ])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        let request = TurnRequest(input: TurnInput(text: "hi"), client: ClientContext(platform: .ios))
        var events: [TurnEvent] = []
        for try await e in client.startTurn(request) { events.append(e) }
        #expect(events.map(\.type) == ["turn_started", "text_delta", "turn_completed"])
        #expect(events[1] == .textDelta(TextDelta(text: "Hello")))
        let sent = try #require(transport.requests.get.first)
        #expect(sent.url?.path == "/v1/turns")
        #expect(sent.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func turnStreamReauthenticatesOn401() async throws {
        let transport = ScriptedTransport([
            .stream(401, [""]),
            .stream(200, ["data: {\"type\":\"turn_suspended\",\"turn_id\":\"t1\",\"reason\":\"approval\"}\n\n"]),
        ])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        var events: [TurnEvent] = []
        for try await e in client.resumeTurn(id: "t1", ResumeRequest()) { events.append(e) }
        #expect(events == [.turnSuspended(TurnSuspended(turnId: "t1", reason: .approval))])
        #expect(transport.authorizations() == ["Bearer token-1", "Bearer token-2"])
        #expect(transport.requests.get.last?.url?.path == "/v1/turns/t1/resume")
    }

    @Test func turnStreamErrorStatusThrows() async {
        let transport = ScriptedTransport([.stream(503, [#"{"code":"no_model","message":"down","retryable":true}"#])])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        await #expect(throws: ZoroError.http(status: 503, body: ErrorBody(code: "no_model", message: "down", retryable: true))) {
            for try await _ in client.startTurn(TurnRequest(input: TurnInput(text: "x"), client: ClientContext(platform: .macos))) {}
        }
    }

    @Test func malformedEventFailsTheStream() async {
        let transport = ScriptedTransport([.stream(200, ["data: {not json\n\n"])])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        await #expect(throws: ZoroError.self) {
            for try await _ in client.startTurn(TurnRequest(input: TurnInput(text: "x"), client: ClientContext(platform: .ios))) {}
        }
    }

    // MARK: - Pagination

    @Test func paginationFollowsCursors() async throws {
        let calls = Locked<[String?]>([])
        let items = try await Pagination.collect { (cursor: String?) -> Page<String> in
            calls.withLock { $0.append(cursor) }
            switch cursor {
            case nil: return Page(items: ["a", "b"], nextCursor: "2")
            case "2": return Page(items: ["c"], nextCursor: "3")
            default: return Page(items: ["d"], nextCursor: nil)
            }
        }
        #expect(items == ["a", "b", "c", "d"])
        #expect(calls.get == [nil, "2", "3"])
    }

    @Test func paginationDetectsCursorLoopsAndLimits() async throws {
        await #expect(throws: ZoroError.invalidResponse("pagination cursor repeated")) {
            _ = try await Pagination.collect { (_: String?) -> Page<Int> in Page(items: [1], nextCursor: "same") }
        }
        let limited = try await Pagination.collect(maxItems: 3) { (c: String?) -> Page<Int> in
            Page(items: [1, 2], nextCursor: (c ?? "") + "x")
        }
        #expect(limited == [1, 2, 1])
    }

    @Test func voiceAndRouteEndpoints() async throws {
        let config = #"{"settings":{"activation":"hold_to_talk"},"engines":[{"id":"on_device","available":true}],"voices":[]}"#
        let grant = #"{"provider":"gemini","model":"m","ws_url":"wss://x","ephemeral_token":"tok","expires_at":"2099-01-01T00:00:00Z","system_instruction":"s"}"#
        let transport = ScriptedTransport([
            .response(200, "[]"), .response(200, "[]"), .response(200, config), .response(200, #"{"speaking_rate":1.5}"#),
            .response(200, grant),
        ])
        let client = ZoroAPIClient(baseURL: base, transport: transport, tokens: FakeTokens())
        #expect(try await client.modelRoutes(privacyMode: .cloudIntelligence).isEmpty)
        #expect(try await client.modelRoutes(privacyMode: nil).isEmpty)
        #expect(try await client.voiceConfig().settings.activation == .holdToTalk)
        var settings = VoiceSettings()
        settings.speakingRate = 1.5
        #expect(try await client.updateVoiceSettings(settings).speakingRate == 1.5)
        #expect(try await client.liveSession().ephemeralToken == "tok")

        let sent = transport.requests.get
        #expect(sent.map { $0.httpMethod ?? "" } == ["GET", "GET", "GET", "PUT", "POST"])
        #expect(sent[0].url?.absoluteString == "https://zoro.tailnet.example:8443/v1/models/routes?privacy_mode=cloud_intelligence")
        #expect(sent[1].url?.absoluteString == "https://zoro.tailnet.example:8443/v1/models/routes")
        #expect(sent[2].url?.path == "/v1/voice/config")
        #expect(sent[3].url?.path == "/v1/voice/settings")
        #expect(String(decoding: sent[3].httpBody ?? Data(), as: UTF8.self).contains(#""speaking_rate":1.5"#))
        #expect(sent[4].url?.path == "/v1/voice/live-session")
        #expect(String(decoding: sent[4].httpBody ?? Data(), as: UTF8.self) == "{}")
        #expect(sent[4].value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
}

