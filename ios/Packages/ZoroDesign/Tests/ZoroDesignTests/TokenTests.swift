import SwiftUI
import Testing
@testable import ZoroDesign

@Suite("Tokens")
struct TokenTests {
    @Test("spec hues are exact (light / dark)")
    func specValues() {
        let expected: [ZoroHue: (UInt32, UInt32)] = [
            .neel: (0x2A2F8F, 0x5B62E0), .mor: (0x0B7F86, 0x19B5B0), .genda: (0xD98A00, 0xFFB321),
            .lac: (0xB5302A, 0xFF6B5E), .moonstone: (0x6E7A8A, 0xA9B4C2),
        ]
        #expect(expected.count == ZoroHue.allCases.count)
        for hue in ZoroHue.allCases {
            #expect(hue.variants.light == RGB(expected[hue]!.0))
            #expect(hue.variants.dark == RGB(expected[hue]!.1))
        }
    }

    @Test("each hue has four distinct variants and resolves per appearance", arguments: ZoroHue.allCases)
    func variants(hue: ZoroHue) {
        let v = hue.variants
        #expect(Set([v.light, v.dark, v.lightHighContrast, v.darkHighContrast]).count == 4)
        #expect(hue.rgb(scheme: .light, highContrast: false) == v.light)
        #expect(hue.rgb(scheme: .dark, highContrast: false) == v.dark)
        #expect(hue.rgb(scheme: .light, highContrast: true) == v.lightHighContrast)
        #expect(hue.rgb(scheme: .dark, highContrast: true) == v.darkHighContrast)
    }

    @Test("Increase Contrast variants carry text at 4.5:1 on every system background", arguments: ZoroHue.allCases)
    func highContrast(hue: ZoroHue) {
        let v = hue.variants
        #expect(v.lightHighContrast.contrastRatio(against: ZoroNeutralReference.lightBackground) >= 4.5)
        #expect(v.lightHighContrast.contrastRatio(against: ZoroNeutralReference.lightGroupedBackground) >= 4.5)
        #expect(v.darkHighContrast.contrastRatio(against: ZoroNeutralReference.darkBackground) >= 4.5)
        #expect(v.darkHighContrast.contrastRatio(against: ZoroNeutralReference.darkSecondaryBackground) >= 4.5)
    }

    @Test("standard variants reach 3:1 as UI marks, except marigold in light mode (fill only)", arguments: ZoroHue.allCases)
    func standardContrast(hue: ZoroHue) {
        let v = hue.variants
        #expect(v.dark.contrastRatio(against: ZoroNeutralReference.darkSecondaryBackground) >= 3)
        if hue != .genda { #expect(v.light.contrastRatio(against: ZoroNeutralReference.lightBackground) >= 3) }
    }

    @Test("text safety is measured: mor and lac carry text, neel, genda, moonstone do not")
    func textSafety() {
        #expect(ZoroHue.allCases.filter(\.isTextSafeAtStandardContrast) == [.mor, .lac])
    }

    @Test("labels on a filled hue read at 4.5:1 in every appearance", arguments: ZoroHue.allCases)
    func onFill(hue: ZoroHue) {
        for scheme in [ColorScheme.light, .dark] {
            for hc in [false, true] {
                let fill = hue.rgb(scheme: scheme, highContrast: hc)
                #expect(hue.labelOnFill(scheme: scheme, highContrast: hc).contrastRatio(against: fill) >= 4.5)
            }
        }
        // The primary button is white on neel in both schemes.
        #expect(ZoroHue.neel.labelOnFill(scheme: .light, highContrast: false) == .white)
        #expect(ZoroHue.neel.labelOnFill(scheme: .dark, highContrast: false) == .white)
    }

    @Test func contrastMath() {
        #expect(abs(RGB.white.contrastRatio(against: .black) - 21) < 1e-9)
        #expect(RGB(0x123456).contrastRatio(against: RGB(0x123456)) == 1)
        #expect(RGB(0x2A2F8F).hexString == "#2A2F8F")
    }

    @Test("every semantic role maps to a hue, and each hue serves a role")
    func roles() {
        #expect(Set(ZoroRole.allCases.map(\.hue)) == Set(ZoroHue.allCases))
    }

    @Test("type scale: every style defined, families as the spec says", arguments: ZoroTextStyle.allCases)
    func type(style: ZoroTextStyle) {
        switch style {
        case .title, .heading, .amountHero, .amount:
            #expect(style.family == .expanded && style.weight == .semibold)
        case .zoroVoice, .zoroBody:
            #expect(style.family == .serif)
        case .ownerVoice, .body, .detail, .caption:
            #expect(style.family == .standard)
        }
        if style == .amount || style == .amountHero { #expect(style.usesMonospacedDigits) }
        #expect(style.mixedScriptLeading >= 0)
    }

    @Test("voice lines get the most mixed-script leading")
    func leading() {
        let maxLeading = ZoroTextStyle.allCases.map(\.mixedScriptLeading).max()
        #expect(ZoroTextStyle.zoroVoice.mixedScriptLeading == maxLeading)
        #expect(ZoroTextStyle.ownerVoice.mixedScriptLeading == maxLeading)
    }

    @Test("spacing on a 4 pt grid (plus the 2 pt hair), strictly increasing")
    func spacing() {
        let values = ZoroSpace.allCases.map(\.value)
        #expect(values == values.sorted() && Set(values).count == values.count)
        #expect(values.dropFirst().allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
    }

    @Test("radii grow with surface size")
    func radii() {
        let r = ZoroRadius.allCases.map(\.value)
        #expect(r == r.sorted() && Set(r).count == r.count)
    }

    @Test("motion durations increase and Reduce Motion is a short cross-fade")
    func motion() {
        let d = ZoroMotion.allCases.map(\.duration)
        #expect(d == d.sorted() && d.allSatisfy { $0 > 0 && $0 <= 1 })
        #expect(ZoroMotion.reducedDuration <= ZoroMotion.standard.duration)
        for m in ZoroMotion.allCases {
            #expect(m.animation(reduceMotion: true) == .easeInOut(duration: ZoroMotion.reducedDuration))
        }
    }

    @Test("haptics: one feedback per event, all distinct events")
    func haptics() {
        #expect(ZoroHaptic.allCases.count == 6)
        #expect(ZoroHaptic.failure.feedback == .error)
        #expect(ZoroHaptic.success.feedback == .success)
    }

    @Test("state views: error is lac, disconnected is genda, each has a symbol")
    func states() {
        #expect(ZoroStateKind.error.role == .critical)
        #expect(ZoroStateKind.disconnected.role == .attention)
        #expect(Set(ZoroStateKind.allCases.map(\.symbol)).count == ZoroStateKind.allCases.count)
    }
}
