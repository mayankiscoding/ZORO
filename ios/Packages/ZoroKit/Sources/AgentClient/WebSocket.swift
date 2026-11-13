import Foundation
import ZoroCore

/// One open WebSocket carrying JSON text frames.
public protocol WebSocketConnection: Sendable {
    func send(_ text: String) async throws
    /// Next text frame; throws when the socket closes or fails (`ZoroError.unauthorized` for a 401 handshake).
    func receive() async throws -> String
    func close() async
}

public protocol WebSocketConnecting: Sendable {
    func connect(_ request: URLRequest) async throws -> any WebSocketConnection
}

public struct URLSessionWebSocketConnector: WebSocketConnecting {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw mapped(error)
        }
    }

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let s): return s
            case .data(let d): return String(decoding: d, as: UTF8.self)
            @unknown default: throw ZoroError.invalidResponse("unknown WebSocket frame")
            }
        } catch {
            throw mapped(error)
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func mapped(_ error: Error) -> Error {
        if (task.response as? HTTPURLResponse)?.statusCode == 401 { return ZoroError.unauthorized }
        return error
    }
}

/// Exponential backoff with symmetric jitter: `min(maximum, initial * multiplier^attempt) * (1 ± jitter)`.
public struct BackoffPolicy: Sendable, Equatable {
    public var initial: Double
    public var multiplier: Double
    public var maximum: Double
    public var jitter: Double

    public init(initial: Double = 1, multiplier: Double = 2, maximum: Double = 60, jitter: Double = 0.2) {
        self.initial = initial
        self.multiplier = multiplier
        self.maximum = maximum
        self.jitter = jitter
    }

    /// `random` is in 0...1; 0.5 means no jitter.
    public func delay(attempt: Int, random: Double) -> Double {
        let base = min(maximum, initial * pow(multiplier, Double(max(0, attempt))))
        let r = min(1, max(0, random))
        return max(0, base * (1 + jitter * (2 * r - 1)))
    }
}

public protocol Sleeping: Sendable {
    func sleep(seconds: Double) async throws
}

public struct TaskSleeper: Sleeping {
    public init() {}
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
