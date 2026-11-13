import Foundation

/// Signed 16-bit little-endian PCM, the wire format of the speech recogniser input (16 kHz) and the
/// realtime voice model (16 kHz in, 24 kHz out).
public enum PCM16 {
    /// Clamps to -1...1 and scales to Int16 (little-endian).
    public static func encode(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                let clamped = max(-1, min(1, s.isFinite ? s : 0))
                let scaled = clamped < 0 ? clamped * 32768 : clamped * 32767
                out[i] = Int16(scaled.rounded()).littleEndian
            }
        }
        return data
    }

    /// Int16 samples of a little-endian buffer; a trailing odd byte is ignored.
    public static func samples(_ data: Data) -> [Int16] {
        let count = data.count / 2
        var out = [Int16](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let lo = UInt16(raw[2 * i])
                let hi = UInt16(raw[2 * i + 1])
                out[i] = Int16(bitPattern: lo | (hi << 8))
            }
        }
        return out
    }

    public static func data(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let u = UInt16(bitPattern: s)
            data.append(UInt8(u & 0xFF))
            data.append(UInt8(u >> 8))
        }
        return data
    }

    public static func toFloat(_ samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32768 }
    }

    public static func decode(_ data: Data) -> [Float] {
        toFloat(samples(data))
    }

    public static func duration(byteCount: Int, sampleRate: Double) -> TimeInterval {
        sampleRate > 0 ? Double(byteCount / 2) / sampleRate : 0
    }
}

/// Loudness helpers shared by the orb level streams and the voice activity detector.
public enum AudioLevel {
    public static let silenceDB: Float = -100

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func dbfs(rms: Float) -> Float {
        rms > 0 ? max(silenceDB, 20 * log10(rms)) : silenceDB
    }

    public static func dbfs(_ samples: [Float]) -> Float { dbfs(rms: rms(samples)) }

    /// Maps dBFS to 0...1 linearly between `floorDB` and 0 dBFS.
    public static func normalized(dbfs: Float, floorDB: Float = -60) -> Float {
        guard dbfs > floorDB else { return 0 }
        return min(1, (dbfs - floorDB) / -floorDB)
    }
}

/// Attack/release smoothing so the orb moves smoothly instead of flickering per buffer.
public struct LevelMeter: Sendable, Equatable {
    public var attack: Float
    public var release: Float
    public private(set) var value: Float = 0

    public init(attack: Float = 0.6, release: Float = 0.25) {
        self.attack = attack
        self.release = release
    }

    public mutating func update(_ target: Float) -> Float {
        let t = max(0, min(1, target))
        let k = t > value ? attack : release
        value += (t - value) * k
        if value < 0.001 { value = 0 }
        return value
    }

    public mutating func reset() { value = 0 }
}

/// Averages channels into one.
public enum Downmix {
    public static func mono(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let n = channels.map(\.count).min() ?? 0
        var out = [Float](repeating: 0, count: n)
        let scale = 1 / Float(channels.count)
        for ch in channels {
            for i in 0..<n { out[i] += ch[i] * scale }
        }
        return out
    }
}

/// RBJ biquad low-pass with state carried across buffers.
struct Biquad: Sendable, Equatable {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(lowPassCutoff fc: Double, sampleRate fs: Double, q: Double = 0.7071) {
        let w0 = 2 * Double.pi * min(fc, fs * 0.49) / fs
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        b0 = Float((1 - cosw) / 2 / a0)
        b1 = Float((1 - cosw) / a0)
        b2 = b0
        a1 = Float(-2 * cosw / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ input: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: input.count)
        for (i, x) in input.enumerated() {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            out[i] = y
        }
        return out
    }
}

/// Streaming sample-rate converter: anti-alias low-pass (two cascaded biquads when downsampling)
/// followed by linear interpolation. Phase is carried across buffers, so chunk boundaries do not click
/// and the long-run output count matches `input * outputRate / inputRate`.
public struct StreamingResampler: Sendable, Equatable {
    public let inputRate: Double
    public let outputRate: Double
    private let step: Double
    private var position: Double = 0
    private var last: Float?
    private var filters: [Biquad]

    public init(inputRate: Double, outputRate: Double) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.step = inputRate / outputRate
        if inputRate > outputRate {
            let cutoff = outputRate * 0.45
            filters = [Biquad(lowPassCutoff: cutoff, sampleRate: inputRate), Biquad(lowPassCutoff: cutoff, sampleRate: inputRate)]
        } else {
            filters = []
        }
    }

    public var isPassthrough: Bool { inputRate == outputRate }

    public mutating func process(_ input: [Float]) -> [Float] {
        guard !isPassthrough else { return input }
        guard !input.isEmpty else { return [] }
        var filtered = input
        for i in filters.indices { filtered = filters[i].process(filtered) }
        let x: [Float] = last.map { [$0] + filtered } ?? filtered
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 2)
        let lastIndex = Double(x.count - 1)
        while position <= lastIndex {
            let i = Int(position)
            let frac = Float(position - Double(i))
            let a = x[i]
            let b = i + 1 < x.count ? x[i + 1] : a
            out.append(a + (b - a) * frac)
            position += step
        }
        position -= lastIndex
        last = x.last
        return out
    }

    public mutating func reset() {
        position = 0
        last = nil
        if inputRate > outputRate {
            let cutoff = outputRate * 0.45
            filters = [Biquad(lowPassCutoff: cutoff, sampleRate: inputRate), Biquad(lowPassCutoff: cutoff, sampleRate: inputRate)]
        }
    }
}
