import Foundation

import ZoroCore

// `PhotoMediaKind` (what an asset is) and `PhotoQuery.Media` (the contract's `media` filter) come from ZoroCore.

/// One asset as the library reports it (metadata only, no pixels).
public struct LibraryAsset: Sendable, Equatable, Hashable {
    /// PhotoKit local identifier.
    public var id: String
    public var capturedAt: Date?
    public var modifiedAt: Date?
    public var kind: PhotoMediaKind
    public var hasLocation: Bool

    public init(id: String, capturedAt: Date?, modifiedAt: Date?, kind: PhotoMediaKind, hasLocation: Bool) {
        self.id = id
        self.capturedAt = capturedAt
        self.modifiedAt = modifiedAt
        self.kind = kind
        self.hasLocation = hasLocation
    }
}

/// A classification label with its confidence (0...1).
public struct VisualLabel: Sendable, Equatable, Hashable {
    public var name: String
    public var confidence: Double
    public init(name: String, confidence: Double) {
        self.name = name
        self.confidence = confidence
    }
}

/// What the image analyser (Vision) found in one image.
public struct VisualAnalysis: Sendable, Equatable {
    public var labels: [VisualLabel]
    /// Recognised text lines, in reading order.
    public var textLines: [String]
    /// Image feature print as 32-bit floats (Vision's L2-comparable vector), nil when unavailable.
    public var featurePrint: [Float]?

    public init(labels: [VisualLabel] = [], textLines: [String] = [], featurePrint: [Float]? = nil) {
        self.labels = labels
        self.textLines = textLines
        self.featurePrint = featurePrint
    }
}

/// Image regions colours are kept for: the whole picture and a 3×3 grid, so a small object
/// ("blue cap") can match one part of the image.
public enum ColourRegion: Sendable, Hashable, Codable, CustomStringConvertible {
    case full
    case cell(row: Int, column: Int)

    public static let gridSize = 3

    public var description: String {
        switch self {
        case .full: "full"
        case .cell(let r, let c): "r\(r)c\(c)"
        }
    }

    public init?(_ raw: String) {
        if raw == "full" {
            self = .full
            return
        }
        let chars = Array(raw)
        guard chars.count == 4, chars[0] == "r", chars[2] == "c",
              let r = chars[1].wholeNumberValue, let c = chars[3].wholeNumberValue,
              r < Self.gridSize, c < Self.gridSize
        else { return nil }
        self = .cell(row: r, column: c)
    }
}

/// Share of a region covered by one named colour.
public struct RegionColour: Sendable, Equatable, Hashable {
    public var region: ColourRegion
    public var colour: NamedColour
    /// 0...1 of the region's opaque pixels.
    public var fraction: Double
    public init(region: ColourRegion, colour: NamedColour, fraction: Double) {
        self.region = region
        self.colour = colour
        self.fraction = fraction
    }
}

/// Everything the index keeps about one asset. No image bytes.
public struct IndexedAsset: Sendable, Equatable {
    public var asset: LibraryAsset
    public var labels: [VisualLabel]
    /// Recognised text, already normalised for search.
    public var text: String
    public var colours: [RegionColour]
    public var featurePrint: [Float]?
    public var embedding: [Float]?
    public var embeddingModel: String?
    public var analysisVersion: Int
    /// False when only metadata could be indexed (for example the image is only in iCloud).
    public var analysisComplete: Bool
    public var indexedAt: Date

    public init(
        asset: LibraryAsset, labels: [VisualLabel] = [], text: String = "", colours: [RegionColour] = [],
        featurePrint: [Float]? = nil, embedding: [Float]? = nil, embeddingModel: String? = nil,
        analysisVersion: Int, analysisComplete: Bool, indexedAt: Date
    ) {
        self.asset = asset
        self.labels = labels
        self.text = text
        self.colours = colours
        self.featurePrint = featurePrint
        self.embedding = embedding
        self.embeddingModel = embeddingModel
        self.analysisVersion = analysisVersion
        self.analysisComplete = analysisComplete
        self.indexedAt = indexedAt
    }
}

/// What the store remembers to decide whether an asset needs (re)indexing.
public struct IndexFingerprint: Sendable, Equatable {
    public var modifiedAt: Date?
    public var analysisVersion: Int
    public var analysisComplete: Bool
    public init(modifiedAt: Date?, analysisVersion: Int, analysisComplete: Bool) {
        self.modifiedAt = modifiedAt
        self.analysisVersion = analysisVersion
        self.analysisComplete = analysisComplete
    }
}

/// Why indexing is paused.
public enum IndexPauseReason: String, Sendable, Equatable {
    case lowPowerMode = "low_power_mode"
    case thermalPressure = "thermal_pressure"
}

/// Live progress of the indexer.
public struct IndexProgress: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case indexing
        case paused(IndexPauseReason)
        case failed(String)
    }
    public var state: State
    public var indexedCount: Int
    public var totalCount: Int
    public var lastCompletedAt: Date?

    public init(state: State = .idle, indexedCount: Int = 0, totalCount: Int = 0, lastCompletedAt: Date? = nil) {
        self.state = state
        self.indexedCount = indexedCount
        self.totalCount = totalCount
        self.lastCompletedAt = lastCompletedAt
    }
}

/// Outcome of one indexing pass.
public struct IndexPassReport: Sendable, Equatable {
    public var indexed: Int
    public var metadataOnly: Int
    public var deleted: Int
    public var unchanged: Int
    public var total: Int
    public init(indexed: Int = 0, metadataOnly: Int = 0, deleted: Int = 0, unchanged: Int = 0, total: Int = 0) {
        self.indexed = indexed
        self.metadataOnly = metadataOnly
        self.deleted = deleted
        self.unchanged = unchanged
        self.total = total
    }
}
