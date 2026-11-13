import Foundation
import Testing

@testable import AudioEngine

/// Speaker fake: records scheduled frames; the test decides when they "finish playing".
actor FakeOutput: AudioOutputHardware {
    var preparedRates: [Double] = []
    var scheduled: [[Float]] = []
    var completions: [@Sendable () -> Void] = []
    var stops = 0

    func prepareOutput(sampleRate: Double) async throws { preparedRates.append(sampleRate) }
    func schedule(_ samples: [Float], completion: @escaping @Sendable () -> Void) async {
        scheduled.append(samples)
        completions.append(completion)
    }
    func stopOutput() async {
        stops += 1
        let pending = completions
        completions.removeAll()
        pending.forEach { $0() }
    }
    func playAll() {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0() }
    }
}

/// Microphone fake: the test pushes buffers through the installed handler.
final class FakeInput: AudioInputHardware, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (RawAudioBuffer) -> Void)?
    private(set) var stops = 0
    var failWith: Error?

    func startInput(_ handler: @escaping @Sendable (RawAudioBuffer) -> Void) async throws {
        if let failWith { throw failWith }
        lock.withLock { self.handler = handler }
    }
    func stopInput() async { lock.withLock { stops += 1; handler = nil } }
    func push(_ buffer: RawAudioBuffer) { lock.withLock { handler }?(buffer) }
}

func eventually(_ timeout: TimeInterval = 2, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

@Suite("Streaming playback")
struct PlayerTests {
    func pcm(_ seconds: TimeInterval, rate: Double = 24_000) -> Data {
        PCM16.encode(Signals.sine(frequency: 300, amplitude: 0.5, sampleRate: rate, duration: seconds))
    }

    @Test func waitsForPrebufferThenSchedulesFrames() async throws {
        let out = FakeOutput()
        let player = PCMStreamPlayer(hardware: out, sampleRate: 24_000, prebuffer: 0.1, frameDuration: 0.02)
        try await player.enqueue(pcm(0.05))
        #expect(await out.scheduled.isEmpty)
        #expect(await out.preparedRates == [24_000])
        try await player.enqueue(pcm(0.06))
        // 0.11 s at 24 kHz = 2640 samples → five 480-sample frames + 240.
        #expect(await out.scheduled.map(\.count) == [480, 480, 480, 480, 480, 240])
        #expect(await player.bufferState == .playing)
    }

    @Test func finishWaitsUntilPlayedOut() async throws {
        let out = FakeOutput()
        let player = PCMStreamPlayer(hardware: out, prebuffer: 0.05)
        try await player.enqueue(pcm(0.03))
        let finished = Task { await player.finish() }
        #expect(await eventually { await out.scheduled.count > 0 })
        await out.playAll()
        #expect(await finished.value == true)
    }

    @Test func flushStopsHardwareAndAbandonsWaiter() async throws {
        let out = FakeOutput()
        let player = PCMStreamPlayer(hardware: out, prebuffer: 0.01)
        try await player.enqueue(pcm(0.5))
        let finished = Task { await player.finish() }
        #expect(await eventually { await player.isAwaitingDrain })
        await player.flush()
        #expect(await finished.value == false)
        #expect(await out.stops == 1)
        #expect(await player.bufferedSamples == 0)
        #expect(await player.framesInFlight == 0)
        // A new reply after the flush plays normally.
        try await player.enqueue(pcm(0.05))
        #expect(await player.framesInFlight > 0)
    }

    @Test func outputLevelsFollowAudio() async throws {
        let out = FakeOutput()
        let player = PCMStreamPlayer(hardware: out, prebuffer: 0)
        let levels = player.levels()
        try await player.enqueue(pcm(0.04))
        var iterator = levels.makeAsyncIterator()
        let first = await iterator.next()
        #expect((first ?? 0) > 0.3)
    }

    @Test func underrunRebuffers() async throws {
        let out = FakeOutput()
        let player = PCMStreamPlayer(hardware: out, prebuffer: 0.02)
        try await player.enqueue(pcm(0.02))
        await out.playAll()
        #expect(await eventually { await player.underruns == 1 })
        #expect(await player.bufferState == .buffering)
    }
}

@Suite("Microphone capture")
struct CaptureTests {
    @Test func convertsHardwareBuffersIntoChunks() async throws {
        let input = FakeInput()
        let capture = MicrophoneCapture(hardware: input)
        let chunks = try await capture.start()
        let tone = Signals.sine(frequency: 200, amplitude: 0.3, sampleRate: 48_000, duration: 0.1)
        for _ in 0..<5 { input.push(RawAudioBuffer(mono: tone, sampleRate: 48_000)) }
        var received: [CapturedChunk] = []
        for await chunk in chunks {
            received.append(chunk)
            if received.count == 5 { break }
        }
        #expect(received.allSatisfy { abs($0.pcm16.count / 2 - 1_600) <= 1 })
        #expect(received.flatMap(\.vadEvents).contains(.speechStarted))
        #expect(received.last?.isSpeech == true)
        await capture.stop()
        #expect(input.stops == 1)
    }

    @Test func startFailurePropagates() async {
        let input = FakeInput()
        input.failWith = AudioEngineError.noInputDevice
        let capture = MicrophoneCapture(hardware: input)
        await #expect(throws: AudioEngineError.noInputDevice) { _ = try await capture.start() }
    }

    @Test func broadcasterReplaysLatestAndFansOut() async {
        let b = Broadcaster<Int>(initial: 1, replayLatest: true)
        let s1 = b.subscribe()
        b.yield(2)
        let s2 = b.subscribe()
        b.finish()
        var a: [Int] = []
        for await v in s1 { a.append(v) }
        var c: [Int] = []
        for await v in s2 { c.append(v) }
        #expect(a == [1, 2])
        #expect(c == [2])
    }
}
