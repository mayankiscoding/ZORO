#if canImport(AppKit) && !targetEnvironment(macCatalyst) && DEBUG
import CoreImage
import Foundation
import SwiftUI
import ZoroDesign

/// Renders ZORO's app icon from the orb itself and writes ready-to-copy icon sets.
///
///     scripts/swiftpm.sh ZoroDesign run ZoroDesignSnapshots --icons <repo>/assets/AppIcon <review-dir>
///
/// Writes `master/` (1024 px masters), `ios/AppIcon.appiconset` (light, dark, tinted; the
/// single-size format of current asset catalogs) and `macos/AppIcon.appiconset` (16 to 1024 px),
/// plus `app-icon-review.png` in `<review-dir>`: every variant at the sizes people will see.
enum AppIconRenderer {
    enum Variant: String, CaseIterable {
        case iosLight = "ios-light", iosDark = "ios-dark", iosTinted = "ios-tinted", macOS = "macos"
    }

    static let master: CGFloat = 1024
    /// One frozen frame of the orb at full iridescence (the state it takes while agents work, with no
    /// satellites), chosen so the mor band and the genda thread read as unbroken rings.
    static let orbState: OrbState = .delegating
    static let orbTime: Double = 8.2

    /// The pale ground of the light icon: white drawn towards neel, top to bottom.
    static let groundTop = Color(red: 0.972, green: 0.973, blue: 0.992)
    static let groundBottom = Color(red: 0.906, green: 0.914, blue: 0.965)

    @MainActor
    static func run(iconRoot: URL, reviewDir: URL) throws {
        let fm = FileManager.default
        let iosSet = iconRoot.appendingPathComponent("ios/AppIcon.appiconset")
        let macSet = iconRoot.appendingPathComponent("macos/AppIcon.appiconset")
        for dir in [iosSet, macSet, reviewDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        var masters: [Variant: CGImage] = [:]
        for variant in Variant.allCases {
            let image = try renderMaster(variant)
            masters[variant] = image
        }

        // iOS: one 1024 px image per appearance; the system derives every other size.
        let iosFiles: [(Variant, String)] = [(.iosLight, "AppIcon-1024.png"), (.iosDark, "AppIcon-dark-1024.png"), (.iosTinted, "AppIcon-tinted-1024.png")]
        for (variant, name) in iosFiles {
            try Pixels.writePNG(masters[variant]!, to: iosSet.appendingPathComponent(name))
        }
        try IconSetManifest.iOS.write(to: iosSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

        // macOS: every point size at 1x and 2x.
        for entry in IconSetManifest.macEntries {
            let px = entry.pixels
            let image = try Pixels.redraw(masters[.macOS]!, width: px, height: px)
            try Pixels.writePNG(image, to: macSet.appendingPathComponent(entry.fileName))
        }
        try IconSetManifest.macOS.write(to: macSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

        try writeReview(masters, to: reviewDir.appendingPathComponent("app-icon-review.png"))
        print("wrote icon sets to \(iconRoot.path)")
    }

    @MainActor
    static func renderMaster(_ variant: Variant) throws -> CGImage {
        let size = CGSize(width: master, height: master)
        switch variant {
        case .iosLight:
            let image = try Pixels.render(IconArt(ground: .pale, lineScheme: .light), size: size, scale: 1, scheme: .light)
            return try Pixels.redraw(image, width: Int(master), height: Int(master), alpha: false)
        case .iosDark:
            return try Pixels.render(IconArt(ground: .clear, lineScheme: .dark), size: size, scale: 1, scheme: .dark)
        case .iosTinted:
            // Tinted icons are grayscale; the system tints by luminance, so the orb must be the
            // brightest thing: render the dark orb on black, drop colour and lift its midtones.
            let image = try Pixels.render(IconArt(ground: .black, lineScheme: .dark), size: size, scale: 1, scheme: .dark)
            let lifted = CIImage(cgImage: image)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.1])
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.55])
            let ctx = CIContext(options: [.workingColorSpace: Pixels.sRGB])
            guard let cg = ctx.createCGImage(lifted, from: CGRect(origin: .zero, size: size)) else { throw SnapshotError.noImage("tinted") }
            return try Pixels.redraw(cg, width: Int(master), height: Int(master), gray: true)
        case .macOS:
            return try Pixels.render(MacIconArt(), size: size, scale: 1, scheme: .light)
        }
    }

    /// Every variant at the sizes it is seen: Home Screen (180, 120), Spotlight (80), Settings (58),
    /// notifications (40), and the Mac Dock and Finder (128, 64, 32, 16).
    @MainActor
    static func writeReview(_ masters: [Variant: CGImage], to url: URL) throws {
        let rows: [(Variant, ColorScheme, [Int])] = [
            (.iosLight, .light, [180, 120, 80, 58, 40]),
            (.iosDark, .dark, [180, 120, 80, 58, 40]),
            (.iosTinted, .dark, [180, 120, 80, 58, 40]),
            (.macOS, .light, [256, 128, 64, 32, 16]),
        ]
        var images: [[(CGImage, Int)]] = []
        for (variant, _, sizes) in rows {
            images.append(try sizes.map { (try Pixels.redraw(masters[variant]!, width: $0, height: $0), $0) })
        }
        let sheet = IconReviewSheet(rows: rows.indices.map { i in (rows[i].0.rawValue, rows[i].1, images[i]) })
        let image = try Pixels.render(sheet, size: CGSize(width: 860, height: 1080), scale: 1, scheme: .light)
        try Pixels.writePNG(image, to: url)
    }
}

