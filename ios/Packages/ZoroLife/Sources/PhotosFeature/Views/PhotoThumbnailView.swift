import LifeSupport
import SwiftUI
import ZoroDesign

/// One real photo, loaded from this device by its local identifier. While loading it shows a quiet well; when the photo cannot be
/// read it says so instead of leaving a gap.
struct PhotoThumbnailView: View {
    let assetId: String
    let accessibilityText: String
    @Environment(\.photoThumbnailProvider) private var provider
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: PhotoThumbnail?
    @State private var failed = false

    private let side: CGFloat = 110

    var body: some View {
        ZStack {
            Rectangle().fill(ZoroNeutral.inset)
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                VStack(spacing: ZoroSpace.xs.value) {
                    Image(systemName: "photo.badge.exclamationmark").accessibilityHidden(true)
                    Text("Not on this device").zoroText(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(ZoroSpace.xs.value)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(ZoroRadius.inset.shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failed ? "\(accessibilityText) It is not available on this device." : accessibilityText)
        .accessibilityAddTraits(.isImage)
        .task(id: assetId) {
            thumbnail = nil
            failed = false
            let pixels = side * displayScale * 2
            let result = await provider.thumbnail(for: assetId, targetSize: CGSize(width: pixels, height: pixels))
            if Task.isCancelled { return }
            thumbnail = result
            failed = result == nil
        }
    }
}

/// A wrapping grid of thumbnails.
struct PhotoGrid: View {
    struct Item: Identifiable {
        let id: String
        let accessibilityText: String
    }
    let items: [Item]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: ZoroSpace.s.value)], spacing: ZoroSpace.s.value) {
            ForEach(items) { item in
                PhotoThumbnailView(assetId: item.id, accessibilityText: item.accessibilityText)
            }
        }
    }
}

/// A row of "how it was understood" chips that wraps onto more lines at larger text sizes.
struct ChipFlow: View {
    let chips: [PhotoQueryChip]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: ZoroSpace.s.value, alignment: .leading)], alignment: .leading, spacing: ZoroSpace.s.value) {
            ForEach(chips) { chip in
                ZoroCapsuleLabel(text: chip.label, symbol: chip.symbol)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(chip.accessibilityLabel)
            }
        }
    }
}
