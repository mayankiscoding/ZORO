import AVFoundation
import CoreText
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import ZoroDesign

/// Paths in the repository, found from this file so the tests run from any working directory.
enum RepoPaths {
    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let root = package.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let resources = package.appendingPathComponent("Sources/ZoroDesign/Resources")
    static let licences = root.appendingPathComponent("assets/LICENSES.md")
    static let appIcon = root.appendingPathComponent("assets/AppIcon")

    /// Every regular file under a folder, as paths relative to `base`, ignoring Finder litter.
    static func files(under folder: URL, relativeTo base: URL) -> Set<String> {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: Set<String> = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            guard url.lastPathComponent != ".DS_Store" else { continue }
            out.insert(String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1)))
        }
        return out
    }
}

@Suite("Bundled resources")
struct ResourceTests {
    @Test("every manifest entry loads from the package bundle", arguments: ZoroResources.manifest)
    func loads(fileName: String) throws {
        let name = (fileName as NSString).deletingPathExtension, ext = (fileName as NSString).pathExtension
        let url = try #require(ZoroResources.url(named: name, extension: ext), "\(fileName) missing from Bundle.module")
        let data = try Data(contentsOf: url)
        #expect(!data.isEmpty)
    }

    @Test("the manifest and the Resources folder hold exactly the same files")
    func manifestMatchesFolder() {
        let onDisk = Set(RepoPaths.files(under: RepoPaths.resources, relativeTo: RepoPaths.resources).map { ($0 as NSString).lastPathComponent })
        #expect(onDisk == Set(ZoroResources.manifest))
    }

    @Test("every file under Resources is listed in assets/LICENSES.md")
    func everyResourceIsLicensed() throws {
        let listed = try LicenceTable.load().files
        let resources = RepoPaths.files(under: RepoPaths.resources, relativeTo: RepoPaths.root)
        #expect(!resources.isEmpty)
        let missing = resources.subtracting(listed)
        #expect(missing.isEmpty, "not in LICENSES.md: \(missing.sorted())")
    }

    @Test("every app icon file is listed in assets/LICENSES.md, and nothing listed is missing")
    func everyIconIsLicensedAndPresent() throws {
        let table = try LicenceTable.load()
        let icons = RepoPaths.files(under: RepoPaths.appIcon, relativeTo: RepoPaths.root)
        #expect(icons.subtracting(table.files).isEmpty, "not in LICENSES.md: \(icons.subtracting(table.files).sorted())")
        for path in table.files {
            #expect(FileManager.default.fileExists(atPath: RepoPaths.root.appendingPathComponent(path).path), "listed but missing: \(path)")
        }
    }

    @Test("every licence row names an accepted licence")
    func licencesAreAccepted() throws {
        let accepted = ["CC0 1.0", "SIL Open Font License 1.1", "Original work"]
        for row in try LicenceTable.load().rows {
            #expect(accepted.contains(where: row.licence.contains), "\(row.file): \(row.licence)")
        }
    }
}

@Suite("Devanagari serif")
struct FontTests {
    @Test("registers, resolves by PostScript name and covers Devanagari")
    func registersAndResolves() throws {
        #expect(ZoroFonts.register() == .registered)
        #expect(ZoroFonts.register() == .registered, "registration is idempotent")
        #expect(ZoroFonts.resolvesDevanagariSerif())
        let font = CTFontCreateWithName(ZoroFonts.devanagariSerifPostScriptName as CFString, 20, nil)
        let text = Array("नमस्ते ज़ोरो। ०१२".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: text.count)
        #expect(CTFontGetGlyphsForCharacters(font, text, &glyphs, text.count))
        #expect(!glyphs.contains(0))
    }

    @Test("registering the same file again is not an error")
    func alreadyRegistered() {
        ZoroFonts.register()
        let url = ZoroResources.url(named: ZoroFonts.devanagariSerifFileName, extension: "ttf")
        #expect(ZoroFonts.performRegistration(url: url) == .registered)
    }

