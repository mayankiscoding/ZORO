import AgentClient
import Foundation
import Testing
import ZoroCore

@testable import VoiceInterface

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("Live API messages")
struct LiveCodecTests {
    let grant = Harness.grant()

    @Test func setupCarriesLockedModelToolVADAndResumption() throws {
        let setup = try json(LiveMessageCodec.setup(grant: grant, resumptionHandle: "h-1"))["setup"]
        #expect(setup?["model"]?.stringValue == "models/test-live-model")
        #expect(setup?["generationConfig"]?["responseModalities"] == ["AUDIO"])
        #expect(setup?["systemInstruction"]?["parts"]?[0]?["text"]?.stringValue == "Be brief.")
        let decl = setup?["tools"]?[0]?["functionDeclarations"]?[0]
        #expect(decl?["name"]?.stringValue == "ask_zoro")
        #expect(decl?["parameters"]?["required"] == ["request"])
        let vad = setup?["realtimeInputConfig"]?["automaticActivityDetection"]
        #expect(vad?["disabled"]?.boolValue == false)
        #expect(vad?["silenceDurationMs"]?.intValue == 600)
        #expect(setup?["sessionResumption"]?["handle"]?.stringValue == "h-1")
        #expect(setup?["contextWindowCompression"]?["slidingWindow"] == [:])
        #expect(setup?["inputAudioTranscription"] == [:])
        #expect(setup?["outputAudioTranscription"] == [:])
    }

    @Test func newSessionSendsEmptyResumptionConfig() throws {
        let setup = try json(LiveMessageCodec.setup(grant: grant, resumptionHandle: nil))["setup"]
        #expect(setup?["sessionResumption"] == [:])
        #expect(LiveMessageCodec.modelResource("models/x") == "models/x")
    }

    @Test func audioAndToolResponseFrames() throws {
        let audio = try json(LiveMessageCodec.realtimeAudio(Data([1, 2, 3, 4]), sampleRate: 16_000))
        #expect(audio["realtimeInput"]?["audio"]?["mimeType"]?.stringValue == "audio/pcm;rate=16000")
        #expect(audio["realtimeInput"]?["audio"]?["data"]?.stringValue == "AQIDBA==")
        let tool = try json(LiveMessageCodec.toolResponse(callId: "fc1", name: "ask_zoro", response: ["result": "Done"]))
        let r = tool["toolResponse"]?["functionResponses"]?[0]
        #expect(r?["id"]?.stringValue == "fc1")
        #expect(r?["name"]?.stringValue == "ask_zoro")
        #expect(r?["response"]?["result"]?.stringValue == "Done")
    }

    @Test func decodesServerContent() throws {
        let b64 = Data([0, 1, 2, 3]).base64EncodedString()
        let text = """
            {"serverContent":{"inputTranscription":{"text":"kal ka"},"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\(b64)"}}]},"outputTranscription":{"text":"Kal"},"generationComplete":true,"turnComplete":true}}
            """
        #expect(
            try LiveMessageCodec.decode(text) == [
                .inputTranscript("kal ka"), .audio(Data([0, 1, 2, 3])), .outputTranscript("Kal"), .generationComplete, .turnComplete,
            ])
        #expect(try LiveMessageCodec.decode(#"{"serverContent":{"interrupted":true}}"#) == [.interrupted])
        #expect(try LiveMessageCodec.decode(#"{"setupComplete":{}}"#) == [.setupComplete])
    }

    @Test func decodesToolCallsCancellationGoAwayAndResumption() throws {
        let call = #"{"toolCall":{"functionCalls":[{"id":"fc1","name":"ask_zoro","args":{"request":"kal ka mausam"}}]}}"#
        #expect(try LiveMessageCodec.decode(call) == [.toolCall([LiveFunctionCall(id: "fc1", name: "ask_zoro", args: ["request": "kal ka mausam"])])])
        #expect(try LiveMessageCodec.decode(#"{"toolCallCancellation":{"ids":["fc1","fc2"]}}"#) == [.toolCallCancellation(["fc1", "fc2"])])
        #expect(try LiveMessageCodec.decode(#"{"goAway":{"timeLeft":"12.5s"}}"#) == [.goAway(timeLeft: 12.5)])
        #expect(try LiveMessageCodec.decode(#"{"goAway":{}}"#) == [.goAway(timeLeft: nil)])
        #expect(
            try LiveMessageCodec.decode(#"{"sessionResumptionUpdate":{"newHandle":"h2","resumable":true}}"#) == [
                .resumptionUpdate(handle: "h2", resumable: true)
            ])
        #expect(try LiveMessageCodec.decode(#"{"usageMetadata":{"totalTokenCount":5}}"#).isEmpty)
    }

    @Test func malformedMessagesThrowTypedErrors() {
        #expect(throws: VoiceError.self) { try LiveMessageCodec.decode("not json") }
        #expect(throws: VoiceError.self) { try LiveMessageCodec.decode("[1,2]") }
    }

    @Test func socketURLAddsEphemeralTokenOnce() throws {
        let url = try LiveMessageCodec.socketURL(for: grant)
        #expect(url.absoluteString == "wss://example.invalid/ws/live?access_token=tok")
        var g = grant
        g.wsUrl = "wss://example.invalid/ws/live?access_token=already"
        #expect(try LiveMessageCodec.socketURL(for: g).absoluteString == "wss://example.invalid/ws/live?access_token=already")
        g.wsUrl = "https://example.invalid/not-a-socket"
        #expect(throws: VoiceError.self) { try LiveMessageCodec.socketURL(for: g) }
    }
}

