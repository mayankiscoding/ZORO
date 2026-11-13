import Foundation
import ImageIO
import SwiftUI

/// ZORO's photographs: few, and each one a material the identity is made of. They appear on the
/// welcome screen and in empty states only, never behind data, prices, numbers or the orb.
///
/// Every file is cropped and toned to the palette (see `assets/tools/README.md`) and listed with its
/// source, author and licence in `assets/LICENSES.md`.
public enum ZoroArtwork: String, CaseIterable, Sendable {
    /// The eye of a peacock tail feather: neel, mor and a ring of bronze. The orb is drawn after it.
    case peacockEye
    /// The scale-like feathers of a peacock's back, gold-green over blue.
    case peacockPlumage
    /// Indigo-dyed cotton twill, toned to neel.
    case indigoCloth
    /// Marigold petals filling the frame.
    case marigoldPetals
    /// One marigold in bloom.
    case marigoldBloom

    /// Where an artwork may be used.
    public enum Use: String, Sendable {
        case welcome, emptyState
    }

    public static let fileExtension = "jpg"

    public var fileName: String {
        switch self {
        case .peacockEye: "zoro-art-peacock-eye"
        case .peacockPlumage: "zoro-art-peacock-plumage"
        case .indigoCloth: "zoro-art-indigo-cloth"
        case .marigoldPetals: "zoro-art-marigold-petals"
        case .marigoldBloom: "zoro-art-marigold-bloom"
        }
    }

    /// A plain description, for the gallery and for anyone replacing the file.
    public var title: String {
        switch self {
        case .peacockEye: "Peacock feather eye"
        case .peacockPlumage: "Peacock back feathers"
        case .indigoCloth: "Indigo cloth"
        case .marigoldPetals: "Marigold petals"
        case .marigoldBloom: "Marigold in bloom"
        }
    }

    public var uses: Set<Use> {
        switch self {
        case .peacockEye, .marigoldPetals: [.welcome, .emptyState]
        case .peacockPlumage, .indigoCloth, .marigoldBloom: [.emptyState]
        }
    }

    /// The part of the picture to keep when a frame crops it.
    public var focus: Alignment {
        switch self {
        case .peacockEye: .leading
        case .peacockPlumage: .bottom
        case .indigoCloth, .marigoldPetals: .center
        case .marigoldBloom: .trailing
        }
    }

    /// The hue that stands in while the image loads or if it cannot be decoded.
    public var fallbackHue: ZoroHue {
        switch self {
        case .peacockEye, .indigoCloth: .neel
        case .peacockPlumage: .mor
        case .marigoldPetals, .marigoldBloom: .genda
        }
    }

    /// Credit line, as recorded in `assets/LICENSES.md`. Not required by the licences; shown in the
    /// app's acknowledgements.
    public var credit: String {
        switch self {
        case .peacockEye, .peacockPlumage: "Bernard Spragg, CC0, via Wikimedia Commons"
        case .indigoCloth: "colormass and Rico Cilliers, CC0, via Poly Haven"
        case .marigoldPetals: "Ramya Srivastav, CC0, via Wikimedia Commons"
        case .marigoldBloom: "Jesselikesweather, CC0, via Wikimedia Commons"
        }
    }

    public static func artworks(for use: Use) -> [ZoroArtwork] { allCases.filter { $0.uses.contains(use) } }

    public var url: URL? { ZoroResources.url(named: fileName, extension: Self.fileExtension) }

    /// The decoded image, at most `maxPixelSize` on its long edge, cached after the first load.
    /// Nil only if the bundle is broken; views then show `fallbackHue`.
    public func cgImage(maxPixelSize: Int = 2048) -> CGImage? {
        let key = "\(rawValue)@\(maxPixelSize)" as NSString
        if let cached = ZoroArtworkCache.images.object(forKey: key) { return cached }
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        ZoroArtworkCache.images.setObject(image, forKey: key)
        return image
    }
}

private enum ZoroArtworkCache {
    /// NSCache is thread-safe; it drops images under memory pressure.
    nonisolated(unsafe) static let images = NSCache<NSString, CGImage>()
}

/// A ZORO photograph that fills its frame, cropped around the artwork's focus. Decorative: hidden
/// from VoiceOver. In dark mode it is dimmed so it never outshines the content beside it.
///
/// Give it a frame and a shape; never put text, numbers or controls on top of it.
public struct ZoroArtworkView: View {
    /// How loudly the photograph speaks. Use `.quiet` wherever the orb is on screen too, so the orb
    /// stays the one bold element.
    public enum Emphasis: Sendable { case standard, quiet }

    let artwork: ZoroArtwork
    let emphasis: Emphasis

    public init(_ artwork: ZoroArtwork) {
        self.init(artwork, emphasis: .standard)
    }

    public init(_ artwork: ZoroArtwork, emphasis: Emphasis) {
        self.artwork = artwork
        self.emphasis = emphasis
    }

    @Environment(\.colorScheme) private var scheme

    private var dim: Double {
        switch (scheme, emphasis) {
        case (.dark, .quiet): 0.4
        case (.dark, _): 0.22
        case (_, .quiet): 0.08
        default: 0
        }
    }

    public var body: some View {
        Rectangle()
            .fill(ZoroColor(artwork.fallbackHue).opacity(0.25))
            .overlay(alignment: artwork.focus) {
                if let image = artwork.cgImage() {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .saturation(emphasis == .quiet ? 0.55 : 1)
                }
            }
            .overlay { Color.black.opacity(dim) }
            .clipped()
            .accessibilityHidden(true)
    }
}

/// An empty state with a photograph above it: the artwork in a band, then the state's one sentence
/// and optional action, left-aligned. For empty states only; loading, error and disconnected states
/// stay plain so the photograph never stands next to a problem.
public struct ZoroIllustratedEmptyState: View {
    let artwork: ZoroArtwork
    let message: String
    let action: ZoroStateAction?
    @ScaledMetric(relativeTo: .body) private var bandHeight: CGFloat = 132

    public init(_ artwork: ZoroArtwork, message: String, action: ZoroStateAction? = nil) {
        self.artwork = artwork
        self.message = message
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZoroArtworkView(artwork)
                .frame(height: bandHeight)
                .frame(maxWidth: .infinity)
                .clipShape(ZoroRadius.control.shape)
            ZoroStateView(.empty, message: message, action: action)
        }
    }
}
