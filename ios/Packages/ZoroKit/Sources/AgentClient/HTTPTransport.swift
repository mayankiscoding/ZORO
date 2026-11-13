import Foundation
import ZoroCore

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public struct HTTPStreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    /// Body chunks in arrival order; chunk boundaries are arbitrary.
    public var body: AsyncThrowingStream<Data, Error>
    public init(status: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Reads the whole body (used for error responses).
    public func collect(limit: Int = 1 << 20) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count >= limit { break }
        }
        return data
    }
}

/// The network seam: `URLSessionTransport` in the app, scripted fakes in tests.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
    func stream(for request: URLRequest) async throws -> HTTPStreamResponse
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        let http = try Self.http(response)
        return HTTPResponse(status: http.statusCode, headers: Self.headers(http), body: data)
    }

    public func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let http = try Self.http(response)
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(4096)
                    for try await byte in bytes {
                        buffer.append(byte)
                        // Flush per line so events reach the parser as soon as they end.
                        if byte == 0x0A || buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(status: http.statusCode, headers: Self.headers(http), body: body)
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ZoroError.invalidResponse("not an HTTP response") }
        return http
    }

    private static func headers(_ http: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { out[k.lowercased()] = v }
        }
        return out
    }
}
