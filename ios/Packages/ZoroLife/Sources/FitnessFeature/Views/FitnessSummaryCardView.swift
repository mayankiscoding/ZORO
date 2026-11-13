import LifeSupport
import SwiftUI
import ZoroCore
import ZoroDesign

/// The `fitness_summary` card in a conversation: the figures, ZORO's observations, the data source and freshness line,
/// and the fitness-information note.
public struct FitnessSummaryCardView: View {
    let card: UICard
    let now: Date

    public init(card: UICard) {
        self.card = card
        self.now = Date()
    }

    init(card: UICard, now: Date) {
        self.card = card
        self.now = now
    }

    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        ZoroCard {
            switch Result(catching: { try FitnessCardModel(card: card, now: now) }) {
            case .success(let model):
                content(model)
            case .failure:
                ZoroStateView(.error, message: "This fitness card could not be shown. Ask ZORO again.")
            }
        }
    }

    private func content(_ model: FitnessCardModel) -> some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            Text(model.title).zoroText(.heading).accessibilityAddTraits(.isHeader)
            if model.rows.isEmpty && model.planLine == nil {
                Text("There are no figures to show yet. Sync Health from the Fitness space, then ask again.")
                    .zoroText(.detail).foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).zoroText(.body)
                        Spacer(minLength: ZoroSpace.s.value)
                        Text(row.value).zoroText(.amount).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    if let detail = row.detail { Text(detail).zoroText(.caption).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
            }
            if let plan = model.planLine { Text(plan).zoroText(.detail) }
            ForEach(model.observations, id: \.self) { Text($0).zoroText(.zoroBody).fixedSize(horizontal: false, vertical: true) }
            VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                Text(model.sourceLine).zoroText(.caption).foregroundStyle(.secondary)
                if let stale = model.staleNote {
                    Label(stale, systemImage: "clock.badge.exclamationmark").zoroText(.caption)
                        .foregroundStyle(ZoroRole.attention.hue.color(scheme: scheme, contrast: .increased))
                }
                Text(FitnessCardModel.disclaimer).zoroText(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
