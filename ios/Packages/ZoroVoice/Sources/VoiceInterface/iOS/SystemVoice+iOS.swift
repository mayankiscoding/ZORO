// UNVERIFIED-ON-HOST
// iOS branch of SystemVoice: the AVAudioSession-backed controller from AudioEngine/iOS.
#if os(iOS) && canImport(AVFoundation) && canImport(Speech)
import AudioEngine

extension SystemVoice {
    static func platformAudioSession(_ hardware: AVAudioEngineHardware) -> any AudioSessionManaging {
        AudioSessionController(hardware: hardware)
    }
}
#endif
