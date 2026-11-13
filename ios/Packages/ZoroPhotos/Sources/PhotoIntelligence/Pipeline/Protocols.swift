import CoreGraphics
import Foundation
import ZoroCore

/// A decoded, small image ready for analysis. CGImage is immutable, so sharing it is safe.
public struct AnalysisImage: @unchecked Sendable {
    public let cgImage: CGImage
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }
}

/// The photo library (PhotoKit on device; in-memory fakes in tests).
public protocol PhotoLibraryProviding: Sendable {
    func authorizationStatus() async -> MediaAuthorization
    /// Shows the system prompt only when the status is not determined.
    func requestAuthorization() async -> MediaAuthorization
    /// Every still image the app can currently read (only the selected ones in a limited library).
    func fetchAssets() async throws -> [LibraryAsset]
    /// The subset of `ids` the app can still read.
    func accessibleIdentifiers(among ids: [String]) async -> Set<String>
    /// A small rendition (longer side about `maxPixelSize`), nil when none is available on the device
    /// (for example an iCloud-only original: indexing never downloads).
    func thumbnail(for assetId: String, maxPixelSize: Int) async throws -> AnalysisImage?
    /// Fires when the library or the limited selection changes.
    func changes() -> AsyncStream<Void>
}

/// On-device image understanding (Vision on device; fakes in tests).
public protocol ImageAnalyzing: Sendable {
    func analyze(_ image: AnalysisImage) async throws -> VisualAnalysis
}

/// Optional text-image embedding model (a CLIP-style Core ML model the owner may add).
/// None is bundled: model weights need a licence check before shipping. The index works without it.
public protocol ImageTextEmbedder: Sendable {
    /// Stored with every embedding; a different model id means stored vectors are not comparable.
    var modelIdentifier: String { get }
    func embed(image: AnalysisImage) async throws -> [Float]
    func embed(text: String) async throws -> [Float]
}

/// Converts a small image into RGBA pixels for colour analysis.
public protocol PixelSampling: Sendable {
    func pixels(of image: AnalysisImage, maxSide: Int) -> PixelBuffer?
}

/// Device power and thermal state.
public struct PowerCondition: Sendable, Equatable {
    public enum Thermal: Int, Sendable, Comparable {
        case nominal, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }
    public var lowPowerMode: Bool
    public var thermal: Thermal
    public init(lowPowerMode: Bool = false, thermal: Thermal = .nominal) {
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
    }
}

public protocol PowerMonitoring: Sendable {
    func current() async -> PowerCondition
    /// Yields whenever the power or thermal state changes.
    func changes() -> AsyncStream<PowerCondition>
}

/// Battery rules for indexing: pause in Low Power Mode or under serious thermal pressure, and run
/// one image at a time when the device is warm.
public enum IndexingPolicy {
    public static func pauseReason(_ c: PowerCondition) -> IndexPauseReason? {
        if c.lowPowerMode { return .lowPowerMode }
        if c.thermal >= .serious { return .thermalPressure }
        return nil
    }

    public static func concurrency(_ c: PowerCondition, maximum: Int) -> Int {
        c.thermal >= .fair ? 1 : max(1, maximum)
    }
}

/// Picks OCR languages from what the OS supports, in the owner's preference order. Hindi is used
/// only when the running OS offers it (Vision's list differs between OS versions).
public enum TextRecognitionLanguages {
    public static let preferred = ["en-IN", "en-US", "en-GB", "hi-IN", "hi"]

    public static func select(supported: [String], preferred: [String] = preferred) -> [String] {
        var chosen: [String] = []
        for want in preferred {
            let base = want.split(separator: "-").first.map(String.init) ?? want
            let exact = supported.first { $0.caseInsensitiveCompare(want) == .orderedSame }
            let sameLanguage = supported.first {
                ($0.split(separator: "-").first.map(String.init) ?? $0).caseInsensitiveCompare(base) == .orderedSame
            }
            if let pick = exact ?? sameLanguage, !chosen.contains(pick) { chosen.append(pick) }
        }
        return chosen
    }
}

/// Decides what an indexing pass has to do.
public struct IndexPlan: Sendable, Equatable {
    /// Newest first; assets whose earlier analysis was incomplete come last.
    public var toIndex: [LibraryAsset]
    /// Indexed assets no longer readable (deleted, or removed from a limited selection).
    public var toDelete: [String]
    public var unchanged: Int

    public static func make(library: [LibraryAsset], indexed: [String: IndexFingerprint], analysisVersion: Int) -> IndexPlan {
        var fresh: [LibraryAsset] = []
        var retry: [LibraryAsset] = []
        var unchanged = 0
        var seen = Set<String>()
        for asset in library where seen.insert(asset.id).inserted {
            guard let print = indexed[asset.id] else {
                fresh.append(asset)
                continue
            }
            if print.modifiedAt != asset.modifiedAt || print.analysisVersion < analysisVersion {
                fresh.append(asset)
            } else if !print.analysisComplete {
                retry.append(asset)
            } else {
                unchanged += 1
            }
        }
        let newest: (LibraryAsset, LibraryAsset) -> Bool = {
            ($0.capturedAt ?? .distantPast, $1.id) > ($1.capturedAt ?? .distantPast, $0.id)
        }
        let toDelete = indexed.keys.filter { !seen.contains($0) }.sorted()
        return IndexPlan(toIndex: fresh.sorted(by: newest) + retry.sorted(by: newest), toDelete: toDelete, unchanged: unchanged)
    }
}
