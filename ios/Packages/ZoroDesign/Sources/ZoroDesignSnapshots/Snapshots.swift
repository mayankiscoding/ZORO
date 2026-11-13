#if canImport(AppKit) && !targetEnvironment(macCatalyst) && DEBUG
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ZoroDesign

/// Renders orb states and key components to PNG with ImageRenderer, and builds ZORO's assets.
///
///     scripts/swiftpm.sh ZoroDesign run ZoroDesignSnapshots <output-dir>
///     scripts/swiftpm.sh ZoroDesign run ZoroDesignSnapshots --icons <assets/AppIcon> <review-dir>
///     scripts/swiftpm.sh ZoroDesign run ZoroDesignSnapshots --artwork <sources-dir> <resources-dir>
///
/// Snapshots are at most 900 px wide (points × scale 2).
@main
struct ZoroDesignSnapshots {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first {
            case "--icons":
                guard args.count == 3 else { throw UsageError() }
                try AppIconRenderer.run(iconRoot: URL(fileURLWithPath: args[1], isDirectory: true), reviewDir: URL(fileURLWithPath: args[2], isDirectory: true))
            case "--artwork":
                guard args.count == 3 else { throw UsageError() }
                try ArtworkPipeline.run(sources: URL(fileURLWithPath: args[1], isDirectory: true), output: URL(fileURLWithPath: args[2], isDirectory: true))
            default:
                try snapshots(to: URL(fileURLWithPath: args.first ?? "docs/design/snapshots", isDirectory: true))
            }
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    struct UsageError: Error, CustomStringConvertible {
        var description: String { "usage: ZoroDesignSnapshots [<dir> | --icons <icon-root> <review-dir> | --artwork <sources> <output>]" }
    }

    @MainActor
    static func snapshots(to out: URL) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let registration = ZoroFonts.register()
        print("Devanagari serif: \(registration)")
        let jobs: [(String, CGFloat, ColorScheme, AnyView)] = [
            ("orb-states-dark", 450, .dark, AnyView(GalleryOrbGrid())),
            ("orb-states-light", 450, .light, AnyView(GalleryOrbGrid())),
            ("live-voice-dark", 390, .dark, AnyView(GalleryVoiceStage())),
            ("shopping-light", 420, .light, AnyView(GalleryCommerce())),
            ("controls-states-light", 390, .light, AnyView(VStack(spacing: 24) { GalleryControls(chip: .constant(1)); GalleryStates() })),
            ("agents-approval-dark", 390, .dark, AnyView(VStack(spacing: 24) { GalleryAgents(); GalleryTrust() })),
            ("charts-light", 390, .light, AnyView(GalleryCharts())),
            ("palette-type-light", 450, .light, AnyView(VStack(alignment: .leading, spacing: 24) { GalleryPalette(); GalleryTypeScale() })),
            ("devanagari-light", 420, .light, AnyView(GalleryDevanagari())),
            ("devanagari-dark", 420, .dark, AnyView(GalleryDevanagari())),
            ("welcome-light", 390, .light, AnyView(GalleryWelcome())),
            ("welcome-dark", 390, .dark, AnyView(GalleryWelcome())),
            ("artwork-light", 420, .light, AnyView(GalleryArtwork())),
            ("artwork-dark", 420, .dark, AnyView(GalleryArtwork())),
        ]
        for (name, width, scheme, view) in jobs {
            let url = out.appendingPathComponent("\(name).png")
            let size = try render(view, width: width, scheme: scheme, to: url)
            print("wrote \(url.path) (\(size.width)x\(size.height) px)")
        }
    }

    @MainActor
    static func render(_ view: AnyView, width: CGFloat, scheme: ColorScheme, to url: URL) throws -> CGSize {
        let content = view
            .padding(20)
            .frame(width: width)
            .background(ZoroNeutral.background)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var image: CGImage?
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        guard let cg = image else { throw SnapshotError.noImage(url.lastPathComponent) }
        try Pixels.writePNG(cg, to: url)
        return CGSize(width: cg.width, height: cg.height)
    }
}
#else
/// The snapshot tool is a macOS debug-build host tool (it uses the debug-only gallery specimens).
@main
struct ZoroDesignSnapshots {
    static func main() { print("ZoroDesignSnapshots runs only in macOS debug builds.") }
}
#endif
