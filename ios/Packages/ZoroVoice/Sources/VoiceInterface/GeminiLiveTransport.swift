import AgentClient
import Foundation
import ZoroCore

/// A realtime voice connection.
public protocol LiveTransporting: Sendable {
    /// Opens the socket, sends the setup message and streams server events until the socket closes.
    /// The stream finishes normally after `close()`, and throws when the connection fails.
    func connect(grant: LiveSessionGrant, resumptionHandle: String?) async throws -> AsyncThrowingStream<LiveServerEvent, Error>
    func sendAudio(_ pcm16: Data) async throws
    func sendToolResponse(callId: String, name: String, response: JSONObject) async throws
    func close() async
}

/// Gemini Live over URLSessionWebSocketTask (through AgentClient's `WebSocketConnecting`), using the
/// ephemeral token from `POST /v1/voice/live-session`. The provider key never reaches the device.
public actor GeminiLiveTransport: LiveTransporting {
    private let connector: any WebSocketConnecting
    private let options: LiveSetupOptions
    private var connection: (any WebSocketConnection)?
    private var receiveTask: Task<Void, Never>?
    private var inputSampleRate = 16_000
    private var generation = 0

    public init(connector: any WebSocketConnecting = URLSessionWebSocketConnector(), options: LiveSetupOptions = LiveSetupOptions()) {
        self.connector = connector
        self.options = options
    }

    public func connect(grant: LiveSessionGrant, resumptionHandle: String?) async throws -> AsyncThrowingStream<LiveServerEvent, Error> {
        await close()
        if grant.expiresAt <= Date() { throw VoiceError.liveSession("the live-session grant has expired") }
        var request = URLRequest(url: try LiveMessageCodec.socketURL(for: grant))
        request.timeoutInterval = 15
        let socket = try await connector.connect(request)
        do {
            try await socket.send(try LiveMessageCodec.setup(grant: grant, resumptionHandle: resumptionHandle, options: options))
        } catch {
            await socket.close()
            throw VoiceError.liveSession("could not start the session: \(ZoroError.wrap(error).localizedDescription)")
        }
        generation += 1
        let gen = generation
        connection = socket
        inputSampleRate = grant.inputSampleRate
        let (stream, continuation) = AsyncThrowingStream<LiveServerEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(512))
        receiveTask = Task {
            do {
                while !Task.isCancelled {
                    let text = try await socket.receive()
                    for event in try LiveMessageCodec.decode(text) { continuation.yield(event) }
                }
                continuation.finish()
            } catch {
                if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: VoiceError.liveSession(ZoroError.wrap(error).localizedDescription)) }
            }
            self.connectionEnded(gen)
        }
        let task = receiveTask
        continuation.onTermination = { _ in task?.cancel() }
        return stream
    }

    public func sendAudio(_ pcm16: Data) async throws {
        guard let connection else { throw VoiceError.liveSession("not connected") }
        try await connection.send(try LiveMessageCodec.realtimeAudio(pcm16, sampleRate: inputSampleRate))
    }

    public func sendToolResponse(callId: String, name: String, response: JSONObject) async throws {
        guard let connection else { throw VoiceError.liveSession("not connected") }
        try await connection.send(try LiveMessageCodec.toolResponse(callId: callId, name: name, response: response))
    }

    public func close() async {
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        if let connection {
            self.connection = nil
            await connection.close()
        }
    }

    private func connectionEnded(_ gen: Int) {
        guard gen == generation else { return }
        connection = nil
        receiveTask = nil
    }
}
