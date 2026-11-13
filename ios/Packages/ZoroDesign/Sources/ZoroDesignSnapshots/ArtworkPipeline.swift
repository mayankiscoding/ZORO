#if canImport(AppKit) && !targetEnvironment(macCatalyst) && DEBUG
import CoreImage
import Foundation
import ZoroDesign

/// Crops, tones and encodes ZORO's photographs.
///
///     scripts/swiftpm.sh ZoroDesign run ZoroDesignSnapshots --artwork <sources-dir> <resources-dir>
///
/// `<sources-dir>` holds the downloaded originals, each named `<fileName>-source.jpg` (see
/// assets/LICENSES.md for where each comes from). Output: one sRGB JPEG per artwork, long edge
/// 1600 px, at most 380 KB, with no metadata.
enum ArtworkPipeline {
    struct Recipe {
        /// Normalised crop, origin top-left.
        let crop: CGRect
        /// Duotone toning: luminance mapped from `shadow` to `highlight`, mixed in by `amount`.
        let shadow: CIColor
        let highlight: CIColor
        let amount: Double
        let saturation: Double
        let brightness: Double
    }

    /// Long edges tried in order; the first that encodes within `maxBytes` at quality 0.5 or more wins.
    static let longEdges: [CGFloat] = [1600, 1440, 1280, 1120, 1024]
    static let maxBytes = 380_000

    // Palette anchors: neel taken towards black for shadows, the spec hues' light ends for highlights.
    static var neelShadow: CIColor { CIColor(red: 0.07, green: 0.08, blue: 0.26) }
    static var morLight: CIColor { CIColor(red: 0.86, green: 0.96, blue: 0.95) }
    static var neelLight: CIColor { CIColor(red: 0.66, green: 0.69, blue: 1.0) }
    static var gendaLight: CIColor { CIColor(red: 1.0, green: 0.86, blue: 0.55) }

    static func recipe(_ artwork: ZoroArtwork) -> Recipe {
        switch artwork {
        case .peacockEye:
            Recipe(crop: CGRect(x: 0.04, y: 0.08, width: 0.92, height: 0.84), shadow: neelShadow, highlight: morLight,
                   amount: 0.16, saturation: 1.0, brightness: 0)
        case .peacockPlumage:
            Recipe(crop: CGRect(x: 0.22, y: 0.3, width: 0.56, height: 0.7), shadow: neelShadow, highlight: morLight,
                   amount: 0.2, saturation: 0.95, brightness: 0)
        case .indigoCloth:
            Recipe(crop: CGRect(x: 0, y: 0.2, width: 1, height: 0.6), shadow: neelShadow, highlight: neelLight,
                   amount: 0.7, saturation: 1.05, brightness: -0.02)
        case .marigoldPetals:
            Recipe(crop: CGRect(x: 0, y: 0, width: 1, height: 1), shadow: neelShadow, highlight: gendaLight,
                   amount: 0.14, saturation: 0.97, brightness: 0)
        case .marigoldBloom:
            Recipe(crop: CGRect(x: 0.3, y: 0.2, width: 0.7, height: 0.8), shadow: neelShadow, highlight: gendaLight,
                   amount: 0.3, saturation: 0.95, brightness: 0)
        }
    }

    static func run(sources: URL, output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let context = CIContext(options: [.workingColorSpace: Pixels.sRGB, .outputColorSpace: Pixels.sRGB])
        for artwork in ZoroArtwork.allCases {
            let source = sources.appendingPathComponent("\(artwork.fileName)-source.jpg")
            let original = try Pixels.load(source)
            let url = output.appendingPathComponent("\(artwork.fileName).\(ZoroArtwork.fileExtension)")
            var result: (CGImage, Double)?
            for edge in longEdges where result == nil {
                let processed = try process(original, recipe: recipe(artwork), longEdge: edge, context: context)
                if let quality = try? Pixels.writeJPEG(processed, to: url, maxBytes: maxBytes) { result = (processed, quality) }
            }
            guard let (processed, quality) = result else { throw SnapshotError.tooLarge(url.lastPathComponent) }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("wrote \(url.lastPathComponent) \(processed.width)x\(processed.height) q\(String(format: "%.2f", quality)) \(bytes / 1024) KB")
        }
    }

    static func process(_ image: CGImage, recipe r: Recipe, longEdge: CGFloat, context: CIContext) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Core Image's origin is bottom-left; the recipe's is top-left.
        let crop = CGRect(x: r.crop.minX * w, y: (1 - r.crop.maxY) * h, width: r.crop.width * w, height: r.crop.height * h).integral
        var ci = CIImage(cgImage: image).cropped(to: crop)
        ci = ci.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scale = min(1, longEdge / max(crop.width, crop.height))
        ci = ci.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        // The sources are sharpened for print; take the edge off the sharpening halos so the JPEG
        // spends its bytes on the feather, not on noise. Clamp first so the edges do not darken.
        let extentBefore = ci.extent
        ci = ci.clampedToExtent()
            .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.03, kCIInputSharpnessKey: 0.15])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.45])
            .cropped(to: extentBefore)
        let toned = ci.applyingFilter("CIFalseColor", parameters: ["inputColor0": r.shadow, "inputColor1": r.highlight])
        ci = ci.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: toned, kCIInputTimeKey: r.amount])
        ci = ci.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: r.saturation, kCIInputBrightnessKey: r.brightness, kCIInputContrastKey: 1.0,
        ])
        // Drop one pixel on every side: Lanczos leaves a partly transparent edge.
        let extent = CGRect(x: 1, y: 1, width: (crop.width * scale).rounded(.down) - 2, height: (crop.height * scale).rounded(.down) - 2)
        guard let out = context.createCGImage(ci, from: extent, format: .RGBA8, colorSpace: Pixels.sRGB) else {
            throw SnapshotError.noImage("artwork")
        }
        // Flatten to opaque RGB so the JPEG carries no alpha.
        return try Pixels.redraw(out, width: out.width, height: out.height, alpha: false)
    }
}
#endif
