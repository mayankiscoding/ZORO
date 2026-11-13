import CoreGraphics
import Foundation
import SwiftUI

/// Pure geometry for the orb: blob outlines, satellites, ripples and the error shake.
/// No randomness at draw time: every value is a function of (seed, time, parameters).
public enum OrbGeometry {
    /// More working agents than this are shown as this many satellites; VoiceOver still names all.
    public static let maxVisibleSatellites = 6

    /// Harmonics of the edge deformation field: (angular frequency, weight). Weights sum to 1, so
    /// the field stays within [-1, 1] and `deformation` is a true bound on the edge offset.
    static let harmonics: [(k: Double, weight: Double, speed: Double)] = [
        (2, 0.5, 1.0), (3, 0.3, -1.3), (5, 0.2, 1.7),
    ]

    /// Deterministic phases from a seed (SplitMix64).
    static func phases(seed: UInt64, count: Int) -> [Double] {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        return (0..<count).map { _ in
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z % 10_000) / 10_000 * 2 * .pi
        }
    }

    /// Smooth noise in [-1, 1] around the circle at angle `theta` and time `time`.
    public static func edgeNoise(theta: Double, time: Double, seed: UInt64, speed: Double) -> Double {
        let ph = phases(seed: seed, count: harmonics.count)
        var sum = 0.0
        for (i, h) in harmonics.enumerated() {
            sum += h.weight * sin(h.k * theta + ph[i] + h.speed * speed * time)
        }
        return sum
    }

    /// Breath factor (multiplier on radius) at `time`.
    public static func breath(time: Double, amplitude: Double, period: Double) -> Double {
        guard amplitude > 0, period > 0 else { return 1 }
        return 1 + amplitude * sin(2 * .pi * time / period)
    }

    /// Radius of the orb body for a frame size, parameters, time and audio level (0...1).
    public static func bodyRadius(size: CGSize, parameters p: OrbParameters, time: Double, level: Double) -> Double {
        let maxRadius = Double(min(size.width, size.height)) / 2 * 0.62
        let l = clampUnit(level)
        return maxRadius * p.scale * breath(time: time, amplitude: p.breathAmplitude, period: p.breathPeriod) * (1 + p.levelGain * l)
    }

    /// Points of one soft blob outline, evenly spaced in angle starting at 12 o'clock, clockwise in
    /// screen space. Every point lies within radius × (1 ± deformation).
    public static func blobPoints(
        center: CGPoint, radius: Double, count: Int, time: Double, seed: UInt64,
        deformation: Double, noiseSpeed: Double
    ) -> [CGPoint] {
        guard count >= 3, radius > 0 else { return [] }
        return (0..<count).map { i in
            let theta = -Double.pi / 2 + 2 * .pi * Double(i) / Double(count)
            let n = deformation == 0 ? 0 : edgeNoise(theta: theta, time: time, seed: seed, speed: noiseSpeed)
            let r = radius * (1 + deformation * n)
            return CGPoint(x: Double(center.x) + r * cos(theta), y: Double(center.y) + r * sin(theta))
        }
    }

    /// A closed Catmull-Rom spline through the points, as cubic Béziers.
    public static func smoothClosedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        let n = points.count
        guard n >= 3 else { return path }
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    /// Orbit radius for satellites: free-floating while delegating, docked on the rim while a tool runs.
    public static func satelliteOrbitRadius(mode: OrbSatelliteMode, bodyRadius: Double) -> Double {
        switch mode {
        case .hidden: 0
        case .orbiting: bodyRadius * 1.42
        case .docked: bodyRadius * 1.04
        }
    }

    /// Satellite centres, evenly spaced, first at 12 o'clock, turning slowly with time while orbiting.
    /// Docked satellites hold still. At most `maxVisibleSatellites`.
    public static func satellitePositions(
        count: Int, center: CGPoint, mode: OrbSatelliteMode, bodyRadius: Double, time: Double,
        turnsPerSecond: Double = 0.03
    ) -> [CGPoint] {
        let visible = min(max(count, 0), maxVisibleSatellites)
        guard visible > 0, mode != .hidden else { return [] }
        let orbit = satelliteOrbitRadius(mode: mode, bodyRadius: bodyRadius)
        let spin = mode == .orbiting ? 2 * .pi * turnsPerSecond * time : 0
        return (0..<visible).map { i in
            let a = -Double.pi / 2 + spin + 2 * .pi * Double(i) / Double(visible)
            return CGPoint(x: Double(center.x) + orbit * cos(a), y: Double(center.y) + orbit * sin(a))
        }
    }

    /// Satellite disc radius, shrinking slightly as more agents work.
    public static func satelliteRadius(bodyRadius: Double, count: Int) -> Double {
        let c = Double(min(max(count, 1), maxVisibleSatellites))
        return bodyRadius * (0.2 - 0.012 * (c - 1))
    }

    /// Listening ripples: progress values in [0, 1) for `count` rings, evenly staggered.
    public static func ripplePhases(time: Double, count: Int, period: Double = 2.4) -> [Double] {
        guard count > 0, period > 0 else { return [] }
        return (0..<count).map { i in
            let raw = time / period + Double(i) / Double(count)
            return raw - floor(raw)
        }
    }

    /// One damped horizontal shake after entering the error state; exactly 0 after `duration`.
    public static func shakeOffset(elapsed: Double, amplitude: Double, duration: Double = 0.45) -> Double {
        guard elapsed >= 0, elapsed < duration, duration > 0 else { return 0 }
        let t = elapsed / duration
        return amplitude * sin(t * 3 * 2 * .pi) * (1 - t)
    }

    /// Sweep progress (0...1) for the tool-execution ring.
    public static func sweepProgress(time: Double, period: Double = 1.6) -> Double {
        guard period > 0 else { return 0 }
        let raw = time / period
        return raw - floor(raw)
    }

    static func clampUnit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
}
