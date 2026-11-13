import LifeSupport
import SwiftUI
import ZoroCore
import ZoroDesign

/// The `photo_query` card in a conversation: how the query was understood and the real photos, loaded on this device by
/// their identifiers. The card carries identifiers only, never image data.
public struct PhotoQueryCardView: View {
    let card: UICard

    public init(card: UICard) { self.card = card }

    public var body: some View {
        ZoroCard {
            if card.kind != "photo_query" {
                ZoroStateView(.error, message: "This photo card could not be shown. Ask ZORO again.")
            } else if let payload = try? card.decodePayload(PhotoCardPayload.self) {
                content(payload)
            } else {
                ZoroStateView(.error, message: "This photo card could not be shown. Ask ZORO again.")
            }
        }
    }

    private func content(_ p: PhotoCardPayload) -> some View {
        let chips = PhotoQueryChips.chips(from: p.chips, query: p.query)
        let now = Date()
        return VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            Text(card.title ?? "Photos").zoroText(.heading).accessibilityAddTraits(.isHeader)
            if !chips.isEmpty { ChipFlow(chips: chips) }
            switch p.state {
            case "found":
                PhotoGrid(items: p.hits.map { hit in
                    .init(
                        id: hit.assetId,
                        accessibilityText: PhotoHitPresenter.accessibilityLabel(
                            capturedAt: hit.capturedAt, labels: hit.labels, matched: [], now: now, timeZone: .current))
                })
                Text("These photos are loaded from this device. They are not sent to your server.").zoroText(.caption).foregroundStyle(.secondary)
            case "empty":
                ZoroStateView(
                    .empty,
                    message: (p.indexedCount ?? 0) == 0
                        ? "No photos are indexed yet. Open Photos in Spaces and build the index, then ask again."
                        : "No photos matched. Try fewer words or a different date.")
            default:
                ZoroStateView(.loading, message: "Searching your photos on this device.")
            }
            if p.limitedLibrary == true {
                Label("ZORO can only search the photos you chose. Open Photos in Spaces to choose more.", systemImage: "photo.badge.plus")
                    .zoroText(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
