import Foundation
import LifeSupport
import ZoroCore

/// Whether one provider can be used right now, and if not, the one sentence that says why and what to do.
public struct ProviderState: Sendable, Equatable {
    public enum Readiness: Sendable, Equatable {
        case ready
        /// The owner can fix it from this screen.
        case needsSetup(Action)
        /// Nothing the owner can do here (server not set up, restricted device).
        case unavailable
    }

    public enum Action: String, Sendable, Equatable {
        case connectSpotify, allowAppleMusic
        public var title: String { self == .connectSpotify ? "Connect Spotify" : "Allow Apple Music" }
    }

    public var provider: MusicProvider
    public var readiness: Readiness
    public var sentence: String

    public var isReady: Bool { readiness == .ready }
}

public struct MusicProviderChoice: Sendable, Equatable {
    public var spotify: ProviderState
    public var appleMusic: ProviderState
    /// The provider that will be used, or nil when none is ready.
    public var active: MusicProvider?
    /// Why this one, in a sentence.
    public var reason: String

    public func state(for provider: MusicProvider) -> ProviderState { provider == .spotify ? spotify : appleMusic }
}

/// Picks the music provider. The owner's saved choice wins when that provider is ready; otherwise Spotify when it is connected
/// (as the server does), else Apple Music when the owner allowed it, else none.
public enum MusicSelection {
    /// `status` is nil when the server could not be reached: Spotify then cannot be used, because its sign-in lives on the server.
    public static func choose(preferred: MusicProvider?, status: MusicServerStatus?, appleAuthorization: MediaAuthorization) -> MusicProviderChoice {
        let spotify = spotifyState(status)
        let apple = appleMusicState(appleAuthorization)
        func usable(_ p: MusicProvider) -> Bool { (p == .spotify ? spotify : apple).isReady }

        if let preferred, usable(preferred) {
            return MusicProviderChoice(spotify: spotify, appleMusic: apple, active: preferred, reason: "You chose \(preferred.title).")
        }
        if usable(.spotify) {
            return MusicProviderChoice(spotify: spotify, appleMusic: apple, active: .spotify, reason: "Spotify is connected, so ZORO uses it.")
        }
        if usable(.appleMusic) {
            return MusicProviderChoice(spotify: spotify, appleMusic: apple, active: .appleMusic, reason: "Apple Music is allowed on this device, so ZORO uses it.")
        }
        return MusicProviderChoice(
            spotify: spotify, appleMusic: apple, active: nil, reason: "No music service is ready yet. Connect Spotify or allow Apple Music.")
    }

    static func spotifyState(_ status: MusicServerStatus?) -> ProviderState {
        guard let status else {
            return ProviderState(
                provider: .spotify, readiness: .unavailable,
                sentence: "Spotify needs your ZORO server, which could not be reached. Check that it is running, then refresh.")
        }
        switch status.spotify.state {
        case .connected:
            return ProviderState(provider: .spotify, readiness: .ready, sentence: "Spotify is connected.")
        case .notConnected:
            return ProviderState(
                provider: .spotify, readiness: .needsSetup(.connectSpotify),
                sentence: "Spotify is not connected. Connect it to control Spotify from ZORO. Playback control needs Spotify Premium.")
        case .needsReauthorization:
            return ProviderState(provider: .spotify, readiness: .needsSetup(.connectSpotify), sentence: "Spotify needs you to sign in again.")
        case .notConfigured:
            return ProviderState(
                provider: .spotify, readiness: .unavailable,
                sentence: "Spotify is not set up on your ZORO server. Add a Spotify app client id to the server's settings to turn it on.")
        case .unknown:
            return ProviderState(provider: .spotify, readiness: .unavailable, sentence: "Your server reported a Spotify state this app does not know. Update the app.")
        }
    }

