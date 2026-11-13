#if canImport(AppKit) && !targetEnvironment(macCatalyst) && DEBUG
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum SnapshotError: Error { case noImage(String), writeFailed(String), badSource(String), tooLarge(String) }

/// Pixel-level helpers shared by the snapshot, icon and artwork modes. Every write goes through
/// ImageIO with no metadata dictionary, so nothing from a source file (EXIF, GPS, XMP) survives.
enum Pixels {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    @MainActor
    static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat, scheme: ColorScheme) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
        renderer.scale = scale
        renderer.isOpaque = false
        var image: CGImage?
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        guard let image else { throw SnapshotError.noImage("\(V.self)") }
        return image
    }

    /// Redraws an image at a new pixel size. `alpha: false` flattens onto black and drops the alpha
    /// channel (App Store icons must not have one); `gray: true` writes 8-bit grayscale.
    static func redraw(_ image: CGImage, width: Int, height: Int, alpha: Bool = true, gray: Bool = false) throws -> CGImage {
        let space = gray ? CGColorSpaceCreateDeviceGray() : sRGB
        let info: UInt32 = gray
            ? CGImageAlphaInfo.none.rawValue
            : (alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info
        ) else { throw SnapshotError.noImage("context \(width)x\(height)") }
        ctx.interpolationQuality = .high
        if !alpha || gray {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { throw SnapshotError.noImage("redraw \(width)x\(height)") }
        return out
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try write(image, type: .png, options: [:], to: url)
    }

    /// Writes a JPEG, lowering quality until the file fits `maxBytes`. Returns the quality used.
    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL, maxBytes: Int, startQuality: Double = 0.82) throws -> Double {
        var quality = startQuality
        while quality >= 0.5 {
            try write(image, type: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality], to: url)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? .max
            if size <= maxBytes { return quality }
            quality -= 0.04
        }
        throw SnapshotError.tooLarge(url.lastPathComponent)
    }

    private static func write(_ image: CGImage, type: UTType, options: [CFString: Any], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw SnapshotError.writeFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SnapshotError.writeFailed(url.path) }
    }

    /// Loads an image upright (EXIF orientation applied), at full size up to 8192 px.
    static func load(_ url: URL) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8192,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw SnapshotError.badSource(url.path) }
        return image
    }
}
#endif
