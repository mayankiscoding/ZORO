import Foundation
import ZoroCore

/// `VoiceBackend` over the app's `ZoroAPI` client.
public struct ZoroAPIVoiceBackend: VoiceBackend {
    public static let liveSessionPath = "/v1/voice/live-session"
    private let api: any ZoroAPI

    public init(api: any ZoroAPI) { self.api = api }

    public func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        api.startTurn(request)
    }

    public func cancelTurn(id: String) async throws {
        try await api.cancelTurn(id: id)
    }

    /// The backend decides whether cloud voice is allowed (privacy mode, key present) and answers
    /// with an error otherwise; the session then falls back to on-device.
    public func liveSessionGrant() async throws -> LiveSessionGrant {
        try await api.liveSession()
    }
}