    @Test("a missing file is a typed unavailable result")
    func missingFile() {
        let result = ZoroFonts.performRegistration(url: nil)
        #expect(!result.isRegistered)
        if case .unavailable(let reason) = result { #expect(reason.contains("missing")) } else { Issue.record("expected unavailable") }
    }

    @Test("a file that is not a font is a typed unavailable result")
    func notAFont() throws {
        let url = try #require(ZoroResources.url(named: ZoroFonts.devanagariSerifLicenceFileName, extension: "txt"))
        #expect(!ZoroFonts.performRegistration(url: url).isRegistered)
    }

    @Test("default point sizes match the platform's Dynamic Type table")
    func basePointSizes() {
        #if os(macOS)
        #expect(ZoroTextStyle.defaultPointSize(.body) == 13)
        #expect(ZoroTextStyle.defaultPointSize(.title2) == 17)
        #else
        #expect(ZoroTextStyle.defaultPointSize(.body) == 17)
        #expect(ZoroTextStyle.defaultPointSize(.title2) == 22)
        #endif
    }
}

@Suite("Script runs")
struct ScriptTests {
    @Test("a Hindi sentence is one Devanagari run, danda and spaces included")
    func hindi() {
        let runs = ZoroScript.runs(in: "पिछले महीने से कम खर्च हुआ।")
        #expect(runs == [ZoroScript.Run(text: "पिछले महीने से कम खर्च हुआ।", isDevanagari: true)])
    }

    @Test("a Hinglish line splits only where the script changes")
    func mixed() {
        let runs = ZoroScript.runs(in: "कल 7 बजे Ma को call करूँगा")
        #expect(runs.map(\.isDevanagari) == [true, false, true, false, true])
        #expect(runs.map(\.text).joined() == "कल 7 बजे Ma को call करूँगा")
        #expect(runs[0].text == "कल 7 बजे ")
        #expect(runs[1].text == "Ma ")
    }

    @Test("leading punctuation joins the first real run; Latin-only and empty text")
    func edges() {
        #expect(ZoroScript.runs(in: "“नमस्ते”").map(\.isDevanagari) == [true])
        #expect(ZoroScript.runs(in: "Hello, ZORO.") == [ZoroScript.Run(text: "Hello, ZORO.", isDevanagari: false)])
        #expect(ZoroScript.runs(in: "") == [])
        #expect(ZoroScript.runs(in: "₹ 231.50") == [ZoroScript.Run(text: "₹ 231.50", isDevanagari: false)])
        #expect(!ZoroScript.containsDevanagari("ZORO"))
        #expect(ZoroScript.containsDevanagari("ZORO ज़ोरो"))
    }

    @Test("ZORO's styles set the Devanagari serif on Devanagari runs only")
    func attributed() {
        let text = ZoroTextStyle.zoroVoice.attributed("कल Ma को")
        let fonts = text.runs.map { $0.swiftUI.font }
        #expect(fonts.count == 3)
        #expect(fonts[0] != nil && fonts[1] == nil && fonts[2] != nil)
        #expect(String(text.characters) == "कल Ma को")
    }

    @Test("the owner's and interface styles keep the system font")
    func systemStylesUntouched() {
        for style in [ZoroTextStyle.ownerVoice, .body, .title, .caption] {
            #expect(style.attributed("कल Ma को").runs.allSatisfy { $0.swiftUI.font == nil })
        }
    }
}

@Suite("Artwork")
struct ArtworkTests {
    @Test("every artwork decodes, is opaque RGB, and is at most 400 KB", arguments: ZoroArtwork.allCases)
    func decodes(artwork: ZoroArtwork) throws {
        let url = try #require(artwork.url)
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(bytes <= 400_000)
        let image = try #require(artwork.cgImage())
        #expect(image.width >= 1000)
        // ImageIO rounds the thumbnail's long edge, so allow one pixel.
        #expect((255...256).contains(artwork.cgImage(maxPixelSize: 256).map { max($0.width, $0.height) } ?? 0))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyGPSDictionary] == nil, "metadata must be stripped")
        #expect(props[kCGImagePropertyExifDictionary].map { ($0 as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil } ?? true)
    }

