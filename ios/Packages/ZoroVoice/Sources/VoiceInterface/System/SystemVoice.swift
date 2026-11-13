#if canImport(AVFoundation) && canImport(Speech)
import AgentClient
import AudioEngine
import Foundation
import ZoroCore

/// Composition helper for the app shell: wires the system implementations into a `VoiceSession`.
public enum SystemVoice {
    public static func makeSession(
        api: any ZoroAPI, client: ClientContext, settings: VoiceSettings = VoiceSettings(),
        configuration: VoiceSessionConfiguration? = nil, webSockets: any WebSocketConnecting = URLSessionWebSocketConnector()
    ) -> VoiceSession {
        let hardware = AVAudioEngineHardware(voiceProcessing: true)
        let dependencies = VoiceSessionDependencies(
            capture: MicrophoneCapture(hardware: hardware),
            player: PCMStreamPlayer(hardware: hardware, sampleRate: 24_000),
            audioSession: platformAudioSession(hardware),
            recognizer: makeRecognizer(),
            synthesizer: SystemSpeechSynthesizer(),
            backend: ZoroAPIVoiceBackend(api: api),
            liveTransport: GeminiLiveTransport(connector: webSockets),
            clock: SystemVoiceClock())
        return VoiceSession(dependencies: dependencies, settings: settings, configuration: configuration ?? VoiceSessionConfiguration(client: client))
    }

    /// SpeechAnalyzer when the SDK and OS have it and the locale model is installed, else SFSpeechRecognizer.
    public static func makeRecognizer() -> any SpeechRecognizing {
        let legacy = SFSpeechRecognizerEngine()
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *), SpeechAnalyzerRecognizer.isSupported {
            return RecognizerChain(primary: SpeechAnalyzerRecognizer(), fallback: legacy)
        }
        #endif
        return legacy
    }

    #if os(macOS)
    static func platformAudioSession(_ hardware: AVAudioEngineHardware) -> any AudioSessionManaging {
        HostAudioSession(hardware: hardware)
    }
    #endif
}
#endif
