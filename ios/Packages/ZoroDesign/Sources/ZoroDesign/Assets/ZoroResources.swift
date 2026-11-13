import Foundation

/// The files ZoroDesign ships in its resource bundle: the Devanagari serif, artwork and earcons.
/// Every file is listed, with its source and licence, in `assets/LICENSES.md`.
public enum ZoroResources {
    /// The package's resource bundle.
    public static var bundle: Bundle { .module }

    /// A file in the resource bundle, or nil when it is missing (a broken build, never expected).
    public static func url(named name: String, extension ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext)
    }

    /// Every bundled resource by file name, so tests and the gallery can check that each one loads.
    public static let manifest: [String] =
        [ZoroFonts.devanagariSerifFileName + ".ttf", ZoroFonts.devanagariSerifLicenceFileName + ".txt"]
        + ZoroArtwork.allCases.map { $0.fileName + "." + ZoroArtwork.fileExtension }
        + ZoroEarcon.allCases.map { $0.fileName + "." + ZoroEarcon.fileExtension }
}
