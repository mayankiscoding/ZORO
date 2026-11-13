#if DEBUG
import SwiftUI

/// Every component and orb state on one scrolling page. Debug builds only; specimen values.
public struct ZoroDesignGallery: View {
    public init() {}

    @State private var orbState: OrbState = .idle
    @State private var chip = 0

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoroSpace.xxl.value) {
                Text("ZORO design").zoroText(.title)
                Text("Specimen values, not real data.").zoroText(.detail).foregroundStyle(.secondary)

                ZoroSectionHeader("Live orb", detail: "Animated, with the frame budget and Reduce Motion rules.")
                OrbView(state: orbState, level: 0.4, satellites: GallerySpecimens.satellites).frame(height: 220)
                Picker("State", selection: $orbState) {
                    ForEach(OrbState.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }

                ZoroSectionHeader("Orb states")
                GalleryOrbGrid()

                ZoroSectionHeader("Live voice")
                GalleryVoiceStage()

                ZoroSectionHeader("Colour and type")
                GalleryPalette()
                GalleryTypeScale()

                ZoroSectionHeader("Devanagari", detail: "ZORO's Hindi in the bundled serif; the owner's in the system face.")
                GalleryDevanagari()

                ZoroSectionHeader("Welcome")
                GalleryWelcome()

                ZoroSectionHeader("Artwork", detail: "Welcome and empty states only, never behind data.")
                GalleryArtwork()

                ZoroSectionHeader("Controls")
                GalleryControls(chip: $chip)

                ZoroSectionHeader("States")
                GalleryStates()

                ZoroSectionHeader("Agents")
                GalleryAgents()

                ZoroSectionHeader("Shopping")
                GalleryCommerce()

                ZoroSectionHeader("Trust")
                GalleryTrust()

                ZoroSectionHeader("Charts")
                GalleryCharts()
            }
            .padding(ZoroSpace.l.value)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(ZoroNeutral.background)
    }
}

public struct GalleryOrbGrid: View {
    public init() {}
    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ZoroSpace.l.value), count: 4), spacing: ZoroSpace.l.value) {
            ForEach(Array(OrbState.allCases.enumerated()), id: \.element) { index, state in
                VStack(spacing: ZoroSpace.s.value) {
                    OrbCanvas(
                        state: state,
                        level: state == .listening || state == .speaking ? 0.6 : 0,
                        satellites: GallerySpecimens.satellites,
                        time: 3.1 + Double(index) * 1.7,
                        stateElapsed: state == .error ? 0.1 : 10
                    )
                    .aspectRatio(1, contentMode: .fit)
                    Text(state.accessibilityValue).zoroText(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
                }
            }
        }
    }
}

