import Foundation
import LifeSupport
import ModelRouter
import ZoroCore

/// Turns the owner's words into a `PhotoQuery`.
public protocol PhotoQueryParsing: Sendable {
    func parse(_ text: String, timeZone: TimeZone) async throws -> ParsedPhotoQuery
}

/// The ZORO server's parser: dates in the owner's time zone, colour and object words in English, Hindi and Hinglish.
public struct ServerPhotoQueryParser: PhotoQueryParsing {
    public let api: any ZoroAPI
    public init(api: any ZoroAPI) { self.api = api }

    public func parse(_ text: String, timeZone: TimeZone) async throws -> ParsedPhotoQuery {
        let request = try APIRequest.json(.post, "/v1/vision/parse-query", body: ParseQueryRequest(text: text, timezone: timeZone.identifier))
        return try await api.send(request, as: ParsedPhotoQuery.self)
    }
}

/// The on-device parser (ModelRouter): no network, no model. Used offline and as the fallback.
public struct DevicePhotoQueryParser: PhotoQueryParsing {
    public let clock: @Sendable () -> Date
    public init(clock: @escaping @Sendable () -> Date = { Date() }) { self.clock = clock }

    public func parse(_ text: String, timeZone: TimeZone) async throws -> ParsedPhotoQuery {
        let query = PhotoQueryParser(clock: clock, timeZone: timeZone).parse(text)
        return ParsedPhotoQuery(query: query, source: .device(reason: "Understood on this device."))
    }
}

/// Tries the server, and falls back to the device when the server cannot answer. The result says which one understood the query.
public struct FallbackPhotoQueryParser: PhotoQueryParsing {
    public let primary: any PhotoQueryParsing
    public let fallback: any PhotoQueryParsing

    public init(primary: any PhotoQueryParsing, fallback: any PhotoQueryParsing) {
        self.primary = primary
        self.fallback = fallback
    }

    public init(api: any ZoroAPI, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(primary: ServerPhotoQueryParser(api: api), fallback: DevicePhotoQueryParser(clock: clock))
    }

    public func parse(_ text: String, timeZone: TimeZone) async throws -> ParsedPhotoQuery {
        do {
            return try await primary.parse(text, timeZone: timeZone)
        } catch {
            if error is CancellationError { throw error }
            var parsed = try await fallback.parse(text, timeZone: timeZone)
            parsed.source = .device(reason: Self.reason(for: error))
            return parsed
        }
    }

    static func reason(for error: Error) -> String {
        switch error as? ZoroError {
        case .transport?, .timeout?, .notPaired?, .unauthorized?:
            return "Understood on this device, because your ZORO server could not be reached."
        case .http(_, let body)?:
            if body?.code.hasPrefix("permission_not_granted:") == true {
                return "Understood on this device. Allow photo search in Security and privacy to let your server help."
            }
            return "Understood on this device, because your ZORO server could not parse it."
        default:
            return "Understood on this device."
        }
    }
}