    static func appleMusicState(_ auth: MediaAuthorization) -> ProviderState {
        switch auth {
        case .authorized, .limited:
            return ProviderState(provider: .appleMusic, readiness: .ready, sentence: "Apple Music is allowed on this device.")
        case .notDetermined:
            return ProviderState(
                provider: .appleMusic, readiness: .needsSetup(.allowAppleMusic),
                sentence: "Allow Apple Music so ZORO can search and play music on this device.")
        case .denied:
            return ProviderState(
                provider: .appleMusic, readiness: .unavailable,
                sentence: "Apple Music access is off. Turn it on in Settings under ZORO, then refresh.")
        case .restricted:
            return ProviderState(
                provider: .appleMusic, readiness: .unavailable,
                sentence: "Apple Music access is restricted on this device, for example by Screen Time. ZORO cannot use it until that changes.")
        }
    }
}

/// Moving playback between devices.
public struct DeviceChoice: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var isActive: Bool
        public var accessibilityLabel: String { isActive ? "\(name), playing here" : "\(name), move playback here" }
    }

    public var rows: [Row]
    /// The honest note about what this provider can do across devices.
    public var note: String
    public var canMove: Bool

    public var targets: [Row] { rows.filter { !$0.isActive } }
}

public enum DeviceSelection {
    /// `devices` come from `MusicControlling.outputDevices()`. The active one is the device the player reports; the session
    /// device (saved on the server) is used when the player reports none.
    public static func choice(devices: [MusicOutputDevice], session: SessionDevice?, provider: MusicProvider?) -> DeviceChoice {
        var rows = devices.map { DeviceChoice.Row(id: $0.id, name: $0.name, isActive: $0.isActive) }
        if !rows.contains(where: \.isActive), let session, let id = session.id, let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].isActive = true
        }
        switch provider {
        case .spotify:
            let note = rows.isEmpty
                ? "No devices found. Open Spotify on your iPhone or Mac and sign in to the same account, then refresh. Playback control needs Spotify Premium."
                : "Spotify can move playback to any device that has Spotify open and is signed in to your account. Playback control needs Spotify Premium."
            return DeviceChoice(rows: rows, note: note, canMove: rows.contains { !$0.isActive })
        case .appleMusic:
            return DeviceChoice(
                rows: rows,
                note: "Apple does not let apps move Apple Music between your devices. Use the AirPlay button in Control Centre to pick where it plays.",
                canMove: false)
        case nil:
            return DeviceChoice(rows: rows, note: "Choose a music service first, then you can move playback between your devices.", canMove: false)
        }
    }
}

/// Playback state in words.
public struct NowPlayingPresentation: Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var provider: String?
    public var device: String?
    public var isPlaying: Bool
    public var progress: Double?
    public var positionText: String?
    public var observedLine: String

    public var accessibilityLabel: String {
        var parts = [isPlaying ? "Playing" : "Paused", title]
        if let subtitle { parts.append(subtitle) }
        if let device { parts.append("on \(device)") }
        return parts.joined(separator: ", ")
    }
}

public enum NowPlayingPresenter {
    /// nil when nothing is loaded in the player.
    public static func presentation(_ n: NowPlaying?, now: Date, timeZone: TimeZone = .current) -> NowPlayingPresentation? {
        guard let n, let item = n.item else { return nil }
        var progress: Double?
        var position: String?
        if let pos = n.positionSeconds, let dur = n.durationSeconds, dur > 0 {
            progress = min(max(pos / dur, 0), 1)
            position = "\(LifeFormat.clock(seconds: pos)) of \(LifeFormat.clock(seconds: dur))"
        }
        return NowPlayingPresentation(
            title: item.title, subtitle: item.subtitle, provider: MusicProvider(service: item.service).title,
            device: n.deviceName, isPlaying: n.isPlaying, progress: progress, positionText: position,
            observedLine: "As of \(LifeFormat.moment(n.observedAt, now: now, timeZone: timeZone))")
    }
}
