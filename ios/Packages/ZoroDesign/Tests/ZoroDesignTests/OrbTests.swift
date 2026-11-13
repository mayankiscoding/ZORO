import CoreGraphics
import Foundation
import Testing
@testable import ZoroDesign

@Suite("Orb parameters")
struct OrbParameterTests {
    @Test("every state has its own parameter set")
    func statesAreDistinct() {
        let all = OrbState.allCases.map { OrbParameters.forState($0) }
        #expect(Set(all).count == OrbState.allCases.count)
    }

    @Test("idle breathes slowly and is not reactive to sound")
    func idle() {
        let p = OrbParameters.forState(.idle)
        #expect(p.breathAmplitude > 0)
        #expect(p.breathPeriod >= 3)
        #expect(p.levelGain == 0)
        #expect(p.satellites == .hidden)
        #expect(p.arc == .none && p.ring == .none)
    }

    @Test("listening opens and ripples with the owner's voice")
    func listening() {
        let idle = OrbParameters.forState(.idle), p = OrbParameters.forState(.listening)
        #expect(p.scale > idle.scale)
        #expect(p.levelGain > 0)
        #expect(p.ripples)
    }

    @Test("processing turns an iridescent arc")
    func processing() {
        let p = OrbParameters.forState(.processing)
        #expect(p.arc == .turning)
        #expect(p.iridescence == 1)
        #expect(p.rotationSpeed > OrbParameters.forState(.idle).rotationSpeed)
    }

    @Test("delegating orbits satellites; tool execution docks them and sweeps a ring")
    func agents() {
        #expect(OrbParameters.forState(.delegating).satellites == .orbiting)
        let tool = OrbParameters.forState(.toolExecution)
        #expect(tool.satellites == .docked)
        #expect(tool.arc == .sweep)
    }

    @Test("speaking is marigold-warm and follows ZORO's voice")
    func speaking() {
        let p = OrbParameters.forState(.speaking)
        #expect(p.warmth >= 0.5)
        #expect(p.levelGain > 0)
        #expect(OrbState.allCases.filter { OrbParameters.forState($0).warmth > 0 } == [.speaking])
    }

    @Test("error is lac-tinted and shakes once")
    func error() {
        let p = OrbParameters.forState(.error)
        #expect(p.alarm > 0.5)
        #expect(p.shake)
        #expect(OrbState.allCases.filter { OrbParameters.forState($0).alarm > 0 } == [.error])
    }

    @Test("private mode is moonstone, sealed, with no iridescence")
    func privateMode() {
        let p = OrbParameters.forState(.privateOffline)
        #expect(p.palette == .moonstone)
        #expect(p.ring == .sealed)
        #expect(p.iridescence == 0)
        #expect(p.rotationSpeed == 0)
        #expect(OrbState.allCases.filter { OrbParameters.forState($0).ring == .sealed } == [.privateOffline])
    }

    @Test("Reduce Motion removes deformation and travel in every state; sound becomes opacity", arguments: OrbState.allCases)
    func reduceMotion(state: OrbState) {
        let p = OrbParameters.forState(state, reduceMotion: true)
        #expect(p.deformation == 0)
        #expect(p.breathAmplitude == 0)
        #expect(p.noiseSpeed == 0)
        #expect(p.rotationSpeed == 0)
        #expect(p.levelGain == 0)
        #expect(!p.ripples && !p.shake)
        let full = OrbParameters.forState(state)
        if full.levelGain > 0 { #expect(p.levelOpacityGain > 0) }
        // Identity of the state survives: palette, ring, arc, satellites, tint.
        #expect(p.palette == full.palette && p.ring == full.ring && p.arc == full.arc)
        #expect(p.satellites == full.satellites && p.warmth == full.warmth && p.alarm == full.alarm)
    }

    @Test("every parameter stays in range", arguments: OrbState.allCases)
    func ranges(state: OrbState) {
        let p = OrbParameters.forState(state)
        #expect((0.5...1).contains(p.scale))
        #expect((0...0.1).contains(p.deformation))
        #expect((0...1).contains(p.iridescence))
        #expect((0...1).contains(p.warmth))
        #expect((0...1).contains(p.alarm))
        // Body + deformation + breath + full level never leaves the frame's safe radius.
        #expect(p.scale * (1 + p.breathAmplitude) * (1 + p.levelGain) * (1 + p.deformation) <= 1.2)
    }

    @Test("VoiceOver value per state, naming working agents")
    func accessibility() {
        let values = OrbState.allCases.map(\.accessibilityValue)
        #expect(Set(values).count == values.count)
        #expect(values.allSatisfy { !$0.isEmpty })
        let sats = [OrbSatellite(id: "s", name: "Shopping", symbol: "basket"), OrbSatellite(id: "f", name: "Finance", symbol: "indianrupeesign")]
        let v = OrbAccessibility.value(state: .delegating, satellites: sats)
        #expect(v.contains("Shopping") && v.contains("Finance"))
        #expect(OrbAccessibility.value(state: .idle, satellites: sats) == OrbState.idle.accessibilityValue)
        #expect(OrbAccessibility.value(state: .delegating, satellites: []) == OrbState.delegating.accessibilityValue)
    }
}

@Suite("Orb frame budget")
struct OrbFramePolicyTests {
    @Test func fullRateWhenVisible() {
        let p = OrbFramePolicy.make(visible: true, sceneActive: true, lowPower: false, reduceMotion: false)
        #expect(!p.paused)
        #expect(abs(p.minimumInterval - 1.0 / 60) < 1e-9)
    }

