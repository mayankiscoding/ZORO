import Foundation
import Testing

@testable import AudioEngine

@Suite("PCM conversion")
struct PCMTests {
    @Test func encodesLittleEndianAndClamps() {
        let data = PCM16.encode([0, 1, -1, 2, -2, 0.5, .nan])
        #expect(Array(data) == [0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0xFF, 0x7F, 0x00, 0x80, 0x00, 0x40, 0x00, 0x00])
        #expect(PCM16.samples(data) == [0, 32767, -32768, 32767, -32768, 16384, 0])
    }

    @Test func roundTripsWithinOneStep() {
        let input = Signals.sine(frequency: 440, amplitude: 0.8, sampleRate: 16_000, duration: 0.05)
        let back = PCM16.decode(PCM16.encode(input))
        #expect(back.count == input.count)
        #expect(zip(input, back).allSatisfy { abs($0 - $1) <= 2.0 / 32_768 })
    }

    @Test func ignoresTrailingOddByteAndRebuildsData() {
        var data = PCM16.data([1, -2, 300])
        data.append(0x7F)
        #expect(PCM16.samples(data) == [1, -2, 300])
        #expect(PCM16.duration(byteCount: 32_000, sampleRate: 16_000) == 1)
    }

    @Test func downmixAveragesChannels() {
        #expect(Downmix.mono([[1, 0.5], [0, -0.5]]) == [0.5, 0])
        #expect(Downmix.mono([[0.25]]) == [0.25])
        #expect(Downmix.mono([]).isEmpty)
    }

    @Test func levelsMapDecibelsToUnitRange() {
        #expect(AudioLevel.dbfs([]) == AudioLevel.silenceDB)
        #expect(abs(AudioLevel.dbfs([1, -1, 1, -1])) < 0.001)
        #expect(AudioLevel.normalized(dbfs: -60) == 0)
        #expect(AudioLevel.normalized(dbfs: -30) == 0.5)
        #expect(AudioLevel.normalized(dbfs: 3) == 1)
        var meter = LevelMeter(attack: 1, release: 0.5)
        #expect(meter.update(0.8) == 0.8)
        #expect(meter.update(0) == 0.4)
    }
}

@Suite("Resampling")
struct ResamplerTests {
    @Test(arguments: [48_000.0, 44_100.0, 24_000.0, 8_000.0])
    func outputCountTracksRatioAcrossChunks(inputRate: Double) {
        var r = StreamingResampler(inputRate: inputRate, outputRate: 16_000)
        var total = 0
        var inputTotal = 0
        for size in [1024, 333, 4096, 17, 2048] {
            let chunk = Signals.sine(frequency: 300, amplitude: 0.5, sampleRate: inputRate, duration: Double(size) / inputRate)
            inputTotal += chunk.count
            total += r.process(chunk).count
        }
        let expected = Double(inputTotal) * 16_000 / inputRate
        #expect(abs(Double(total) - expected) <= 2)
    }

    @Test func preservesFrequencyWhenDownsampling() {
        var r = StreamingResampler(inputRate: 48_000, outputRate: 16_000)
        let input = Signals.sine(frequency: 1_000, amplitude: 0.5, sampleRate: 48_000, duration: 1)
        var out: [Float] = []
        for start in stride(from: 0, to: input.count, by: 960) {
            out += r.process(Array(input[start..<min(input.count, start + 960)]))
        }
        // 1 kHz for one second: about 2000 zero crossings at any sample rate.
        #expect(abs(Signals.zeroCrossings(out) - 2_000) <= 4)
    }

    @Test func attenuatesContentAboveTheNewNyquist() {
        var r = StreamingResampler(inputRate: 48_000, outputRate: 16_000)
        let tone = Signals.sine(frequency: 15_000, amplitude: 0.5, sampleRate: 48_000, duration: 0.5)
        let out = r.process(tone)
        // Without the low-pass this would alias to 1 kHz at full level.
        #expect(AudioLevel.rms(Array(out.dropFirst(200))) < 0.05)
    }

