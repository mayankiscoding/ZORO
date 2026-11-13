import Foundation

/// Deterministic synthetic signals for DSP tests (no hardware, no randomness between runs).
enum Signals {
    static func sine(frequency: Double, amplitude: Float, sampleRate: Double, duration: TimeInterval, phase: Double = 0) -> [Float] {
        let n = Int(sampleRate * duration)
        return (0..<n).map { i in amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate + phase)) }
    }

    static func silence(sampleRate: Double, duration: TimeInterval) -> [Float] {
        [Float](repeating: 0, count: Int(sampleRate * duration))
    }

    /// Uniform noise in -amplitude...amplitude from a fixed-seed LCG.
    static func noise(amplitude: Float, sampleRate: Double, duration: TimeInterval, seed: UInt32 = 42) -> [Float] {
        var state = seed
        return (0..<Int(sampleRate * duration)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state) / Float(UInt32.max) * 2 - 1) * amplitude
        }
    }

    static func zeroCrossings(_ s: [Float]) -> Int {
        zip(s, s.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }
}
