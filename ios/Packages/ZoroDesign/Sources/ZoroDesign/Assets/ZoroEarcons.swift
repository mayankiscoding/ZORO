import AVFoundation
import Foundation

/// ZORO's four earcons: short struck tones on Sa and Pa, the tanpura's drone interval. Off by
/// default; the owner turns them on in Settings. They pair with, never replace, the orb and haptics.
public enum ZoroEarcon: String, CaseIterable, Sendable {
    /// The orb starts listening (Sa rising to Pa).
    case listenStart
    /// Listening stopped (Pa falling to Sa).
    case listenStop
    /// A turn or an action finished (Sa, Ga, Pa).
    case done
    /// Something went wrong (two low strikes, a semitone apart).
    case error

    public static let fileExtension = "wav"

    public var fileName: String {
        switch self {
        case .listenStart: "zoro-earcon-listen-start"
        case .listenStop: "zoro-earcon-listen-stop"
        case .done: "zoro-earcon-done"
        case .error: "zoro-earcon-error"
        }
    }

    public var url: URL? { ZoroResources.url(named: fileName, extension: Self.fileExtension) }
}

/// What happened when an earcon was asked to play.
public enum ZoroEarconOutcome: Equatable, Sendable {
    case played
    /// Earcons are switched off (the default).
    case disabled
    /// The file is missing or the audio system refused it; the reason is for logs, not for the owner.
    case unavailable(reason: String)
}

/// Plays earcons. Inject this protocol so features and tests can use a silent stand-in.
@MainActor
public protocol ZoroEarconPlaying: AnyObject {
    var isEnabled: Bool { get set }
    @discardableResult func play(_ earcon: ZoroEarcon) -> ZoroEarconOutcome
}

/// The default earcon player. It never configures the audio session: on iOS it plays through
/// whatever session the voice engine has set (`.playAndRecord` during a voice session), so an
/// earcon never interrupts or ducks the owner's audio on its own.
@MainActor
public final class ZoroEarconPlayer: ZoroEarconPlaying {
    /// Suggested `UserDefaults` key for the owner's setting. The app owns the setting; this type only
    /// reads the value it is given.
    public static let enabledDefaultsKey = "zoro.earcons.enabled"

    public var isEnabled: Bool
    /// 0...1. Earcons are mastered at -9 dBFS; 0.6 keeps them under speech.
    public var volume: Float = 0.6
    private var players: [ZoroEarcon: AVAudioPlayer] = [:]

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    /// Decodes every earcon ahead of first use. Returns the earcons that could not be loaded.
    @discardableResult
    public func preload() -> [ZoroEarcon] {
        ZoroEarcon.allCases.filter { (try? player(for: $0)) == nil }
    }

    @discardableResult
    public func play(_ earcon: ZoroEarcon) -> ZoroEarconOutcome {
        guard isEnabled else { return .disabled }
        do {
            let player = try player(for: earcon)
            player.volume = volume
            player.currentTime = 0
            return player.play() ? .played : .unavailable(reason: "The audio system did not start \(earcon.fileName).")
        } catch {
            return .unavailable(reason: "\(error)")
        }
    }

    enum LoadError: Error, CustomStringConvertible {
        case missingFile(String)
        var description: String {
            switch self {
            case .missingFile(let name): "\(name).\(ZoroEarcon.fileExtension) is missing from the ZoroDesign bundle."
            }
        }
    }

    func player(for earcon: ZoroEarcon) throws -> AVAudioPlayer {
        if let cached = players[earcon] { return cached }
        guard let url = earcon.url else { throw LoadError.missingFile(earcon.fileName) }
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        players[earcon] = player
        return player
    }
}