    @Test func passthroughAtSameRate() {
        var r = StreamingResampler(inputRate: 16_000, outputRate: 16_000)
        #expect(r.isPassthrough)
        #expect(r.process([0.1, 0.2]) == [0.1, 0.2])
    }

    @Test func captureProcessorProducesSixteenKilohertzMonoChunks() {
        var p = CaptureProcessor()
        let left = Signals.sine(frequency: 200, amplitude: 0.4, sampleRate: 48_000, duration: 0.1)
        let chunk = p.process(RawAudioBuffer(channels: [left, left], sampleRate: 48_000))
        #expect(abs(chunk.pcm16.count / 2 - 1_600) <= 1)
        #expect(abs(chunk.duration - 0.1) < 0.001)
        #expect(chunk.level > 0)
    }
}

@Suite("Voice activity detection")
struct VADTests {
    func run(_ samples: [Float], _ vad: inout VoiceActivityDetector) -> [(Int, VADEvent)] {
        var events: [(Int, VADEvent)] = []
        var frame = 0
        for start in stride(from: 0, to: samples.count, by: 320) {
            let slice = Array(samples[start..<min(samples.count, start + 320)])
            guard slice.count == 320 else { break }
            if let e = vad.process(frame: slice) { events.append((frame, e)) }
            frame += 1
        }
        return events
    }

    @Test func silenceProducesNoEvents() {
        var vad = VoiceActivityDetector()
        #expect(run(Signals.silence(sampleRate: 16_000, duration: 2), &vad).isEmpty)
        #expect(!vad.isSpeech)
    }

    @Test func speechStartsAfterDebounceAndEndsAfterHangover() {
        var vad = VoiceActivityDetector()
        let quiet = Signals.noise(amplitude: 0.002, sampleRate: 16_000, duration: 0.4)
        let speech = Signals.sine(frequency: 220, amplitude: 0.3, sampleRate: 16_000, duration: 1)
        let tail = Signals.noise(amplitude: 0.002, sampleRate: 16_000, duration: 1, seed: 7)
        let events = run(quiet + speech + tail, &vad)
        #expect(events.map(\.1) == [.speechStarted, .speechEnded])
        // 0.4 s of quiet = 20 frames; three voiced frames to start.
        #expect(events[0].0 == 20 + 2)
        // Speech ends 50 frames later; hangover is 30 frames (600 ms) of silence.
        #expect(events[1].0 == 20 + 50 + 29)
    }

    @Test func shortClickIsIgnored() {
        var vad = VoiceActivityDetector()
        let quiet = Signals.silence(sampleRate: 16_000, duration: 0.3)
        let click = Signals.sine(frequency: 1_000, amplitude: 0.9, sampleRate: 16_000, duration: 0.04)
        #expect(run(quiet + click + quiet, &vad).isEmpty)
    }

    @Test func steadyBackgroundNoiseIsLearnedNotTakenForSpeech() {
        var vad = VoiceActivityDetector()
        let fan = Signals.noise(amplitude: 0.02, sampleRate: 16_000, duration: 3)
        #expect(run(fan, &vad).isEmpty)
        #expect(vad.noiseFloorDB > -50)
        let voice = Signals.sine(frequency: 180, amplitude: 0.4, sampleRate: 16_000, duration: 0.5)
        #expect(run(voice, &vad).map(\.1) == [.speechStarted])
    }

    @Test func briefPauseInsideSpeechDoesNotEndIt() {
        var vad = VoiceActivityDetector()
        let quiet = Signals.silence(sampleRate: 16_000, duration: 0.2)
        let word = Signals.sine(frequency: 200, amplitude: 0.3, sampleRate: 16_000, duration: 0.4)
        let pause = Signals.silence(sampleRate: 16_000, duration: 0.3)
        let events = run(quiet + word + pause + word, &vad)
        #expect(events.map(\.1) == [.speechStarted])
    }

    @Test func arbitraryChunkSizesAreFramed() {
        var vad = VoiceActivityDetector()
        let signal = Signals.silence(sampleRate: 16_000, duration: 0.2) + Signals.sine(frequency: 200, amplitude: 0.3, sampleRate: 16_000, duration: 0.3)
        var events: [VADEvent] = []
        for start in stride(from: 0, to: signal.count, by: 1_365) {
            events += vad.process(samples: Array(signal[start..<min(signal.count, start + 1_365)]))
        }
        #expect(events == [.speechStarted])
    }
}

