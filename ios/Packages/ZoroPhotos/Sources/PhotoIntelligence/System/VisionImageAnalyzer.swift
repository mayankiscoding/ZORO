#if canImport(Vision)
import Foundation
import Vision

/// On-device image analysis with Vision's Swift API (iOS 18 / macOS 15): scene classification
/// labels, text recognition, and an image feature print. Nothing is sent anywhere.
public struct VisionImageAnalyzer: ImageAnalyzing {
    public var minimumLabelConfidence: Float
    public var maximumLabels: Int
    /// OCR language preference; only languages the running OS supports are used.
    public var preferredLanguages: [String]

    public init(minimumLabelConfidence: Float = 0.1, maximumLabels: Int = 20, preferredLanguages: [String] = TextRecognitionLanguages.preferred) {
        self.minimumLabelConfidence = minimumLabelConfidence
        self.maximumLabels = maximumLabels
        self.preferredLanguages = preferredLanguages
    }

    public func analyze(_ image: AnalysisImage) async throws -> VisualAnalysis {
        let cg = image.cgImage
        let observations = try await ClassifyImageRequest().perform(on: cg)
        let labels = observations
            .filter { $0.confidence >= minimumLabelConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maximumLabels)
            .map { VisualLabel(name: $0.identifier, confidence: Double($0.confidence)) }
        try Task.checkCancellation()

        var textRequest = RecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        let languages = Self.languages(supported: textRequest.supportedRecognitionLanguages, preferred: preferredLanguages)
        if !languages.isEmpty { textRequest.recognitionLanguages = languages }
        let lines = try await textRequest.perform(on: cg).compactMap { $0.topCandidates(1).first?.string }
        try Task.checkCancellation()

        let print = try? await GenerateImageFeaturePrintRequest().perform(on: cg)
        return VisualAnalysis(labels: Array(labels), textLines: lines, featurePrint: print.map(Self.floats))
    }

    /// Supported languages in preference order (Hindi only where this OS's Vision offers it).
    static func languages(supported: [Locale.Language], preferred: [String]) -> [Locale.Language] {
        var byIdentifier = [String: Locale.Language]()
        for language in supported {
            let code = language.languageCode?.identifier ?? language.minimalIdentifier
            let id = language.region.map { "\(code)-\($0.identifier)" } ?? code
            if byIdentifier[id] == nil { byIdentifier[id] = language }
        }
        return TextRecognitionLanguages.select(supported: byIdentifier.keys.sorted(), preferred: preferred)
            .compactMap { byIdentifier[$0] }
    }

    static func floats(_ observation: FeaturePrintObservation) -> [Float] {
        let data = observation.data
        switch observation.elementType {
        case .double:
            let size = MemoryLayout<Double>.size
            return data.withUnsafeBytes { raw in
                (0..<(raw.count / size)).map { Float(raw.loadUnaligned(fromByteOffset: $0 * size, as: Double.self)) }
            }
        default:
            return VectorMath.decode(data)
        }
    }
}
#endif
