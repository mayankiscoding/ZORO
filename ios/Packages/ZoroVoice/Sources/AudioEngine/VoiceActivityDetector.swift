import Foundation

public enum VADEvent: String, Sendable, Equatable {
    case speechStarted
    case speechEnded
}

public struct VADConfiguration: Sendable, Equatable {
    /// Frame length the detector expects, in samples (20 ms at 16 kHz = 320).
    public var frameSamples: Int
    public var sampleRate: Double
    /// A frame counts as voiced when it is this many dB above the tracked noise floor...
    public var startMarginDB: Float
    /// ...and, while speech continues, this many dB above it (hysteresis).
    public var continueMarginDB: Float
    /// ...and never quieter than this absolute level.
    public var minimumSpeechDB: Float
    /// Consecutive voiced frames before `speechStarted` (rejects clicks).
    public var startFrames: Int
    /// Consecutive unvoiced frames before `speechEnded` (the hangover).
    public var hangoverFrames: Int
    /// How fast the noise floor follows rising background noise, per frame (0...1).
    public var noiseRiseRate: Float
    /// Opening frames that only measure the room (no events), so steady noise is not taken for speech.
    public var calibrationFrames: Int
    public var maxCalibratedFloorDB: Float = -35

    public init(
        frameSamples: Int = 320, sampleRate: Double = 16_000, startMarginDB: Float = 12, continueMarginDB: Float = 8,
        minimumSpeechDB: Float = -50, startFrames: Int = 3, hangoverFrames: Int = 30, noiseRiseRate: Float = 0.02,
        calibrationFrames: Int = 5
    ) {
        self.calibrationFrames = calibrationFrames
        self.frameSamples = frameSamples
        self.sampleRate = sampleRate
        self.startMarginDB = startMarginDB
        self.continueMarginDB = continueMarginDB
        self.minimumSpeechDB = minimumSpeechDB
        self.startFrames = startFrames
        self.hangoverFrames = hangoverFrames
        self.noiseRiseRate = noiseRiseRate
    }

    public var frameDuration: TimeInterval { Double(frameSamples) / sampleRate }
    /// 600 ms of trailing silence ends an utterance by default (30 x 20 ms).
    public var hangoverDuration: TimeInterval { Double(hangoverFrames) * frameDuration }
}

/// Energy-based voice activity detection with an adaptive noise floor, start debouncing and hangover.
/// Pure and deterministic: feed it frames of `frameSamples` samples.
public struct VoiceActivityDetector: Sendable, Equatable {
    public let configuration: VADConfiguration
    public private(set) var isSpeech = false
    public private(set) var noiseFloorDB: Float
    private var voicedRun = 0
    private var silentRun = 0
    private var pending: [Float] = []
    private var calibrated = 0
    private var calibrationSum: Float = 0

    public init(configuration: VADConfiguration = VADConfiguration(), initialNoiseFloorDB: Float = -70) {
        self.configuration = configuration
        self.noiseFloorDB = initialNoiseFloorDB
    }

    /// Classifies one frame.
    public mutating func process(frame: [Float]) -> VADEvent? {
        let db = AudioLevel.dbfs(frame)
        if calibrated < configuration.calibrationFrames {
            calibrated += 1
            calibrationSum += db
            // Capped, so an owner who starts talking at once is not learned as "noise".
            noiseFloorDB = max(-90, min(configuration.maxCalibratedFloorDB, calibrationSum / Float(calibrated)))
            return nil
        }
        let margin = isSpeech ? configuration.continueMarginDB : configuration.startMarginDB
        let threshold = max(noiseFloorDB + margin, configuration.minimumSpeechDB)
        let voiced = db > threshold

        if !isSpeech {
            adaptNoiseFloor(db, voiced: voiced)
        } else {
            // Very slow drift during speech, so a noise that starts mid-utterance cannot hold it open forever.
            noiseFloorDB = min(-20, noiseFloorDB + (db - noiseFloorDB) * configuration.noiseRiseRate * 0.05)
        }

        if voiced {
            voicedRun += 1
            silentRun = 0
        } else {
            silentRun += 1
            voicedRun = 0
        }
        if !isSpeech, voicedRun >= configuration.startFrames {
            isSpeech = true
            return .speechStarted
        }
        if isSpeech, silentRun >= configuration.hangoverFrames {
            isSpeech = false
            return .speechEnded
        }
        return nil
    }

    /// Splits arbitrary-length audio into frames (remainder kept for the next call).
    public mutating func process(samples: [Float]) -> [VADEvent] {
        pending.append(contentsOf: samples)
        var events: [VADEvent] = []
        let n = configuration.frameSamples
        var start = 0
        while pending.count - start >= n {
            if let e = process(frame: Array(pending[start..<(start + n)])) { events.append(e) }
            start += n
        }
        pending.removeFirst(start)
        return events
    }

    /// Clears speech state; the learned noise floor is kept (same room).
    public mutating func reset() {
        isSpeech = false
        voicedRun = 0
        silentRun = 0
        pending = []
    }

    private mutating func adaptNoiseFloor(_ db: Float, voiced: Bool) {
        if db < noiseFloorDB {
            // Falls quickly: quiet frames are reliable evidence of the floor.
            noiseFloorDB += (db - noiseFloorDB) * 0.5
        } else if !voiced {
            noiseFloorDB += (db - noiseFloorDB) * configuration.noiseRiseRate
        } else {
            // Loud but not yet speech: creep up very slowly so constant noise (a fan) is learned.
            noiseFloorDB += (db - noiseFloorDB) * configuration.noiseRiseRate * 0.1
        }
        noiseFloorDB = max(-90, min(-20, noiseFloorDB))
    }
}