    @Test("every use has artwork, and welcome artwork is a subset of the catalogue")
    func uses() {
        #expect(!ZoroArtwork.artworks(for: .welcome).isEmpty)
        #expect(ZoroArtwork.artworks(for: .emptyState).count == ZoroArtwork.allCases.count)
        #expect(Set(ZoroArtwork.allCases.map(\.fileName)).count == ZoroArtwork.allCases.count)
    }
}

@Suite("Earcons")
struct EarconTests {
    @Test("every earcon is under 60 KB and under one second", arguments: ZoroEarcon.allCases)
    func loads(earcon: ZoroEarcon) throws {
        let url = try #require(earcon.url)
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(bytes < 60_000)
        let player = try AVAudioPlayer(contentsOf: url)
        #expect(player.duration > 0.2 && player.duration < 1)
    }

    @MainActor
    @Test("earcons are off by default and say so")
    func offByDefault() {
        let player = ZoroEarconPlayer()
        #expect(!player.isEnabled)
        for earcon in ZoroEarcon.allCases { #expect(player.play(earcon) == .disabled) }
        #expect(player.preload().isEmpty)
    }
}

@Suite("App icon sets")
struct AppIconTests {
    @Test("each icon set contains every size its Contents.json declares", arguments: ["ios", "macos"])
    func sizesMatch(platform: String) throws {
        let set = RepoPaths.appIcon.appendingPathComponent("\(platform)/AppIcon.appiconset")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: set.appendingPathComponent("Contents.json"))) as? [String: Any]
        let images = try #require(json?["images"] as? [[String: Any]])
        #expect(images.count == (platform == "ios" ? 3 : 10))
        var declared: Set<String> = []
        for entry in images {
            let file = try #require(entry["filename"] as? String)
            declared.insert(file)
            let points = try #require((entry["size"] as? String)?.split(separator: "x").first.flatMap { Double($0) })
            let scale = Double((entry["scale"] as? String)?.dropLast() ?? "1") ?? 1
            let source = try #require(CGImageSourceCreateWithURL(set.appendingPathComponent(file) as CFURL, nil), "\(file) missing")
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(props[kCGImagePropertyPixelWidth] as? Int == Int(points * scale), "\(file)")
            #expect(props[kCGImagePropertyPixelHeight] as? Int == Int(points * scale), "\(file)")
            if file == "AppIcon-1024.png" {
                #expect(props[kCGImagePropertyHasAlpha] as? Bool != true, "the App Store icon must not have an alpha channel")
            }
        }
        let pngs = Set(try FileManager.default.contentsOfDirectory(atPath: set.path).filter { $0.hasSuffix(".png") })
        #expect(pngs == declared, "files on disk that Contents.json does not declare, or the reverse")
    }
}

/// The licence table in assets/LICENSES.md: rows whose first cell is a backticked repo path.
struct LicenceTable {
    struct Row { let file: String; let licence: String }
    let rows: [Row]
    var files: Set<String> { Set(rows.map(\.file)) }

    static func load() throws -> LicenceTable {
        let text = try String(contentsOf: RepoPaths.licences, encoding: .utf8)
        var rows: [Row] = []
        var licenceColumn: Int?
        for line in text.split(separator: "\n") where line.hasPrefix("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let index = cells.firstIndex(of: "Licence") { licenceColumn = index; continue }
            guard let first = cells.first, first.hasPrefix("`"), first.hasSuffix("`"), let column = licenceColumn, column < cells.count else { continue }
            rows.append(Row(file: String(first.dropFirst().dropLast()), licence: cells[column]))
        }
        return LicenceTable(rows: rows)
    }
}