/// The Live Voice composition: orb, then the rekha. ZORO's words stand on the line, the owner's hang from it.
public struct GalleryVoiceStage: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.xl.value) {
            PrivacyModeBanner(.strictPrivate)
            OrbCanvas(state: .speaking, level: 0.5, time: 2.4).frame(height: 230).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                Text("Store A has all three for ₹231.50, the lowest of the three stores. Open the basket there?")
                    .zoroText(.zoroVoice)
                    .fixedSize(horizontal: false, vertical: true)
                RekhaWaveform(
                    userLevels: GallerySpecimens.levels(count: 40, seed: 1) + Array(repeating: 0, count: 50),
                    assistantLevels: Array(repeating: 0, count: 50) + GallerySpecimens.levels(count: 40, seed: 4)
                )
                Text("दूध, चावल और टमाटर सबसे सस्ते कहाँ मिलेंगे?")
                    .zoroText(.ownerVoice)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

public struct GalleryPalette: View {
    public init() {}
    public var body: some View {
        HStack(spacing: ZoroSpace.s.value) {
            ForEach(ZoroHue.allCases, id: \.self) { hue in
                VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                    ZoroRadius.control.shape.fill(ZoroColor(hue)).frame(height: 56)
                    Text(hue.rawValue.capitalized).font(.subheadline.weight(.semibold))
                    Text("\(hue.variants.light.hexString) \(hue.variants.dark.hexString)").zoroText(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

public struct GalleryTypeScale: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
            Text("Spaces").zoroText(.title)
            Text("This month").zoroText(.heading)
            MoneyText(Decimal(string: "1234567.5")!, style: .exact, textStyle: .amountHero)
            Text("Your grocery spend is lower than last month.").zoroText(.zoroVoice)
            ZoroVoiceText("पिछले महीने से कम खर्च हुआ।", style: .zoroBody)
            Text("Remind me to call Ma at 7").zoroText(.ownerVoice)
            Text("Interface text in SF Pro.").zoroText(.body)
            Text("From Specimen store A, checked 4:12 pm").zoroText(.caption).foregroundStyle(.secondary)
        }
    }
}

public struct GalleryControls: View {
    @Binding var chip: Int
    public init(chip: Binding<Int>) { _chip = chip }
    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            HStack {
                ForEach(Array(["All", "Groceries", "Pharmacy"].enumerated()), id: \.offset) { i, title in
                    ZoroChip(title, symbol: i == 1 ? "basket" : nil, isSelected: chip == i) { chip = i }
                }
            }
            Button("Add to basket") {}.buttonStyle(.zoroPrimary)
            Button("Compare stores") {}.buttonStyle(.zoroSecondary)
            Button("Remove item") {}.buttonStyle(ZoroSecondaryButtonStyle(role: .critical))
            Button("Add to basket") {}.buttonStyle(.zoroPrimary).disabled(true)
        }
    }
}

public struct GalleryStates: View {
    public init() {}
    public var body: some View {
        VStack(spacing: ZoroSpace.s.value) {
            ZoroCard { ZoroStateView(.empty, message: "No baskets yet. Ask ZORO to start one, like “add milk and eggs”.") }
            ZoroCard { ZoroStateView(.loading, message: "Checking prices at 3 stores.") }
            ZoroCard { ZoroStateView(.error, message: "Store B didn't answer, so it's left out of the comparison.", action: ZoroStateAction("Try again") {}) }
            ZoroCard { ZoroStateView(.disconnected, message: "Can't reach your ZORO server. Check that your Mac is awake and on Tailscale.", action: ZoroStateAction("Reconnect") {}) }
        }
    }
}

public struct GalleryAgents: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroCard {
                VStack(spacing: 0) {
                    ForEach(GallerySpecimens.activities) { AgentActivityRow($0) }
                }
            }
            HStack {
                AgentBadge(name: "Shopping", symbol: "basket", status: .working)
                ConfidenceBadge(score: 0.92)
                ConfidenceBadge(score: 0.6)
                ConfidenceBadge(score: 0.2)
            }
        }
    }
}

public struct GalleryCommerce: View {
    public init() {}
    public var body: some View {
        VStack(spacing: ZoroSpace.m.value) {
            ProductCardView(GallerySpecimens.product, now: GallerySpecimens.now)
            ProductCardView(GallerySpecimens.staleProduct, now: GallerySpecimens.now)
            ComparisonTableView(GallerySpecimens.comparison, now: GallerySpecimens.now)
        }
    }
}

public struct GalleryTrust: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            PrivacyModeBanner(.strictPrivate, actionTitle: "Change") {}
            PrivacyModeBanner(.cloudIntelligence, actionTitle: "Change") {}
            ApprovalSummaryBlock(GallerySpecimens.paymentHandoff, now: GallerySpecimens.now, onApprove: {}, onDecline: {})
        }
    }
}

public struct GalleryCharts: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroCard { CategoryBarChart(GallerySpecimens.categories) }
            ZoroCard { TrendLineChart(GallerySpecimens.trend) }
            ZoroCard { AllocationRingChart(GallerySpecimens.allocation) }
        }
    }
}
#endif
