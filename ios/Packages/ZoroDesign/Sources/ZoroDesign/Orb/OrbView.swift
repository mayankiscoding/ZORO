import Combine
import SwiftUI

/// The orb: ZORO's one bold element. Redraws inside a `TimelineView` at 60 fps, 30 fps in Low Power
/// Mode, and not at all when it is off screen, the scene is inactive, or Reduce Motion is on (then
/// it draws one static frame and answers sound with opacity only).
public struct OrbView: View {
    public let state: OrbState
    public let level: Double
    public let satellites: [OrbSatellite]

    /// - Parameters:
    ///   - level: audio level 0...1 (the owner's voice while listening, ZORO's while speaking).
    ///   - satellites: one per working agent.
    public init(state: OrbState, level: Double = 0, satellites: [OrbSatellite] = []) {
        self.state = state
        self.level = level
        self.satellites = satellites
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var stateEnteredAt = Date()

    public var body: some View {
        let policy = OrbFramePolicy.make(
            visible: isVisible, sceneActive: scenePhase != .background, lowPower: lowPower, reduceMotion: reduceMotion
        )
        TimelineView(.animation(minimumInterval: policy.minimumInterval, paused: policy.paused)) { timeline in
            OrbCanvas(
                state: state, level: level, satellites: satellites,
                time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate,
                stateElapsed: timeline.date.timeIntervalSince(stateEnteredAt),
                reduceMotion: reduceMotion
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: state) { stateEnteredAt = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OrbAccessibility.label)
        .accessibilityValue(OrbAccessibility.value(state: state, satellites: satellites))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// One frame of the orb at an explicit time. `OrbView` animates it; snapshots and previews use it
/// directly.
public struct OrbCanvas: View {
    let state: OrbState
    let level: Double
    let satellites: [OrbSatellite]
    let time: Double
    let stateElapsed: Double
    let reduceMotion: Bool

    public init(
        state: OrbState, level: Double = 0, satellites: [OrbSatellite] = [], time: Double = 0,
        stateElapsed: Double = 10, reduceMotion: Bool = false
    ) {
        self.state = state
        self.level = level
        self.satellites = satellites
        self.time = time
        self.stateElapsed = stateElapsed
        self.reduceMotion = reduceMotion
    }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    public var body: some View {
        let renderer = OrbRenderer(
            parameters: OrbParameters.forState(state, reduceMotion: reduceMotion),
            level: OrbGeometry.clampUnit(level), satellites: satellites, time: time,
            stateElapsed: stateElapsed, scheme: scheme, contrast: contrast
        )
        Canvas { context, size in renderer.draw(in: &context, size: size) }
    }
}

struct OrbRenderer {
    let parameters: OrbParameters
    let level: Double
    let satellites: [OrbSatellite]
    let time: Double
    let stateElapsed: Double
    let scheme: ColorScheme
    let contrast: ColorSchemeContrast

    private func hue(_ h: ZoroHue) -> Color { h.color(scheme: scheme, contrast: contrast) }

    func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let p = parameters
        let shake = p.shake ? OrbGeometry.shakeOffset(elapsed: stateElapsed, amplitude: Double(min(size.width, size.height)) * 0.04) : 0
        let c = CGPoint(x: Double(size.width) / 2 + shake, y: Double(size.height) / 2)
        let r = OrbGeometry.bodyRadius(size: size, parameters: p, time: time, level: level)
        guard r > 1 else { return }

        let moon = p.palette == .moonstone
        let neel = moon ? hue(.moonstone) : hue(.neel)
        let mor = moon ? hue(.moonstone) : hue(.mor)
        let genda = hue(.genda)
        // Errors read as lac red, not coral or pink: deepen the dark-mode variant.
        let lac = scheme == .dark ? hue(.lac).mix(with: .black, by: 0.3) : hue(.lac)

        func tinted(_ color: Color) -> Color {
            var out = color
            if !moon { out = neel.mix(with: out, by: p.iridescence) }
            if p.alarm > 0 { out = out.mix(with: lac, by: p.alarm) }
            return out
        }

        // 1. Halo: answers sound with opacity (and is all that moves under Reduce Motion).
        var haloColor = tinted(neel)
        if p.warmth > 0 { haloColor = haloColor.mix(with: genda, by: p.warmth * 0.8) }
        let haloOpacity = (scheme == .dark ? 0.34 : 0.2) + p.levelOpacityGain * level
        ctx.fill(
            Path(ellipseIn: square(c, r * 1.6)),
            with: .radialGradient(
                Gradient(colors: [haloColor.opacity(haloOpacity), haloColor.opacity(0)]),
                center: c, startRadius: r * 0.7, endRadius: r * 1.6
            )
        )

        // 2. Ripples while listening.
        if p.ripples {
            for phase in OrbGeometry.ripplePhases(time: time, count: 3) {
                let rr = r * (1.06 + 0.5 * phase) * (1 + 0.25 * level)
                ctx.stroke(
                    Path(ellipseIn: square(c, rr)),
                    with: .color(mor.opacity((1 - phase) * (0.25 + 0.45 * level))),
                    lineWidth: 1.2
                )
            }
        }

        // 3. Body: a peacock feather's eye. Deep neel centre, a mor band, one thread of genda, neel
        // again at the rim. The eye drifts inside the blob, so the colours shift like iridescence
        // instead of spinning like a pinwheel.
        let turn = 2 * Double.pi * p.rotationSpeed * time
        let deep = neel.mix(with: .black, by: moon ? 0.12 : (scheme == .dark ? 0.45 : 0.3))
        let thread = moon ? neel : genda
        let eyeStops: [Gradient.Stop] = [
            .init(color: tinted(deep), location: 0),
            .init(color: tinted(neel), location: 0.36),
            .init(color: tinted(mor), location: 0.62),
            .init(color: tinted(thread), location: 0.71),
            .init(color: tinted(mor), location: 0.77),
            .init(color: tinted(neel), location: 0.9),
            .init(color: tinted(deep), location: 1),
        ]
        let drift = 0.22 * p.iridescence
        let eye = CGPoint(x: c.x + r * drift * cos(turn), y: c.y + r * drift * sin(turn * 0.7) - r * 0.06)
        let back = OrbGeometry.smoothClosedPath(OrbGeometry.blobPoints(
            center: c, radius: r, count: 48, time: time, seed: 11, deformation: p.deformation, noiseSpeed: p.noiseSpeed
        ))
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: r * 0.035))
            layer.fill(back, with: .radialGradient(Gradient(stops: eyeStops), center: eye, startRadius: 0, endRadius: r * 1.25))
        }

        // 4. Sheen: a second, smaller blob of mor that slides the other way at low opacity.
        if p.iridescence > 0 {
            let mid = OrbGeometry.smoothClosedPath(OrbGeometry.blobPoints(
                center: CGPoint(x: c.x - r * drift * cos(turn * 1.3), y: c.y + r * 0.1), radius: r * 0.62, count: 40,
                time: time, seed: 29, deformation: p.deformation * 1.6, noiseSpeed: p.noiseSpeed * 1.2
            ))
            ctx.drawLayer { layer in
                layer.opacity = 0.35 * p.iridescence
                layer.blendMode = .screen
                layer.addFilter(.blur(radius: r * 0.12))
                layer.fill(mid, with: .color(tinted(mor)))
            }
        }

        // 5. Marigold warmth while ZORO speaks; a soft light from the upper left.
        if p.warmth > 0 {
            let warm = genda.opacity(p.warmth * (0.7 + 0.3 * level))
            ctx.drawLayer { layer in
                layer.blendMode = .screen
                layer.fill(back, with: .radialGradient(Gradient(colors: [warm, genda.opacity(0)]), center: eye, startRadius: 0, endRadius: r * 0.75))
            }
        }
        let light = CGPoint(x: c.x - r * 0.32, y: c.y - r * 0.4)
        ctx.fill(
            back,
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(scheme == .dark ? 0.16 : 0.22), Color.white.opacity(0)]),
                center: light, startRadius: 0, endRadius: r * 0.7
            )
        )

        // 6. Processing arc / tool sweep / sealed ring.
        let ringR = r * 1.2
        let ringWidth = max(1.5, r * 0.04)
        switch p.arc {
        case .none: break
        case .turning:
            let start = Angle.radians(2 * .pi * 0.45 * time)
            var arc = Path()
            arc.addArc(center: c, radius: ringR, startAngle: start, endAngle: start + .degrees(110), clockwise: false)
            let arcGradient = Gradient(stops: [
                .init(color: tinted(mor).opacity(0), location: 0),
                .init(color: tinted(mor), location: 0.2),
                .init(color: tinted(genda), location: 0.31),
                .init(color: tinted(genda).opacity(0), location: 0.32),
            ])
            ctx.stroke(arc, with: .conicGradient(arcGradient, center: c, angle: start), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
        case .sweep:
            ctx.stroke(Path(ellipseIn: square(c, ringR)), with: .color(mor.opacity(0.2)), lineWidth: ringWidth)
            let progress = OrbGeometry.sweepProgress(time: time)
            var arc = Path()
            arc.addArc(center: c, radius: ringR, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * max(progress, 0.02)), clockwise: false)
            ctx.stroke(arc, with: .color(mor), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
        }
        if p.ring == .sealed {
            let stone = hue(.moonstone)
            ctx.stroke(Path(ellipseIn: square(c, ringR)), with: .color(stone), lineWidth: ringWidth)
            ctx.stroke(Path(ellipseIn: square(c, ringR - ringWidth * 2.5)), with: .color(stone.opacity(0.5)), lineWidth: ringWidth * 0.5)
            // The clasp: where the ring closes on itself, at 12 o'clock.
            let clasp = CGRect(x: c.x - r * 0.07, y: c.y - ringR - ringWidth * 1.6, width: r * 0.14, height: ringWidth * 3.2)
            ctx.fill(Path(roundedRect: clasp, cornerRadius: ringWidth * 1.6, style: .continuous), with: .color(stone))
        }

        // 7. Satellites: one per working agent.
        guard p.satellites != .hidden, !satellites.isEmpty else { return }
        let positions = OrbGeometry.satellitePositions(count: satellites.count, center: c, mode: p.satellites, bodyRadius: r, time: time)
        let sr = OrbGeometry.satelliteRadius(bodyRadius: r, count: satellites.count)
        let disc = scheme == .dark ? Color(white: 0.11) : Color.white
        for (point, satellite) in zip(positions, satellites) {
            if p.satellites == .orbiting {
                var tether = Path()
                let dx = point.x - c.x, dy = point.y - c.y
                let len = max(sqrt(dx * dx + dy * dy), 1)
                tether.move(to: CGPoint(x: c.x + dx / len * r * 1.02, y: c.y + dy / len * r * 1.02))
                tether.addLine(to: CGPoint(x: point.x - dx / len * sr, y: point.y - dy / len * sr))
                ctx.stroke(tether, with: .color(mor.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            let rect = square(point, sr)
            ctx.fill(Path(ellipseIn: rect), with: .color(disc))
            ctx.stroke(Path(ellipseIn: rect), with: .color(p.satellites == .docked ? genda : mor), lineWidth: max(1, sr * 0.12))
            var symbol = ctx.resolve(Image(systemName: satellite.symbol))
            symbol.shading = .color(tinted(neel))
            let s = symbol.size
            let box = sr * 1.0
            let k = s.width > 0 && s.height > 0 ? box / max(Double(s.width), Double(s.height)) : 1
            let w = Double(s.width) * k, h = Double(s.height) * k
            ctx.draw(symbol, in: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h))
        }
    }

    private func square(_ center: CGPoint, _ radius: Double) -> CGRect {
        CGRect(x: Double(center.x) - radius, y: Double(center.y) - radius, width: radius * 2, height: radius * 2)
    }
}
