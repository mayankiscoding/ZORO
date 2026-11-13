import SwiftUI

/// The rekha: one horizontal line. The owner's voice hangs below it like Devanagari from its
/// headline; ZORO's voice rises above it like Latin from a baseline.
public struct RekhaWaveform: View {
    public let userLevels: [Double]
    public let assistantLevels: [Double]

    /// Levels are 0...1, oldest first (pass `LevelRingBuffer.padded`).
    public init(userLevels: [Double], assistantLevels: [Double]) {
        self.userLevels = userLevels
        self.assistantLevels = assistantLevels
    }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 56

    public var body: some View {
        let ownerColor = ZoroHue.mor.color(scheme: scheme, contrast: contrast)
        let zoroColor = ZoroHue.genda.color(scheme: scheme, contrast: contrast)
        let line = contrast == .increased ? ZoroStroke.rekhaHighContrast : ZoroStroke.rekha
        Canvas { ctx, size in
            let lineY = Double(size.height) / 2
            let reach = lineY - Double(line)
            for bar in RekhaLayout.bars(levels: assistantLevels, side: .zoro, width: Double(size.width), lineY: lineY, maxHeight: reach, barWidth: 2.5, gap: 2.5) {
                ctx.fill(Path(roundedRect: bar, cornerRadius: 1.25), with: .color(zoroColor))
            }
            for bar in RekhaLayout.bars(levels: userLevels, side: .owner, width: Double(size.width), lineY: lineY, maxHeight: reach, barWidth: 2.5, gap: 2.5) {
                ctx.fill(Path(roundedRect: bar, cornerRadius: 1.25), with: .color(ownerColor))
            }
            var rule = Path()
            rule.move(to: CGPoint(x: 0, y: lineY))
            rule.addLine(to: CGPoint(x: Double(size.width), y: lineY))
            ctx.stroke(rule, with: .color(Color.primary.opacity(ZoroStroke.rekhaOpacity(highContrast: contrast == .increased))), lineWidth: line)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The voice screen's structure: ZORO's words stand on the rekha, the owner's words hang from it.
/// Use it for the live transcript and for every exchange in the ZORO tab.
public struct RekhaStage<Above: View, Below: View>: View {
    let above: Above
    let below: Below

    public init(@ViewBuilder zoro: () -> Above, @ViewBuilder owner: () -> Below) {
        above = zoro()
        below = owner()
    }

    @Environment(\.colorSchemeContrast) private var contrast

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            above
                .frame(maxWidth: .infinity, minHeight: 0, alignment: .bottomLeading)
                .padding(.bottom, ZoroSpace.m.value)
            Rectangle()
                .fill(Color.primary.opacity(ZoroStroke.rekhaOpacity(highContrast: contrast == .increased)))
                .frame(height: contrast == .increased ? ZoroStroke.rekhaHighContrast : ZoroStroke.rekha)
                .accessibilityHidden(true)
            below
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, ZoroSpace.m.value)
        }
    }
}
