import Foundation
import ZoroCore
@testable import AgentClient

/// Thread-safe box for test bookkeeping.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
    var get: Value { withLock { $0 } }
}

/// Answers requests from a script, in order; records every request.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case response(Int, String)
        case stream(Int, [String])
        case failure(Error)
    }

    private let replies: Locked<[Reply]>
    let requests = Locked<[URLRequest]>([])

    init(_ replies: [Reply]) { self.replies = Locked(replies) }

    private func next(_ request: URLRequest) throws -> Reply {
        requests.withLock { $0.append(request) }
        guard let reply = replies.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
            throw URLError(.cannotConnectToHost)
        }
        return reply
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        switch try next(request) {
        case .response(let status, let body): return HTTPResponse(status: status, body: Data(body.utf8))
        case .stream(let status, let chunks): return HTTPResponse(status: status, body: Data(chunks.joined().utf8))
        case .failure(let e): throw e
        }
    }

    func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        let chunks: [String]
        let status: Int
        switch try next(request) {
        case .response(let s, let body): (status, chunks) = (s, [body])
        case .stream(let s, let c): (status, chunks) = (s, c)
        case .failure(let e): throw e
        }
        let body = AsyncThrowingStream<Data, Error> { c in
            for chunk in chunks { c.yield(Data(chunk.utf8)) }
            c.finish()
        }
        return HTTPStreamResponse(status: status, body: body)
    }

    func authorizations() -> [String?] { requests.get.map { $0.value(forHTTPHeaderField: "Authorization") } }
}

/// Issues "token-1", "token-2", ... ; each invalidate forces a new one.
actor FakeTokens: AccessTokenProviding {
    private var counter = 1
    private(set) var invalidated: [String] = []
    func validAccessToken() async throws -> String { "token-\(counter)" }
    func invalidate(token: String) async {
        invalidated.append(token)
        if token == "token-\(counter)" { counter += 1 }
    }
}

struct InstantSleeper: Sleeping {
    let delays = Locked<[Double]>([])
    func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        delays.withLock { $0.append(seconds) }
        await Task.yield()
    }
}

/// A scripted WebSocket: the test pushes inbound frames or a disconnect; sent frames are recorded.
final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    let sent = Locked<[String]>([])
    private let inbound: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let iterator: Locked<AsyncThrowingStream<String, Error>.AsyncIterator?>
    let closed = Locked(false)

    init() {
        (inbound, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        iterator = Locked(inbound.makeAsyncIterator())
    }

    func push(_ frame: String) { continuation.yield(frame) }
    func disconnect() { continuation.finish(throwing: URLError(.networkConnectionLost)) }

    func send(_ text: String) async throws { sent.withLock { $0.append(text) } }

    func receive() async throws -> String {
        var it = iterator.get!
        let value = try await it.next()
        iterator.withLock { $0 = it }
        guard let value else { throw URLError(.networkConnectionLost) }
        return value
    }

    func close() async { closed.withLock { $0 = true } }
}

final class FakeConnector: WebSocketConnecting, @unchecked Sendable {
    enum Step { case fail(Error), socket(FakeSocket) }
    private let steps: Locked<[Step]>
    let requests = Locked<[URLRequest]>([])
    init(_ steps: [Step]) { self.steps = Locked(steps) }

    func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        requests.withLock { $0.append(request) }
        let step = steps.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        switch step {
        case .fail(let e): throw e
        case .socket(let s): return s
        case nil: return FakeSocket()  // stays open until the test stops the channel
        }
    }
}

actor FakeExecutor: DeviceActionExecuting {
    private(set) var executed: [String] = []
    var supportedTools: [String] { ["ios.alarm.create"] }
    func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
        executed.append(request.actionId)
        return DeviceActionResult(actionId: request.actionId, ok: true, result: ["alarm_id": "A1"], executedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}

func waitUntil(_ timeout: Double = 5, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() > deadline { throw ZoroError.timeout }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