    @Test func thirtyFramesInLowPower() {
        let p = OrbFramePolicy.make(visible: true, sceneActive: true, lowPower: true, reduceMotion: false)
        #expect(!p.paused)
        #expect(abs(p.minimumInterval - 1.0 / 30) < 1e-9)
    }

    @Test("paused when hidden, in background, or under Reduce Motion")
    func paused() {
        #expect(OrbFramePolicy.make(visible: false, sceneActive: true, lowPower: false, reduceMotion: false).paused)
        #expect(OrbFramePolicy.make(visible: true, sceneActive: false, lowPower: false, reduceMotion: false).paused)
        #expect(OrbFramePolicy.make(visible: true, sceneActive: true, lowPower: false, reduceMotion: true).paused)
    }
}

@Suite("Orb geometry")
struct OrbGeometryTests {
    let center = CGPoint(x: 100, y: 100)

    func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }

    @Test("no deformation gives a circle")
    func circle() {
        let pts = OrbGeometry.blobPoints(center: center, radius: 50, count: 36, time: 12.3, seed: 7, deformation: 0, noiseSpeed: 1)
        #expect(pts.count == 36)
        #expect(pts.allSatisfy { abs(distance($0, center) - 50) < 1e-9 })
        #expect(abs(Double(pts[0].x) - 100) < 1e-9 && abs(Double(pts[0].y) - 50) < 1e-9) // starts at 12 o'clock
    }

    @Test("deformation is a strict bound on the edge", arguments: [0.0, 1.7, 40.0, 1_000_000.0])
    func bounded(time: Double) {
        let d = 0.08
        let pts = OrbGeometry.blobPoints(center: center, radius: 50, count: 64, time: time, seed: 3, deformation: d, noiseSpeed: 0.9)
        for p in pts {
            let r = distance(p, center)
            #expect(r >= 50 * (1 - d) - 1e-9 && r <= 50 * (1 + d) + 1e-9)
        }
    }