/// The icon artwork: the orb, larger than it ever is in the app, rising from the rekha. The orb is
/// always drawn with its light-appearance hues: deep neel, saturated mor and genda hold their
/// colour on both the pale ground and the system's dark icon ground, where the dark-appearance
/// hues turn lavender.
struct IconArt: View {
    enum Ground { case pale, clear, black }
    let ground: Ground
    let lineScheme: ColorScheme

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                switch ground {
                case .pale:
                    LinearGradient(colors: [AppIconRenderer.groundTop, AppIconRenderer.groundBottom], startPoint: .top, endPoint: .bottom)
                case .clear: Color.clear
                case .black: Color.black
                }
                // The rekha: one horizontal line, drawn under the orb so only its two ends show.
                Rectangle()
                    .fill(ZoroHue.neel.color(scheme: lineScheme, contrast: .standard).opacity(lineScheme == .dark ? 0.6 : 0.4))
                    .frame(width: side * 0.84, height: max(1, side * 0.012))
                    .offset(y: side * 0.25)
                OrbCanvas(state: AppIconRenderer.orbState, time: AppIconRenderer.orbTime)
                    .environment(\.colorScheme, .light)
                    .frame(width: side * 1.5, height: side * 1.5)
                    .offset(y: -side * 0.02)
            }
            .frame(width: side, height: side)
            .clipped()
        }
    }
}

/// macOS icons are a rounded square on a transparent canvas, inset to Apple's 824 px grid, with
/// the system's soft drop shadow.
struct MacIconArt: View {
    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            let tile = side * 824 / 1024
            IconArt(ground: .pale, lineScheme: .light)
                .frame(width: tile, height: tile)
                .clipShape(RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.28), radius: side * 0.012, y: side * 0.01)
                .frame(width: side, height: side)
        }
    }
}

struct IconReviewSheet: View {
    let rows: [(String, ColorScheme, [(CGImage, Int)])]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 12) {
                    Text(row.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(row.1 == .dark ? .white : .black)
                    HStack(alignment: .bottom, spacing: 20) {
                        ForEach(Array(row.2.enumerated()), id: \.offset) { _, item in
                            let mask = row.0.hasPrefix("ios")
                            Image(decorative: item.0, scale: 1)
                                .frame(width: CGFloat(item.1), height: CGFloat(item.1))
                                .clipShape(RoundedRectangle(cornerRadius: mask ? CGFloat(item.1) * 0.225 : 0, style: .continuous))
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(row.1 == .dark ? Color(white: 0.11) : Color(white: 0.95))
            }
        }
    }
}

/// Contents.json for both sets, in the format Xcode 16 and later write.
enum IconSetManifest {
    struct MacEntry {
        let points: Int, scale: Int
        var pixels: Int { points * scale }
        var fileName: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
    }

    static let macEntries: [MacEntry] = [16, 32, 128, 256, 512].flatMap { [MacEntry(points: $0, scale: 1), MacEntry(points: $0, scale: 2)] }

    static let iOS = """
    {
      "images" : [
        {
          "filename" : "AppIcon-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        },
        {
          "appearances" : [
            {
              "appearance" : "luminosity",
              "value" : "dark"
            }
          ],
          "filename" : "AppIcon-dark-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        },
        {
          "appearances" : [
            {
              "appearance" : "luminosity",
              "value" : "tinted"
            }
          ],
          "filename" : "AppIcon-tinted-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """

    static var macOS: String {
        let images = macEntries.map { e in
            """
                {
                  "filename" : "\(e.fileName)",
                  "idiom" : "mac",
                  "scale" : "\(e.scale)x",
                  "size" : "\(e.points)x\(e.points)"
                }
            """
        }.joined(separator: ",\n")
        return """
        {
          "images" : [
        \(images)
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }

        """
    }
}
#endif
