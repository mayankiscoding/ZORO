import Foundation
import ZoroCore

/// Asks for Apple Music access (the system sheet). The MusicKit implementation is `MusicKitAuthorizer`.
public protocol MusicAuthorizing: Sendable {
    func requestAuthorization() async -> MediaAuthorization
}

public struct UnavailableMusicAuthorizer: MusicAuthorizing {
    public init() {}
    public func requestAuthorization() async -> MediaAuthorization { .restricted }
}

/// What happened to a playlist request.
public enum PlaylistOutcome: Sendable, Equatable {
    /// The playlist was made; `message` is ZORO's reply.
    case created(message: String)
    /// The turn is waiting for the owner to approve it (creating a playlist changes the owner's Spotify account).
    case waitingForApproval(title: String)
}

/// Creates a Spotify playlist. The server has no REST route for it: `music.create_playlist` is a tool the server runs inside a turn
/// (medium risk, so it asks the owner to approve).
public protocol PlaylistCreating: Sendable {
    func createPlaylist(named name: String) async throws -> PlaylistOutcome
}

/// Creates a playlist by sending ZORO a turn, so the approval and audit rules apply exactly as for a spoken request.
public struct TurnPlaylistCreator: PlaylistCreating {
    public let api: any ZoroAPI
    public let platform: DevicePlatform
    public let timeZone: TimeZone

    public init(api: any ZoroAPI, platform: DevicePlatform, timeZone: TimeZone = .current) {
        self.api = api
        self.platform = platform
        self.timeZone = timeZone
    }

    public func createPlaylist(named name: String) async throws -> PlaylistOutcome {
        let clean = Self.cleanName(name)
        guard !clean.isEmpty else { throw ZoroError.unavailable(capability: "Playlists", reason: "a playlist needs a name") }
        let request = TurnRequest(
            input: TurnInput(text: "Create a playlist called \(clean)"),
            client: ClientContext(platform: platform, timezone: timeZone.identifier))
        var reply = ""
        var approval: String?
        for try await event in api.startTurn(request) {
            switch event {
            case .textDelta(let d): reply += d.text
            case .approvalRequired(let a): approval = a.approval.title
            case .error(let e): throw ZoroError.turnFailed(e)
            case .toolFinished(let t) where !t.ok: throw ZoroError.unavailable(capability: "Playlists", reason: t.summary ?? "the playlist was not created")
            default: break
            }
        }
        if let approval { return .waitingForApproval(title: approval) }
        return .created(message: reply.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Quotes and line breaks would confuse the name parser on the server.
    static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\u{201C}", with: "").replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
