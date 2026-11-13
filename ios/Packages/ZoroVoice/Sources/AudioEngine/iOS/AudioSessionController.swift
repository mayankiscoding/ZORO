// UNVERIFIED-ON-HOST
// AVAudioSession exists only on iOS; this file is not compiled on the macOS host.
// Checked against developer.apple.com: AVAudioSession.setCategory(_:mode:options:), .playAndRecord,
// .voiceChat, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, setActive(_:options:),
// .notifyOthersOnDeactivation, interruptionNotification (AVAudioSessionInterruptionTypeKey,
// AVAudioSessionInterruptionOptionKey), routeChangeNotification (AVAudioSessionRouteChangeReasonKey),
// mediaServicesWereResetNotification.
#if os(iOS)
import AVFAudio
import Foundation

/// Play-and-record voice-chat session with interruption and route-change events.
public final class AudioSessionController: AudioSessionManaging, @unchecked Sendable {
    private let session = AVAudioSession.sharedInstance()
    private let broadcaster = Broadcaster<AudioSessionEvent>()
    private let hardware: AVAudioEngineHardware?
    private var observers: [NSObjectProtocol] = []
    private var forwardTask: Task<Void, Never>?

    public init(hardware: AVAudioEngineHardware? = nil) {
        self.hardware = hardware
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [broadcaster] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            switch type {
            case .began:
                broadcaster.yield(.interruptionBegan)
            case .ended:
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                broadcaster.yield(.interruptionEnded(shouldResume: opts.contains(.shouldResume)))
            @unknown default:
                break
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [broadcaster] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason: RouteChangeReason
            switch AVAudioSession.RouteChangeReason(rawValue: raw) {
            case .newDeviceAvailable: reason = .newDeviceAvailable
            case .oldDeviceUnavailable: reason = .oldDeviceUnavailable
            case .categoryChange: reason = .categoryChange
            case .override: reason = .override
            default: reason = .other
            }
            broadcaster.yield(.routeChanged(reason))
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [broadcaster] _ in
            broadcaster.yield(.mediaServicesReset)
        })
        if let hardware {
            let stream = hardware.configurationEvents()
            forwardTask = Task { [broadcaster] in
                for await event in stream { broadcaster.yield(event) }
            }
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        forwardTask?.cancel()
    }

    public func microphoneAuthorization() async -> MicrophoneAuthorization { SystemMicrophonePermission.status() }
    public func requestMicrophoneAccess() async -> Bool { await SystemMicrophonePermission.request() }

    public func activate() async throws {
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            throw AudioEngineError.sessionFailed(error.localizedDescription)
        }
    }

    public func deactivate() async {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    public func events() -> AsyncStream<AudioSessionEvent> { broadcaster.subscribe() }
}
#endif
