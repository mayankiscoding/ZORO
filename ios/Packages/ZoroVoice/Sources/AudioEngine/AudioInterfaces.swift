import Foundation

// MARK: - Errors

public enum AudioEngineError: Error, Sendable, Equatable, LocalizedError {
    case microphoneDenied
    case noInputDevice
    case engineFailed(String)
    case sessionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "ZORO can't use the microphone. Allow it in Settings, then tap the orb again."
        case .noInputDevice: "No microphone is available."
        case .engineFailed(let m): "Audio could not start: \(m)"
        case .sessionFailed(let m): "The audio session could not be set up: \(m)"
        }
    }
}

// MARK: - Buffers

/// Audio as delivered by the hardware: one array per channel, at the device's native rate.
public struct RawAudioBuffer: Sendable, Equatable {
    public var channels: [[Float]]
    public var sampleRate: Double
    public init(channels: [[Float]], sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
    }
    public init(mono: [Float], sampleRate: Double) {
        self.init(channels: [mono], sampleRate: sampleRate)
    }
}

/// Microphone audio after conversion: 16 kHz mono 16-bit PCM with its level and VAD result.
public struct CapturedChunk: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    public var pcm16: Data
    /// Smoothed 0...1 level for the orb.
    public var level: Float
    /// True while the detector is inside speech (after start debouncing, through the hangover).
    public var isSpeech: Bool
    public var vadEvents: [VADEvent]

    public init(pcm16: Data, level: Float, isSpeech: Bool, vadEvents: [VADEvent] = []) {
        self.pcm16 = pcm16
        self.level = level
        self.isSpeech = isSpeech
        self.vadEvents = vadEvents
    }

    public var duration: TimeInterval { PCM16.duration(byteCount: pcm16.count, sampleRate: Self.sampleRate) }
}

/// Pure conversion pipeline: downmix → resample to 16 kHz → level → VAD → Int16.
public struct CaptureProcessor: Sendable {
    public private(set) var vad: VoiceActivityDetector
    private var resampler: StreamingResampler?
    private var meter = LevelMeter()

    public init(vad: VADConfiguration = VADConfiguration()) {
        self.vad = VoiceActivityDetector(configuration: vad)
    }

    public mutating func process(_ buffer: RawAudioBuffer) -> CapturedChunk {
        let mono = Downmix.mono(buffer.channels)
        if resampler?.inputRate != buffer.sampleRate {
            resampler = StreamingResampler(inputRate: buffer.sampleRate, outputRate: CapturedChunk.sampleRate)
        }
        let samples = resampler!.process(mono)
        let events = vad.process(samples: samples)
        let level = meter.update(AudioLevel.normalized(dbfs: AudioLevel.dbfs(samples)))
        return CapturedChunk(pcm16: PCM16.encode(samples), level: level, isSpeech: vad.isSpeech, vadEvents: events)
    }

    public mutating func reset() {
        vad.reset()
        resampler?.reset()
        meter.reset()
    }
}

// MARK: - Hardware protocols

/// Microphone hardware. The handler runs on a real-time audio thread and must not block.
public protocol AudioInputHardware: Sendable {
    func startInput(_ handler: @escaping @Sendable (RawAudioBuffer) -> Void) async throws
    func stopInput() async
}

/// Speaker hardware playing mono Float32 at a fixed rate.
public protocol AudioOutputHardware: Sendable {
    func prepareOutput(sampleRate: Double) async throws
    /// Queues samples; `completion` fires once they played or were cleared.
    func schedule(_ samples: [Float], completion: @escaping @Sendable () -> Void) async
    /// Stops at once and drops everything queued.
    func stopOutput() async
}

/// Converted microphone capture.
public protocol AudioCapturing: Sendable {
    func start() async throws -> AsyncStream<CapturedChunk>
    func stop() async
}

/// Streaming PCM16 playback with jitter buffering and instant flush.
public protocol PCMStreaming: Sendable {
    func enqueue(_ pcm16: Data) async throws
    /// Marks the end of the reply and waits until it played (true) or was flushed (false).
    func finish() async -> Bool
    /// Barge-in: drops queued and playing audio immediately.
    func flush() async
    func levels() -> AsyncStream<Float>
}

// MARK: - Audio session (interruptions, routes, permission)

public enum RouteChangeReason: String, Sendable, Equatable {
    case newDeviceAvailable, oldDeviceUnavailable, categoryChange, override, other
}

public enum AudioSessionEvent: Sendable, Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(RouteChangeReason)
    case mediaServicesReset
    /// AVAudioEngine stopped itself because the hardware configuration changed.
    case engineConfigurationChanged
}

public enum MicrophoneAuthorization: String, Sendable, Equatable {
    case notDetermined, denied, granted
}

public protocol AudioSessionManaging: Sendable {
    func microphoneAuthorization() async -> MicrophoneAuthorization
    /// Shows the system prompt when not determined; call only from a user action.
    func requestMicrophoneAccess() async -> Bool
    /// Configures play-and-record for voice chat and activates it.
    func activate() async throws
    func deactivate() async
    func events() -> AsyncStream<AudioSessionEvent>
}

public enum AudioRecoveryAction: String, Sendable, Equatable {
    /// Phone call or Siri took the audio: stop the session, the owner starts again.
    case endSession
    /// Headphones went away: stop speaking so nothing blares from the speaker.
    case stopPlayback
    /// Hardware or the media server changed under the engine: rebuild capture.
    case restartAudio
    case none
}

/// What the voice session does for each audio-session event (pure, tested).
public enum AudioRecoveryPolicy {
    public static func action(for event: AudioSessionEvent, sessionActive: Bool) -> AudioRecoveryAction {
        guard sessionActive else { return .none }
        switch event {
        case .interruptionBegan: return .endSession
        // ZORO never resumes listening by itself after an interruption: no background listening.
        case .interruptionEnded: return .none
        case .routeChanged(.oldDeviceUnavailable): return .stopPlayback
        case .routeChanged(.newDeviceAvailable), .routeChanged(.override): return .restartAudio
        case .routeChanged: return .none
        case .mediaServicesReset, .engineConfigurationChanged: return .restartAudio
        }
    }
}

// MARK: - Broadcast

/// Fan-out of values to any number of AsyncStream subscribers (thread-safe, bounded per subscriber).
public final class Broadcaster<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var latest: Value?
    private let replayLatest: Bool
    private let bufferSize: Int

    public init(initial: Value? = nil, replayLatest: Bool = false, bufferSize: Int = 64) {
        self.latest = initial
        self.replayLatest = replayLatest
        self.bufferSize = bufferSize
    }

    public func subscribe() -> AsyncStream<Value> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        let replay: Value? = lock.withLock {
            continuations[id] = continuation
            return replayLatest ? latest : nil
        }
        if let replay { continuation.yield(replay) }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func yield(_ value: Value) {
        let targets = lock.withLock {
            latest = value
            return Array(continuations.values)
        }
        for c in targets { c.yield(value) }
    }

    public var value: Value? { lock.withLock { latest } }

    public func finish() {
        let targets = lock.withLock {
            let t = Array(continuations.values)
            continuations.removeAll()
            return t
        }
        for c in targets { c.finish() }
    }
}
