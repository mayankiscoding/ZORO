import Foundation
import ZoroCore

/// What the ranker knows about one indexed asset.
public struct RankingCandidate: Sendable, Equatable {
    public var assetId: String
    public var capturedAt: Date?
    public var media: PhotoMediaKind
    public var labels: [VisualLabel]
    /// Normalised recognised text.
    public var text: String
    public var colours: [RegionColour]
    /// Cosine similarity between the query text and the image embedding, when an embedder exists.
    public var similarity: Double?

    public init(
        assetId: String, capturedAt: Date?, media: PhotoMediaKind, labels: [VisualLabel] = [], text: String = "",
        colours: [RegionColour] = [], similarity: Double? = nil
    ) {
        self.assetId = assetId
        self.capturedAt = capturedAt
        self.media = media
        self.labels = labels
        self.text = text
        self.colours = colours
        self.similarity = similarity
    }
}

public struct RankingWeights: Sendable, Equatable {
    public var labelGroup = 1.0
    public var freeTerm = 0.8
    public var colour = 0.6
    public var requiredText = 1.0
    public var embedding = 1.0
    /// Share of the whole picture at which a colour counts fully.
    public var fullColourSaturation = 0.30
    /// Share of one grid cell at which a colour counts (at `cellColourWeight`).
    public var cellColourSaturation = 0.60
    public var cellColourWeight = 0.85
    /// Cosine similarities are mapped linearly from floor (0) to ceiling (1); CLIP-style models
    /// put matching text-image pairs around 0.25–0.35.
    public var embeddingFloor = 0.15
    public var embeddingCeiling = 0.32
    public var minimumLabelConfidence = 0.10
    /// Labels returned with a hit.
    public var hitLabelConfidence = 0.30
    public var hitLabelCount = 5

    public init() {}
}

public struct RankedPhoto: Sendable, Equatable {
    public var assetId: String
    public var capturedAt: Date?
    public var media: PhotoMediaKind
    public var score: Double
    public var labels: [String]
    public var matched: [String]
}

/// Combines date filter, label, colour, text and embedding signals into one score in 0...1.
///
/// Every criterion the plan asks for (each label group, each colour, each free word, the required
/// text, and the embedding when available) contributes `weight × signal`; the score is the weighted
/// mean over the criteria asked for, so an asset matching "blue" and "cap" outranks one matching only
/// "cap". Date and media are hard filters; required text is a hard filter. Assets that match nothing
/// are dropped. A plan with only filters returns everything inside them, newest first.
public struct PhotoRanker: Sendable {
    public var weights: RankingWeights

    public init(weights: RankingWeights = RankingWeights()) {
        self.weights = weights
    }

    public func rank(_ candidates: [RankingCandidate], plan: SearchPlan, embeddingAvailable: Bool = false) -> [RankedPhoto] {
        let useEmbedding = embeddingAvailable && plan.embeddingText != nil
        var ranked: [RankedPhoto] = []
        for candidate in candidates {
            if let interval = plan.dateInterval {
                guard let captured = candidate.capturedAt, interval.contains(captured) else { continue }
            }
            guard plan.media.admits(candidate.media) else { continue }
            if let result = score(candidate, plan: plan, useEmbedding: useEmbedding) {
                ranked.append(result)
            }
        }
        return ranked.sorted(by: Self.order)
    }