@Suite("Jitter buffer")
struct JitterBufferTests {
    @Test func holdsUntilPrebufferThenPlays() {
        var j = JitterBuffer(prebufferSamples: 100, capacitySamples: 1_000)
        j.push([Int16](repeating: 1, count: 60))
        #expect(j.pop(maxSamples: 50) == nil)
        #expect(j.state == .buffering)
        j.push([Int16](repeating: 2, count: 60))
        #expect(j.pop(maxSamples: 50)?.count == 50)
        #expect(j.state == .playing)
        #expect(j.pop(maxSamples: 100)?.count == 70)
        #expect(j.pop(maxSamples: 100) == nil)
    }

    @Test func endOfStreamReleasesShortTail() {
        var j = JitterBuffer(prebufferSamples: 100, capacitySamples: 1_000)
        j.push([1, 2, 3])
        #expect(j.pop(maxSamples: 10) == nil)
        j.markEnd()
        #expect(j.pop(maxSamples: 10) == [1, 2, 3])
        #expect(j.isDrained)
    }

    @Test func underrunReturnsToBuffering() {
        var j = JitterBuffer(prebufferSamples: 4, capacitySamples: 100)
        j.push([1, 2, 3, 4])
        #expect(j.pop(maxSamples: 10) == [1, 2, 3, 4])
        j.reportUnderrun()
        #expect(j.state == .buffering)
        #expect(j.underruns == 1)
        j.push([5, 6])
        #expect(j.pop(maxSamples: 10) == nil)
        j.push([7, 8])
        #expect(j.pop(maxSamples: 10) == [5, 6, 7, 8])
    }

    @Test func overflowDropsOldestAudio() {
        var j = JitterBuffer(prebufferSamples: 0, capacitySamples: 5)
        j.push([1, 2, 3, 4])
        j.push([5, 6, 7])
        #expect(j.droppedSamples == 2)
        #expect(j.pop(maxSamples: 10) == [3, 4, 5, 6, 7])
    }

    @Test func flushDropsEverythingAtOnce() {
        var j = JitterBuffer(sampleRate: 24_000, prebuffer: 0.1, capacity: 1)
        j.push([Int16](repeating: 9, count: 5_000))
        _ = j.pop(maxSamples: 960)
        j.markEnd()
        j.flush()
        #expect(j.count == 0)
        #expect(j.state == .buffering)
        #expect(!j.isEnded)
        #expect(j.pop(maxSamples: 960) == nil)
    }

    @Test func largeStreamsStayCompact() {
        var j = JitterBuffer(prebufferSamples: 0, capacitySamples: 10_000)
        var popped = 0
        for _ in 0..<500 {
            j.push([Int16](repeating: 1, count: 480))
            popped += j.pop(maxSamples: 480)?.count ?? 0
        }
        #expect(popped == 240_000)
        #expect(j.count == 0)
    }
}

@Suite("Audio recovery policy")
struct AudioRecoveryPolicyTests {
    @Test func mapsEveryEvent() {
        let p = AudioRecoveryPolicy.self
        #expect(p.action(for: .interruptionBegan, sessionActive: true) == .endSession)
        #expect(p.action(for: .interruptionEnded(shouldResume: true), sessionActive: true) == .none)
        #expect(p.action(for: .routeChanged(.oldDeviceUnavailable), sessionActive: true) == .stopPlayback)
        #expect(p.action(for: .routeChanged(.newDeviceAvailable), sessionActive: true) == .restartAudio)
        #expect(p.action(for: .routeChanged(.categoryChange), sessionActive: true) == .none)
        #expect(p.action(for: .mediaServicesReset, sessionActive: true) == .restartAudio)
        #expect(p.action(for: .engineConfigurationChanged, sessionActive: true) == .restartAudio)
        #expect(p.action(for: .interruptionBegan, sessionActive: false) == .none)
    }
}