    @Test("deterministic for a seed, different across seeds, moving with time")
    func deterministic() {
        let a = OrbGeometry.blobPoints(center: center, radius: 50, count: 24, time: 2, seed: 5, deformation: 0.05, noiseSpeed: 1)
        let b = OrbGeometry.blobPoints(center: center, radius: 50, count: 24, time: 2, seed: 5, deformation: 0.05, noiseSpeed: 1)
        let c = OrbGeometry.blobPoints(center: center, radius: 50, count: 24, time: 2, seed: 6, deformation: 0.05, noiseSpeed: 1)
        let d = OrbGeometry.blobPoints(center: center, radius: 50, count: 24, time: 3, seed: 5, deformation: 0.05, noiseSpeed: 1)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("degenerate input gives no points")
    func degenerate() {
        #expect(OrbGeometry.blobPoints(center: center, radius: 50, count: 2, time: 0, seed: 1, deformation: 0.1, noiseSpeed: 1).isEmpty)
        #expect(OrbGeometry.blobPoints(center: center, radius: 0, count: 12, time: 0, seed: 1, deformation: 0.1, noiseSpeed: 1).isEmpty)
        #expect(OrbGeometry.smoothClosedPath([]).isEmpty)
    }

    @Test("smooth path stays near the circle it was drawn from")
    func smoothPath() {
        let pts = OrbGeometry.blobPoints(center: center, radius: 50, count: 32, time: 0, seed: 1, deformation: 0, noiseSpeed: 0)
        let box = OrbGeometry.smoothClosedPath(pts).boundingRect
        #expect(abs(Double(box.width) - 100) < 1.5 && abs(Double(box.height) - 100) < 1.5)
    }

    @Test("body radius grows with level only when the state listens to sound")
    func bodyRadius() {
        let size = CGSize(width: 200, height: 200)
        let idle = OrbParameters.forState(.idle), listening = OrbParameters.forState(.listening)
        let quiet = OrbGeometry.bodyRadius(size: size, parameters: listening, time: 0, level: 0)
        let loud = OrbGeometry.bodyRadius(size: size, parameters: listening, time: 0, level: 1)
        #expect(loud > quiet)
        #expect(OrbGeometry.bodyRadius(size: size, parameters: idle, time: 0, level: 1) == OrbGeometry.bodyRadius(size: size, parameters: idle, time: 0, level: 0))
        // Out-of-range and NaN levels are clamped.
        #expect(OrbGeometry.bodyRadius(size: size, parameters: listening, time: 0, level: 7) == loud)
        #expect(OrbGeometry.bodyRadius(size: size, parameters: listening, time: 0, level: .nan) == quiet)
    }

    @Test("one satellite per agent, evenly spaced on the orbit", arguments: [1, 2, 3, 5])
    func satellites(count: Int) {
        let pts = OrbGeometry.satellitePositions(count: count, center: center, mode: .orbiting, bodyRadius: 40, time: 0)
        #expect(pts.count == count)
        let orbit = OrbGeometry.satelliteOrbitRadius(mode: .orbiting, bodyRadius: 40)
        #expect(pts.allSatisfy { abs(distance($0, center) - orbit) < 1e-9 })
        #expect(abs(Double(pts[0].y) - (100 - orbit)) < 1e-9) // first at 12 o'clock
        if count > 1 {
            let chord = 2 * orbit * sin(.pi / Double(count))
            for i in 0..<count {
                #expect(abs(distance(pts[i], pts[(i + 1) % count]) - chord) < 1e-6)
            }
        }
    }

    @Test("satellites: capped, hidden mode empty, docked sit on the rim and hold still")
    func satelliteModes() {
        #expect(OrbGeometry.satellitePositions(count: 10, center: center, mode: .orbiting, bodyRadius: 40, time: 0).count == OrbGeometry.maxVisibleSatellites)
        #expect(OrbGeometry.satellitePositions(count: 3, center: center, mode: .hidden, bodyRadius: 40, time: 0).isEmpty)
        #expect(OrbGeometry.satellitePositions(count: 0, center: center, mode: .orbiting, bodyRadius: 40, time: 0).isEmpty)
        #expect(OrbGeometry.satellitePositions(count: -2, center: center, mode: .orbiting, bodyRadius: 40, time: 0).isEmpty)
        let docked = OrbGeometry.satelliteOrbitRadius(mode: .docked, bodyRadius: 40)
        let orbiting = OrbGeometry.satelliteOrbitRadius(mode: .orbiting, bodyRadius: 40)
        #expect(docked < orbiting && docked >= 40)
        let t0 = OrbGeometry.satellitePositions(count: 3, center: center, mode: .docked, bodyRadius: 40, time: 0)
        let t9 = OrbGeometry.satellitePositions(count: 3, center: center, mode: .docked, bodyRadius: 40, time: 9)
        #expect(t0 == t9)
        let o9 = OrbGeometry.satellitePositions(count: 3, center: center, mode: .orbiting, bodyRadius: 40, time: 9)
        #expect(o9 != OrbGeometry.satellitePositions(count: 3, center: center, mode: .orbiting, bodyRadius: 40, time: 0))
        #expect(OrbGeometry.satelliteRadius(bodyRadius: 40, count: 6) < OrbGeometry.satelliteRadius(bodyRadius: 40, count: 1))
        #expect(OrbGeometry.satelliteRadius(bodyRadius: 40, count: 6) > 0)
    }

    @Test("error shake happens once, then exactly zero")
    func shake() {
        #expect(OrbGeometry.shakeOffset(elapsed: -1, amplitude: 8) == 0)
        #expect(OrbGeometry.shakeOffset(elapsed: 0.45, amplitude: 8) == 0)
        #expect(OrbGeometry.shakeOffset(elapsed: 5, amplitude: 8) == 0)
        let samples = stride(from: 0.0, to: 0.45, by: 0.01).map { OrbGeometry.shakeOffset(elapsed: $0, amplitude: 8) }
        #expect(samples.contains { abs($0) > 2 })
        #expect(samples.allSatisfy { abs($0) <= 8 })
    }

    @Test("ripples and sweep stay in [0, 1)")
    func phases() {
        for t in [0.0, 0.7, 13.37, 9_999.1] {
            let r = OrbGeometry.ripplePhases(time: t, count: 3)
            #expect(r.count == 3 && r.allSatisfy { $0 >= 0 && $0 < 1 })
            let s = OrbGeometry.sweepProgress(time: t)
            #expect(s >= 0 && s < 1)
        }
        #expect(OrbGeometry.ripplePhases(time: 1, count: 0).isEmpty)
    }
}
