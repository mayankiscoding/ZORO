import Foundation

/// Playout buffer for streamed speech. Holds back playback until `prebufferSamples` have arrived
/// (or the stream ended), returns to buffering after an underrun, bounds memory by dropping the oldest
/// audio, and empties instantly on `flush()` (barge-in).
public struct JitterBuffer: Sendable, Equatable {
    public enum State: String, Sendable { case buffering, playing }

    public let prebufferSamples: Int
    public let capacitySamples: Int
    public private(set) var state: State = .buffering
    public private(set) var isEnded = false
    public private(set) var droppedSamples = 0
    public private(set) var underruns = 0
    private var storage: [Int16] = []
    private var head = 0

    public init(prebufferSamples: Int, capacitySamples: Int) {
        self.prebufferSamples = max(0, prebufferSamples)
        self.capacitySamples = max(prebufferSamples, capacitySamples, 1)
    }

    public init(sampleRate: Double, prebuffer: TimeInterval = 0.12, capacity: TimeInterval = 30) {
        self.init(prebufferSamples: Int(sampleRate * prebuffer), capacitySamples: Int(sampleRate * capacity))
    }

    public var count: Int { storage.count - head }
    public var isDrained: Bool { isEnded && count == 0 }

    public mutating func push(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        if isEnded { isEnded = false }
        storage.append(contentsOf: samples)
        let overflow = count - capacitySamples
        if overflow > 0 {
            head += overflow
            droppedSamples += overflow
        }
        compactIfNeeded()
    }

    /// No more audio for this reply: whatever is buffered may play even below the prebuffer target.
    public mutating func markEnd() { isEnded = true }

    /// Up to `maxSamples` ready to play, or nil while buffering / empty.
    public mutating func pop(maxSamples: Int) -> [Int16]? {
        if state == .buffering {
            guard count > 0, count >= prebufferSamples || isEnded else { return nil }
            state = .playing
        }
        guard count > 0, maxSamples > 0 else { return nil }
        let n = min(maxSamples, count)
        let out = Array(storage[head..<(head + n)])
        head += n
        compactIfNeeded()
        return out
    }

    /// The output ran dry before the stream ended: build up the prebuffer again.
    public mutating func reportUnderrun() {
        guard state == .playing, !isEnded else { return }
        state = .buffering
        underruns += 1
    }

    /// Drops everything immediately and starts a fresh stream.
    public mutating func flush() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        state = .buffering
        isEnded = false
    }

    private mutating func compactIfNeeded() {
        if head > 0, head >= storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
    }
}
