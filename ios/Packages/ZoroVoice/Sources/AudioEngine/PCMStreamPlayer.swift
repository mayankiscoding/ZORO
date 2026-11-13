import Foundation

/// Plays streamed 16-bit PCM (24 kHz from the realtime voice model) through a jitter buffer.
/// Audio is released to the hardware in short frames once the prebuffer is met; `flush()` stops the
/// hardware and drops everything at once for barge-in. Completions from flushed audio are ignored
/// through a generation counter.
public actor PCMStreamPlayer: PCMStreaming {
    public nonisolated let sampleRate: Double
    private let hardware: any AudioOutputHardware
    private let frameSamples: Int
    private var jitter: JitterBuffer
    private var prepared = false
    private var generation = 0
    private var outstandingFrames = 0
    private var drainWaiter: CheckedContinuation<Bool, Never>?
    private let levelBroadcaster = Broadcaster<Float>()
    private var meter = LevelMeter(attack: 0.7, release: 0.3)

    public init(
        hardware: any AudioOutputHardware, sampleRate: Double = 24_000, prebuffer: TimeInterval = 0.12,
        capacity: TimeInterval = 60, frameDuration: TimeInterval = 0.04
    ) {
        self.hardware = hardware
        self.sampleRate = sampleRate
        self.frameSamples = max(1, Int(sampleRate * frameDuration))
        self.jitter = JitterBuffer(sampleRate: sampleRate, prebuffer: prebuffer, capacity: capacity)
    }

    public nonisolated func levels() -> AsyncStream<Float> { levelBroadcaster.subscribe() }

    public var bufferState: JitterBuffer.State { jitter.state }
    public var underruns: Int { jitter.underruns }
    public var droppedSamples: Int { jitter.droppedSamples }
    public var bufferedSamples: Int { jitter.count }
    public var framesInFlight: Int { outstandingFrames }
    var isAwaitingDrain: Bool { drainWaiter != nil }

    public func enqueue(_ pcm16: Data) async throws {
        if !prepared {
            try await hardware.prepareOutput(sampleRate: sampleRate)
            prepared = true
        }
        jitter.push(PCM16.samples(pcm16))
        await pump()
    }

    public func finish() async -> Bool {
        jitter.markEnd()
        await pump()
        if outstandingFrames == 0, jitter.count == 0 {
            emitSilence()
            return true
        }
        drainWaiter?.resume(returning: false)
        return await withCheckedContinuation { drainWaiter = $0 }
    }

    public func flush() async {
        generation += 1
        jitter.flush()
        outstandingFrames = 0
        await hardware.stopOutput()
        emitSilence()
        drainWaiter?.resume(returning: false)
        drainWaiter = nil
    }

    private func pump() async {
        while let frame = jitter.pop(maxSamples: frameSamples) {
            let floats = PCM16.toFloat(frame)
            levelBroadcaster.yield(meter.update(AudioLevel.normalized(dbfs: AudioLevel.dbfs(floats))))
            outstandingFrames += 1
            let gen = generation
            await hardware.schedule(floats) { [weak self] in
                guard let self else { return }
                Task { await self.framePlayed(generation: gen) }
            }
        }
    }

    private func framePlayed(generation gen: Int) async {
        guard gen == generation, outstandingFrames > 0 else { return }
        outstandingFrames -= 1
        guard outstandingFrames == 0 else { return }
        if jitter.isDrained || (jitter.isEnded && jitter.count == 0) {
            emitSilence()
            drainWaiter?.resume(returning: true)
            drainWaiter = nil
        } else if jitter.count == 0 {
            jitter.reportUnderrun()
        } else {
            await pump()
        }
    }

    private func emitSilence() {
        meter.reset()
        levelBroadcaster.yield(0)
    }
}
