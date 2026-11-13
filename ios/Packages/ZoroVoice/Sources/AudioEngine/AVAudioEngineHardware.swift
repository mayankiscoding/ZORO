#if canImport(AVFAudio)
import AVFAudio
import Foundation

/// Microphone and speaker on one AVAudioEngine, so the voice-processing I/O unit can cancel the
/// assistant's own speech from the microphone (echo cancellation, noise suppression, AGC).
/// Compiles on macOS and iOS; it touches hardware, so tests use fakes instead.
public final class AVAudioEngineHardware: AudioInputHardware, AudioOutputHardware, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var playerFormat: AVAudioFormat?
    private var inputActive = false
    private var configObserver: NSObjectProtocol?
    private let events = Broadcaster<AudioSessionEvent>()
    public let voiceProcessing: Bool

    public init(voiceProcessing: Bool = true) {
        self.voiceProcessing = voiceProcessing
        engine.attach(player)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.events.yield(.engineConfigurationChanged)
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
    }

    /// Engine configuration changes (device switched, sample rate changed).
    public func configurationEvents() -> AsyncStream<AudioSessionEvent> { events.subscribe() }

    // MARK: Input

    public func startInput(_ handler: @escaping @Sendable (RawAudioBuffer) -> Void) async throws {
        try lock.withLock {
            let input = engine.inputNode
            if voiceProcessing, !input.isVoiceProcessingEnabled {
                // Unsupported on some routes; capture still works without it.
                try? input.setVoiceProcessingEnabled(true)
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioEngineError.noInputDevice }
            input.removeTap(onBus: 0)
            let rate = format.sampleRate
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                handler(Self.raw(buffer, sampleRate: rate))
            }
            inputActive = true
            try startEngineLocked()
        }
    }

    public func stopInput() async {
        lock.withLock {
            engine.inputNode.removeTap(onBus: 0)
            inputActive = false
            if !player.isPlaying { engine.stop() }
        }
    }

    // MARK: Output

    public func prepareOutput(sampleRate: Double) async throws {
        try lock.withLock {
            if playerFormat?.sampleRate != sampleRate {
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
                    throw AudioEngineError.engineFailed("unsupported output format")
                }
                engine.disconnectNodeOutput(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                playerFormat = format
            }
            try startEngineLocked()
            if !player.isPlaying { player.play() }
        }
    }

    public func schedule(_ samples: [Float], completion: @escaping @Sendable () -> Void) async {
        let buffer: AVAudioPCMBuffer? = lock.withLock {
            guard let format = playerFormat,
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                let channel = buffer.floatChannelData?[0]
            else { return nil }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
            }
            if engine.isRunning, !player.isPlaying { player.play() }
            return buffer
        }
        guard let buffer else {
            completion()
            return
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
    }

    public func stopOutput() async {
        lock.withLock {
            // Stopping the node drops every scheduled buffer at once (barge-in).
            player.stop()
            if !inputActive { engine.stop() }
        }
    }

    // MARK: Helpers

    private func startEngineLocked() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioEngineError.engineFailed(error.localizedDescription)
        }
    }

    private static func raw(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> RawAudioBuffer {
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData, frames > 0 else { return RawAudioBuffer(channels: [], sampleRate: sampleRate) }
        var channels: [[Float]] = []
        if buffer.format.isInterleaved {
            let p = data[0]
            for c in 0..<count {
                channels.append((0..<frames).map { p[$0 * count + c] })
            }
        } else {
            for c in 0..<count {
                channels.append(Array(UnsafeBufferPointer(start: data[c], count: frames)))
            }
        }
        return RawAudioBuffer(channels: channels, sampleRate: sampleRate)
    }
}

/// Microphone permission through AVAudioApplication (iOS 17+, macOS 14+).
public enum SystemMicrophonePermission {
    public static func status() -> MicrophoneAuthorization {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    public static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

#if os(macOS)
/// macOS has no AVAudioSession: permission through AVAudioApplication, events from the engine.
public struct HostAudioSession: AudioSessionManaging {
    private let hardware: AVAudioEngineHardware
    public init(hardware: AVAudioEngineHardware) { self.hardware = hardware }
    public func microphoneAuthorization() async -> MicrophoneAuthorization { SystemMicrophonePermission.status() }
    public func requestMicrophoneAccess() async -> Bool { await SystemMicrophonePermission.request() }
    public func activate() async throws {}
    public func deactivate() async {}
    public func events() -> AsyncStream<AudioSessionEvent> { hardware.configurationEvents() }
}
#endif
#endif
