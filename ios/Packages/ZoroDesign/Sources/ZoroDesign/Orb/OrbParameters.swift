import Foundation

/// The orb's states, mirroring the voice state machine in `VoiceInterface`.
public enum OrbState: String, CaseIterable, Sendable, Hashable {
    case idle
    case listening
    case processing
    case delegating
    case toolExecution
    case speaking
    case error
    case privateOffline

    /// VoiceOver value, read after the label "ZORO".
    public var accessibilityValue: String {
        switch self {
        case .idle: "Ready. Tap to talk."
        case .listening: "Listening"
        case .processing: "Thinking"
        case .delegating: "Working with other agents"
        case .toolExecution: "Carrying out a step"
        case .speaking: "Speaking"
        case .error: "Something went wrong"
        case .privateOffline: "Private mode. Nothing leaves your server."
        }
    }
}

/// One working agent shown as a satellite.
public struct OrbSatellite: Identifiable, Hashable, Sendable {
    public let id: String
    /// Plain name read by VoiceOver ("Shopping").
    public let name: String
    /// SF Symbol drawn inside the satellite.
    public let symbol: String

    public init(id: String, name: String, symbol: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
    }
}

public enum OrbPalette: Sendable, Hashable { case peacock, moonstone }
public enum OrbArc: Sendable, Hashable { case none, turning, sweep }
public enum OrbRing: Sendable, Hashable { case none, sealed }
public enum OrbSatelliteMode: Sendable, Hashable { case hidden, orbiting, docked }

/// Every per-state number the orb uses. Pure data, so each state is unit-tested.
public struct OrbParameters: Sendable, Hashable {
    /// Body radius as a fraction of the largest radius the frame allows.
    public var scale: Double
    /// Breath amplitude as a fraction of the radius.
    public var breathAmplitude: Double
    /// Breath period in seconds.
    public var breathPeriod: Double
    /// Edge deformation as a fraction of the radius (noise amplitude).
    public var deformation: Double
    /// How fast the deformation field drifts, radians per second.
    public var noiseSpeed: Double
    /// Radius growth at full audio level, fraction of the radius.
    public var levelGain: Double
    /// Halo opacity added at full audio level (the Reduce Motion response to sound).
    public var levelOpacityGain: Double
    /// 0 = flat colour, 1 = full peacock iridescence.
    public var iridescence: Double
    /// Gradient rotation, turns per second.
    public var rotationSpeed: Double
    /// Marigold warmth mixed into the core, 0...1.
    public var warmth: Double
    /// Lac tint, 0...1.
    public var alarm: Double
    public var palette: OrbPalette
    public var arc: OrbArc
    public var ring: OrbRing
    public var ripples: Bool
    public var satellites: OrbSatelliteMode
    /// One damped shake when the state is entered.
    public var shake: Bool

    public static func forState(_ state: OrbState, reduceMotion: Bool = false) -> OrbParameters {
        var p = OrbParameters.base(state)
        if reduceMotion {
            // Reduce Motion: no deformation, travel or rotation; sound and state show as opacity.
            p.breathAmplitude = 0
            p.deformation = 0
            p.noiseSpeed = 0
            p.rotationSpeed = 0
            p.levelOpacityGain = max(p.levelOpacityGain, p.levelGain * 2)
            p.levelGain = 0
            p.ripples = false
            p.shake = false
        }
        return p
    }

    private static func base(_ state: OrbState) -> OrbParameters {
        let rest = OrbParameters(
            scale: 0.78, breathAmplitude: 0.025, breathPeriod: ZoroMotion.orbBreathPeriod,
            deformation: 0.035, noiseSpeed: 0.25, levelGain: 0, levelOpacityGain: 0,
            iridescence: 0.55, rotationSpeed: 0.02, warmth: 0, alarm: 0,
            palette: .peacock, arc: .none, ring: .none, ripples: false, satellites: .hidden, shake: false
        )
        var p = rest
        switch state {
        case .idle:
            break
        case .listening:
            p.scale = 0.9
            p.breathAmplitude = 0.01
            p.deformation = 0.06
            p.noiseSpeed = 0.9
            p.levelGain = 0.14
            p.levelOpacityGain = 0.15
            p.iridescence = 0.75
            p.rotationSpeed = 0.05
            p.ripples = true
        case .processing:
            p.scale = 0.74
            p.deformation = 0.05
            p.noiseSpeed = 0.6
            p.iridescence = 1
            p.rotationSpeed = 0.18
            p.arc = .turning
        case .delegating:
            p.scale = 0.66
            p.deformation = 0.045
            p.noiseSpeed = 0.5
            p.iridescence = 0.9
            p.rotationSpeed = 0.1
            p.satellites = .orbiting
        case .toolExecution:
            p.scale = 0.7
            p.deformation = 0.03
            p.noiseSpeed = 0.35
            p.iridescence = 0.8
            p.rotationSpeed = 0.06
            p.arc = .sweep
            p.satellites = .docked
        case .speaking:
            p.scale = 0.84
            p.breathAmplitude = 0.012
            p.deformation = 0.05
            p.noiseSpeed = 0.7
            p.levelGain = 0.1
            p.levelOpacityGain = 0.12
            p.iridescence = 0.6
            p.rotationSpeed = 0.04
            p.warmth = 0.7
        case .error:
            p.scale = 0.74
            p.breathAmplitude = 0.012
            p.deformation = 0.02
            p.noiseSpeed = 0.15
            p.iridescence = 0.2
            p.rotationSpeed = 0
            p.alarm = 0.75
            p.shake = true
        case .privateOffline:
            p.scale = 0.72
            p.breathAmplitude = 0.015
            p.deformation = 0.015
            p.noiseSpeed = 0.12
            p.iridescence = 0
            p.rotationSpeed = 0
            p.palette = .moonstone
            p.ring = .sealed
        }
        return p
    }
}

/// VoiceOver text for the orb.
public enum OrbAccessibility {
    public static let label = "ZORO"

    public static func value(state: OrbState, satellites: [OrbSatellite]) -> String {
        guard state == .delegating || state == .toolExecution, !satellites.isEmpty else {
            return state.accessibilityValue
        }
        let names = ListFormatter.localizedString(byJoining: satellites.map(\.name))
        let lead = state == .delegating ? "Working with" : "Carrying out a step with"
        return "\(lead) \(names)"
    }
}

/// How often the orb redraws. `nil` interval means paused (static frame).
public struct OrbFramePolicy: Sendable, Hashable {
    public let minimumInterval: Double
    public let paused: Bool

    public static let fullRate = 1.0 / 60
    public static let lowPowerRate = 1.0 / 30

    public static func make(visible: Bool, sceneActive: Bool, lowPower: Bool, reduceMotion: Bool) -> OrbFramePolicy {
        if !visible || !sceneActive || reduceMotion {
            return OrbFramePolicy(minimumInterval: lowPowerRate, paused: true)
        }
        return OrbFramePolicy(minimumInterval: lowPower ? lowPowerRate : fullRate, paused: false)
    }
}
