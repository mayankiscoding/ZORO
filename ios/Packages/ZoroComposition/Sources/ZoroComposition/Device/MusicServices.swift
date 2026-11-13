import Foundation
import MusicIntegration
import PhotoIntelligence
import ZoroCore

/// `MusicControlling` for the Music screen: Apple Music through MusicKit on both platforms (macOS 14+
/// has `ApplicationMusicPlayer`). Spotify playback is driven by the device tool (`device.music.control`
/// opens the Spotify app on iPhone and uses allowlisted AppleScript on the Mac); the Spotify Web API
/// playback routes are not offered by the server, so the screen's Spotify controls say so.
enum AppleMusicServices {
    @MainActor
    static func make() -> any MusicControlling {
        #if canImport(MusicKit)
        return AppleMusicController(backend: MusicKitBackend())
        #else
        return UnavailableService()
        #endif
    }
}

extension PhotoIntelligenceService: PhotoIndexing {}