// MARK: - Transport over a fake WebSocket

actor FakeSocket: WebSocketConnection {
    private(set) var sent: [String] = []
    private var inbox: [Result<String, Error>] = []
    private var waiter: CheckedContinuation<String, Error>?
    private(set) var closed = false

    func send(_ text: String) async throws { sent.append(text) }
    func receive() async throws -> String {
        if !inbox.isEmpty { return try inbox.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async {
        closed = true
        deliver(.failure(URLError(.cancelled)))
    }
    func deliver(_ r: Result<String, Error>) {
        if let w = waiter {
            waiter = nil
            w.resume(with: r)
        } else {
            inbox.append(r)
        }
    }
}

struct FakeConnector: WebSocketConnecting {
    let socket: FakeSocket
    let requests = Locked<[URLRequest]>([])
    func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        requests.with { $0.append(request) }
        return socket
    }
}

@Suite("Gemini Live transport")
struct LiveTransportTests {
    @Test func sendsSetupFirstThenStreamsEvents() async throws {
        let socket = FakeSocket()
        let connector = FakeConnector(socket: socket)
        let transport = GeminiLiveTransport(connector: connector)
        let events = try await transport.connect(grant: Harness.grant(), resumptionHandle: "h")
        #expect(connector.requests.get().first?.url?.query == "access_token=tok")
        let first = try json(await socket.sent[0])
        #expect(first["setup"]?["sessionResumption"]?["handle"]?.stringValue == "h")

        try await transport.sendAudio(Data([9, 9]))
        try await transport.sendToolResponse(callId: "c", name: "ask_zoro", response: ["result": "ok"])
        #expect(try json(await socket.sent[1])["realtimeInput"] != nil)
        #expect(try json(await socket.sent[2])["toolResponse"] != nil)

        await socket.deliver(.success(#"{"setupComplete":{}}"#))
        await socket.deliver(.success(#"{"serverContent":{"turnComplete":true}}"#))
        var it = events.makeAsyncIterator()
        #expect(try await it.next() == .setupComplete)
        #expect(try await it.next() == .turnComplete)

        await socket.deliver(.failure(URLError(.networkConnectionLost)))
        await #expect(throws: VoiceError.self) { _ = try await it.next() }
        await #expect(throws: VoiceError.self) { try await transport.sendAudio(Data([1])) }
    }

    @Test func closeEndsTheStreamQuietly() async throws {
        let socket = FakeSocket()
        let transport = GeminiLiveTransport(connector: FakeConnector(socket: socket))
        let events = try await transport.connect(grant: Harness.grant(), resumptionHandle: nil)
        await transport.close()
        var it = events.makeAsyncIterator()
        #expect(try await it.next() == nil)
        #expect(await socket.closed)
    }

    @Test func expiredGrantIsRejectedBeforeConnecting() async {
        let socket = FakeSocket()
        let connector = FakeConnector(socket: socket)
        let transport = GeminiLiveTransport(connector: connector)
        await #expect(throws: VoiceError.self) { _ = try await transport.connect(grant: Harness.grant(expiresIn: -1), resumptionHandle: nil) }
        #expect(connector.requests.get().isEmpty)
    }
}
