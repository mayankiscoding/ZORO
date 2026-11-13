import Foundation
import ZoroCore

/// One function call requested by the realtime model.
public struct LiveFunctionCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var args: JSONObject
    public init(id: String, name: String, args: JSONObject) {
        self.id = id
        self.name = name
        self.args = args
    }
}

/// What the realtime voice server sends. One server message may carry several events.
public enum LiveServerEvent: Sendable, Equatable {
    case setupComplete
    /// Model speech, 16-bit PCM at the grant's output rate.
    case audio(Data)
    case inputTranscript(String)
    case outputTranscript(String)
    /// The owner spoke over the model: drop queued audio now.
    case interrupted
    case generationComplete
    case turnComplete
    case toolCall([LiveFunctionCall])
    case toolCallCancellation([String])
    /// The server will close the connection soon; reconnect with the resumption handle.
    case goAway(timeLeft: TimeInterval?)
    case resumptionUpdate(handle: String?, resumable: Bool)
}

/// Session options sent in the setup message.
public struct LiveSetupOptions: Sendable, Equatable {
    /// Trailing silence before the server's VAD ends the owner's turn (500-800 ms recommended).
    public var silenceDurationMs: Int
    public var prefixPaddingMs: Int
    public var transcribeInput: Bool
    public var transcribeOutput: Bool
    public var slidingWindowCompression: Bool

    public init(silenceDurationMs: Int = 600, prefixPaddingMs: Int = 200, transcribeInput: Bool = true, transcribeOutput: Bool = true, slidingWindowCompression: Bool = true) {
        self.silenceDurationMs = silenceDurationMs
        self.prefixPaddingMs = prefixPaddingMs
        self.transcribeInput = transcribeInput
        self.transcribeOutput = transcribeOutput
        self.slidingWindowCompression = slidingWindowCompression
    }
}

/// JSON encoding and decoding for the Gemini Live API (BidiGenerateContent over WebSocket).
/// Field names follow the Live API reference (aistudio.google.com/api-reference/live); the client
/// wrapper keys `setup`, `realtimeInput` and `toolResponse` were not shown on the fetched pages.
public enum LiveMessageCodec {
    public static let toolName = "ask_zoro"

    /// The single tool: every question goes to the owner's backend, where policy lives.
    public static let askZoroDeclaration: JSONValue = [
        "name": .string(toolName),
        "description": "Ask ZORO, the owner's private assistant backend. Use it for every request that needs the owner's data, memory, tools, devices or any action. Pass the owner's request in their own words and language.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "request": ["type": "STRING", "description": "The owner's request, verbatim, in their language (Hindi, English or Hinglish)."],
            ],
            "required": ["request"],
        ],
    ]

    /// The grant's socket URL with the ephemeral token as `access_token` (unless already present).
    public static func socketURL(for grant: LiveSessionGrant) throws -> URL {
        guard var components = URLComponents(string: grant.wsUrl), let scheme = components.scheme?.lowercased(),
            scheme == "wss" || scheme == "ws"
        else {
            throw VoiceError.liveSession("invalid socket URL in the live-session grant")
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "access_token" }) {
            items.append(URLQueryItem(name: "access_token", value: grant.ephemeralToken))
        }
        components.queryItems = items
        guard let url = components.url else { throw VoiceError.liveSession("invalid socket URL in the live-session grant") }
        return url
    }

    public static func modelResource(_ model: String) -> String {
        model.hasPrefix("models/") ? model : "models/\(model)"
    }

    public static func setup(grant: LiveSessionGrant, resumptionHandle: String?, options: LiveSetupOptions = LiveSetupOptions()) throws -> String {
        var setup: JSONObject = [
            "model": .string(modelResource(grant.model)),
            "generationConfig": ["responseModalities": ["AUDIO"]],
            "tools": [["functionDeclarations": [askZoroDeclaration]]],
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "disabled": false,
                    "prefixPaddingMs": .number(Double(options.prefixPaddingMs)),
                    "silenceDurationMs": .number(Double(options.silenceDurationMs)),
                ],
            ],
            "sessionResumption": resumptionHandle.map { ["handle": .string($0)] } ?? [:],
        ]
        if !grant.systemInstruction.isEmpty {
            setup["systemInstruction"] = ["parts": [["text": .string(grant.systemInstruction)]]]
        }
        if options.slidingWindowCompression { setup["contextWindowCompression"] = ["slidingWindow": [:]] }
        if options.transcribeInput { setup["inputAudioTranscription"] = [:] }
        if options.transcribeOutput { setup["outputAudioTranscription"] = [:] }
        return try encode(["setup": .object(setup)])
    }

    public static func realtimeAudio(_ pcm16: Data, sampleRate: Int) throws -> String {
        try encode([
            "realtimeInput": [
                "audio": ["mimeType": .string("audio/pcm;rate=\(sampleRate)"), "data": .string(pcm16.base64EncodedString())],
            ],
        ])
    }

    public static func toolResponse(callId: String, name: String, response: JSONObject) throws -> String {
        try encode([
            "toolResponse": [
                "functionResponses": [["id": .string(callId), "name": .string(name), "response": .object(response)]],
            ],
        ])
    }

    public static func decode(_ text: String) throws -> [LiveServerEvent] {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            throw VoiceError.liveSession("unreadable message from the voice server")
        }
        guard let root = value.objectValue else { throw VoiceError.liveSession("unexpected message from the voice server") }
        var events: [LiveServerEvent] = []
        if root["setupComplete"] != nil { events.append(.setupComplete) }
        if let content = root["serverContent"] {
            if let text = content["inputTranscription"]?["text"]?.stringValue, !text.isEmpty { events.append(.inputTranscript(text)) }
            if content["interrupted"]?.boolValue == true { events.append(.interrupted) }
            for part in content["modelTurn"]?["parts"]?.arrayValue ?? [] {
                if let b64 = part["inlineData"]?["data"]?.stringValue, let data = Data(base64Encoded: b64) {
                    events.append(.audio(data))
                }
            }
            if let text = content["outputTranscription"]?["text"]?.stringValue, !text.isEmpty { events.append(.outputTranscript(text)) }
            if content["generationComplete"]?.boolValue == true { events.append(.generationComplete) }
            if content["turnComplete"]?.boolValue == true { events.append(.turnComplete) }
        }
        if let calls = root["toolCall"]?["functionCalls"]?.arrayValue {
            let parsed = calls.compactMap { c -> LiveFunctionCall? in
                guard let name = c["name"]?.stringValue else { return nil }
                return LiveFunctionCall(id: c["id"]?.stringValue ?? "", name: name, args: c["args"]?.objectValue ?? [:])
            }
            if !parsed.isEmpty { events.append(.toolCall(parsed)) }
        }
        if let ids = root["toolCallCancellation"]?["ids"]?.arrayValue {
            events.append(.toolCallCancellation(ids.compactMap(\.stringValue)))
        }
        if let goAway = root["goAway"] {
            events.append(.goAway(timeLeft: goAway["timeLeft"]?.stringValue.flatMap(parseDuration)))
        }
        if let update = root["sessionResumptionUpdate"] {
            events.append(.resumptionUpdate(handle: update["newHandle"]?.stringValue, resumable: update["resumable"]?.boolValue ?? false))
        }
        return events
    }

    /// Protobuf JSON duration: "12s", "1.5s".
    public static func parseDuration(_ raw: String) -> TimeInterval? {
        guard raw.hasSuffix("s") else { return nil }
        return TimeInterval(raw.dropLast())
    }

    static func encode(_ object: JSONObject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(JSONValue.object(object)), as: UTF8.self)
    }
}
