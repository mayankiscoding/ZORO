import Foundation
import ZoroCore

// Mirrors backend/app/vision (schemas.py, summaries.py). Only text and photo identifiers cross the API; there is no field that
// carries image bytes. The query itself is ZoroCore's `PhotoQuery`.

/// `POST /v1/vision/parse-query` body.
public struct ParseQueryRequest: Sendable, Equatable, Encodable {
    public var text: String
    public var timezone: String
    public var refine: Bool
    public init(text: String, timezone: String, refine: Bool = false) {
        self.text = text
        self.timezone = timezone
        self.refine = refine
    }
}

/// The owner's words turned into a `PhotoQuery`, and who did it.
public struct ParsedPhotoQuery: Sendable, Equatable, Decodable {
    public enum Source: Sendable, Equatable {
        /// The ZORO server parsed it (`/v1/vision/parse-query`).
        case server
        /// This device parsed it, with this sentence explaining why.
        case device(reason: String)
    }

    public var query: PhotoQuery
    public var assumptions: [String]
    /// `original` or `model` (the search text was rephrased by a model).
    public var textSource: String
    public var source: Source

    public init(query: PhotoQuery, assumptions: [String] = [], textSource: String = "original", source: Source = .server) {
        self.query = query
        self.assumptions = assumptions
        self.textSource = textSource
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case query, assumptions
        case textSource = "text_source"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(PhotoQuery.self, forKey: .query)
        assumptions = try c.value(.assumptions, default: [])
        textSource = try c.value(.textSource, default: "original")
        source = .server
    }
}

/// One chip of a `photo_query` card payload.
public struct PhotoCardChip: Sendable, Equatable, Decodable {
    public var kind: String
    public var label: String
}

public struct PhotoCardHit: Sendable, Equatable, Decodable, Identifiable {
    public var assetId: String
    public var capturedAt: Date?
    public var score: Double
    public var labels: [String]
    public var id: String { assetId }

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case capturedAt = "captured_at"
        case score, labels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try c.decode(String.self, forKey: .assetId)
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt)
        score = try c.value(.score, default: 0)
        labels = try c.value(.labels, default: [])
    }
}

/// The payload of a `photo_query` card. `state` is `searching`, `found` or `empty`.
public struct PhotoCardPayload: Sendable, Equatable, Decodable {
    public var query: PhotoQuery
    public var chips: [PhotoCardChip]
    public var assetIds: [String]
    public var hits: [PhotoCardHit]
    public var state: String
    public var indexedCount: Int?
    public var limitedLibrary: Bool?
    public var assumptions: [String]

    enum CodingKeys: String, CodingKey {
        case query, chips
        case assetIds = "asset_ids"
        case hits, state
        case indexedCount = "indexed_count"
        case limitedLibrary = "limited_library"
        case assumptions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(PhotoQuery.self, forKey: .query)
        chips = try c.value(.chips, default: [])
        assetIds = try c.value(.assetIds, default: [])
        hits = try c.value(.hits, default: [])
        state = try c.value(.state, default: "searching")
        indexedCount = try c.decodeIfPresent(Int.self, forKey: .indexedCount)
        limitedLibrary = try c.decodeIfPresent(Bool.self, forKey: .limitedLibrary)
        assumptions = try c.value(.assumptions, default: [])
    }
}