    static func order(_ a: RankedPhoto, _ b: RankedPhoto) -> Bool {
        if a.score != b.score { return a.score > b.score }
        switch (a.capturedAt, b.capturedAt) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.assetId < b.assetId
        }
    }

    private func score(_ c: RankingCandidate, plan: SearchPlan, useEmbedding: Bool) -> RankedPhoto? {
        let normalLabels = c.labels
            .filter { $0.confidence >= weights.minimumLabelConfidence }
            .map { (name: TextNormalizer.normalize($0.name), confidence: $0.confidence) }
        let words = Set(c.text.split(separator: " ").map(String.init))
        var matched: [String] = []
        var total = 0.0
        var weightSum = 0.0
        var anyContent = false

        if !plan.requiredText.isEmpty {
            guard plan.requiredText.allSatisfy({ Self.textContains(words, $0) }) else { return nil }
            weightSum += weights.requiredText
            total += weights.requiredText
            anyContent = true
            matched += plan.requiredText.map { "text:\($0)" }
        }
        for group in plan.labelGroups {
            weightSum += weights.labelGroup
            if let best = bestLabel(normalLabels, terms: group.terms) {
                total += weights.labelGroup * best.confidence
                anyContent = true
                matched.append("label:\(best.name)")
            }
        }
        for colour in plan.colours {
            weightSum += weights.colour
            let s = colourScore(colour, in: c.colours)
            if s > 0 {
                total += weights.colour * s
                anyContent = true
                matched.append("color:\(colour.rawValue)")
            }
        }
        for term in plan.freeTerms {
            weightSum += weights.freeTerm
            if Self.textContains(words, term) {
                total += weights.freeTerm
                anyContent = true
                matched.append("text:\(term)")
            } else if let best = bestLabel(normalLabels, terms: [term]) {
                total += weights.freeTerm * best.confidence
                anyContent = true
                matched.append("label:\(best.name)")
            }
        }
        if useEmbedding {
            weightSum += weights.embedding
            if let sim = c.similarity {
                let span = max(0.0001, weights.embeddingCeiling - weights.embeddingFloor)
                let s = min(1, max(0, (sim - weights.embeddingFloor) / span))
                if s > 0 {
                    total += weights.embedding * s
                    anyContent = true
                    matched.append("similar")
                }
            }
        }

        let score: Double
        if weightSum == 0 {
            score = 1  // filters only
        } else {
            guard anyContent else { return nil }
            score = total / weightSum
        }
        if plan.dateInterval != nil { matched.append("date") }
        if plan.media != .any { matched.append("media:\(c.media.rawValue)") }

        let labels = c.labels
            .filter { $0.confidence >= weights.hitLabelConfidence }
            .sorted { $0.confidence == $1.confidence ? $0.name < $1.name : $0.confidence > $1.confidence }
            .prefix(weights.hitLabelCount)
            .map { TextNormalizer.normalize($0.name) }
        return RankedPhoto(
            assetId: c.assetId, capturedAt: c.capturedAt, media: c.media,
            score: (score * 1000).rounded() / 1000, labels: Array(labels), matched: Self.unique(matched))
    }

    private func bestLabel(_ labels: [(name: String, confidence: Double)], terms: Set<String>) -> (name: String, confidence: Double)? {
        labels
            .filter { label in terms.contains { TextNormalizer.containsPhrase(label.name, $0) } }
            .max { $0.confidence < $1.confidence }
    }

    /// Best of: share of the whole image, or share of one grid cell (a small object in one part).
    func colourScore(_ colour: NamedColour, in colours: [RegionColour]) -> Double {
        var best = 0.0
        for rc in colours where rc.colour == colour {
            let s: Double
            switch rc.region {
            case .full: s = min(1, rc.fraction / weights.fullColourSaturation)
            case .cell: s = weights.cellColourWeight * min(1, rc.fraction / weights.cellColourSaturation)
            }
            best = max(best, s)
        }
        return best
    }

    /// Whole word, or a prefix for words of four letters or more ("invoic" → "invoice").
    static func textContains(_ words: Set<String>, _ term: String) -> Bool {
        if words.contains(term) { return true }
        guard term.count >= 4 else { return false }
        return words.contains { $0.hasPrefix(term) }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Vector helpers for feature prints and embeddings.
public enum VectorMath {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Euclidean distance: the measure Vision uses between feature prints.
    public static func euclidean(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var sum = 0.0
        for i in a.indices {
            let d = Double(a[i]) - Double(b[i])
            sum += d * d
        }
        return sum.squareRoot()
    }

    static func encode(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        let size = MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            (0..<(raw.count / size)).map { raw.loadUnaligned(fromByteOffset: $0 * size, as: Float.self) }
        }
    }
}
