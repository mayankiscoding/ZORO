import Foundation
import ZoroCore

/// Executes `device.photos.search` for the backend (device contract). The result carries asset
/// identifiers and metadata only, never image bytes:
///
///     { "hits": [{ "asset_id", "captured_at", "score", "labels": [], "matched": [], "media" }],
///       "indexed_count", "limited_library", "next_cursor" }
public struct PhotoSearchActionHandler: DeviceActionExecuting {
    public static let toolName = "device.photos.search"

    private let service: PhotoIntelligenceService
    private let timeZone: TimeZone
    private let requestAuthorizationIfNeeded: Bool
    private let now: @Sendable () -> Date

    /// - Parameter requestAuthorizationIfNeeded: show the system Photos prompt when access was never
    ///   asked for (the owner just asked for a photo, so this is "in context").
    public init(
        service: PhotoIntelligenceService, timeZone: TimeZone = .current, requestAuthorizationIfNeeded: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.timeZone = timeZone
        self.requestAuthorizationIfNeeded = requestAuthorizationIfNeeded
        self.now = now
    }

    public var supportedTools: [String] { [Self.toolName] }

    public func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
        let at = now()
        guard request.tool == Self.toolName else {
            return .failure(request, code: .unsupported, message: "This handler runs \(Self.toolName) only.", capabilityStatus: .unavailable, at: at)
        }
        guard request.expiresAt > at else {
            return .failure(request, code: .expired, message: "The request expired before it ran.", at: at)
        }
        let query: PhotoQuery
        do {
            switch request.args["query"] {
            case .object(let object)?:
                query = try PhotoQuery(json: object, timeZone: timeZone)
            case .string(let text)?:
                query = PhotoQuery(text: text)
            default:
                throw PhotoQuery.ValidationError("query is required")
            }
        } catch {
            return .failure(request, code: .invalidArguments, message: Self.message(error), at: at)
        }

        var status = await service.authorizationStatus()
        if status == .notDetermined && requestAuthorizationIfNeeded {
            status = await service.requestAuthorization()
        }
        guard status == .authorized || status == .limited else {
            return .failure(
                request, code: .permissionDenied, message: "Photos access is not allowed. Allow it in Settings to search photos.",
                capabilityStatus: .manualUserStep, at: now())
        }
        do {
            let response = try await service.search(query)
            return DeviceActionResult(
                actionId: request.actionId, ok: true, result: Self.encode(response, timeZone: timeZone),
                capabilityStatus: .workingNative, executedAt: now())
        } catch PhotoSearchError.permissionDenied {
            return .failure(request, code: .permissionDenied, message: "Photos access is not allowed.", capabilityStatus: .manualUserStep, at: now())
        } catch is CancellationError {
            return .failure(request, code: .failed, message: "The search was cancelled.", at: now())
        } catch {
            return .failure(request, code: .failed, message: Self.message(error), at: now())
        }
    }

    /// Contract JSON for a response.
    public static func encode(_ response: PhotoSearchResult, timeZone: TimeZone) -> JSONObject {
        let hits: [JSONValue] = response.hits.map { hit in
            .object([
                "asset_id": .string(hit.assetId),
                "captured_at": hit.capturedAt.map { .string(formatDate($0, timeZone: timeZone)) } ?? .null,
                "score": .number(hit.score),
                "labels": .array(hit.labels.map(JSONValue.string)),
                "matched": .array(hit.matched.map(JSONValue.string)),
                "media": .string(hit.media.rawValue),
            ])
        }
        return [
            "hits": .array(hits),
            "indexed_count": .number(Double(response.indexedCount)),
            "limited_library": .bool(response.limitedLibrary),
            "next_cursor": response.nextCursor.map(JSONValue.string) ?? .null,
        ]
    }

    /// ISO-8601 with the owner's offset, e.g. `2026-11-11T18:30:05+05:30`.
    static func formatDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func message(_ error: Error) -> String {
        switch error {
        case let error as PhotoQuery.ValidationError: "Invalid photo query: \(error.reason)."
        case PhotoSearchError.unsupportedMedia(let reason): "Unsupported media: \(reason)."
        case let error as ZoroError: error.errorDescription ?? "Photo search failed."
        default: "Photo search failed."
        }
    }
}
