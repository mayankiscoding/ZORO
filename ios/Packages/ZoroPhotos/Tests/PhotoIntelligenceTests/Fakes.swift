import CoreGraphics
import Foundation
import Synchronization
import ZoroCore
@testable import PhotoIntelligence

/// Builds a CGImage from synthetic pixels (no files, no hardware).
func makeImage(_ buffer: PixelBuffer) -> CGImage {
    var bytes = buffer.rgba
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    return bytes.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress, width: buffer.width, height: buffer.height, bitsPerComponent: 8,
            bytesPerRow: buffer.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        return context.makeImage()!
    }
}

func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, size: Int = 12) -> PixelBuffer {
    PixelBuffer(width: size, height: size) { _, _ in (r, g, b, 255) }
}

/// In-memory photo library with switchable authorisation and a limited selection.
final class FakeLibrary: PhotoLibraryProviding, @unchecked Sendable {
    struct State {
        var status: MediaAuthorization = .authorized
        var statusAfterRequest: MediaAuthorization = .authorized
        var assets: [LibraryAsset] = []
        /// When set, only these ids are readable (limited library).
        var selection: Set<String>?
        var images: [String: AnalysisImage] = [:]
        var authorizationRequests = 0
        var thumbnailRequests: [String] = []
        var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }
    let state = Mutex(State())

    func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    var thumbnailRequests: [String] { state.withLock { $0.thumbnailRequests } }
    var authorizationRequests: Int { state.withLock { $0.authorizationRequests } }

    func add(_ asset: LibraryAsset, image: CGImage? = nil) {
        state.withLock {
            $0.assets.removeAll { $0.id == asset.id }
            $0.assets.append(asset)
            if let image { $0.images[asset.id] = AnalysisImage(image) }
        }
    }

    func authorizationStatus() async -> MediaAuthorization { state.withLock { $0.status } }

    func requestAuthorization() async -> MediaAuthorization {
        state.withLock {
            $0.authorizationRequests += 1
            if $0.status == .notDetermined { $0.status = $0.statusAfterRequest }
            return $0.status
        }
    }

    private func readable(_ s: State) -> [LibraryAsset] {
        guard s.status == .authorized || s.status == .limited else { return [] }
        guard let selection = s.selection else { return s.assets }
        return s.assets.filter { selection.contains($0.id) }
    }

    func fetchAssets() async throws -> [LibraryAsset] {
        try state.withLock { s in
            guard s.status == .authorized || s.status == .limited else { throw PhotoSearchError.permissionDenied(s.status) }
            return readable(s)
        }
    }

    func accessibleIdentifiers(among ids: [String]) async -> Set<String> {
        state.withLock { s in Set(readable(s).map(\.id)).intersection(ids) }
    }

    func thumbnail(for assetId: String, maxPixelSize: Int) async throws -> AnalysisImage? {
        state.withLock { s in
            s.thumbnailRequests.append(assetId)
            return s.images[assetId]
        }
    }

    func changes() -> AsyncStream<Void> {
        let key = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.observers[key] = continuation }
        }
    }
}

/// Returns canned analyses per image (by object identity); throws for unknown images.
final class FakeAnalyzer: ImageAnalyzing, @unchecked Sendable {
    struct Failure: Error {}
    let results = Mutex<[ObjectIdentifier: VisualAnalysis]>([:])
    let calls = Mutex(0)
    let delay: Duration?

    init(delay: Duration? = nil) { self.delay = delay }

    func register(_ image: CGImage, _ analysis: VisualAnalysis) {
        results.withLock { $0[ObjectIdentifier(image)] = analysis }
    }

    func analyze(_ image: AnalysisImage) async throws -> VisualAnalysis {
        calls.withLock { $0 += 1 }
        if let delay { try await Task.sleep(for: delay) }
        guard let result = results.withLock({ $0[ObjectIdentifier(image.cgImage)] }) else { throw Failure() }
        return result
    }
}

final class FakePower: PowerMonitoring, @unchecked Sendable {
    private let state = Mutex<(PowerCondition, [UUID: AsyncStream<PowerCondition>.Continuation])>((PowerCondition(), [:]))

    init(_ condition: PowerCondition = PowerCondition()) {
        state.withLock { $0.0 = condition }
    }

    func set(_ condition: PowerCondition) {
        let observers = state.withLock { s -> [AsyncStream<PowerCondition>.Continuation] in
            s.0 = condition
            return Array(s.1.values)
        }
        observers.forEach { $0.yield(condition) }
    }

    var observerCount: Int { state.withLock { $0.1.count } }

    func current() async -> PowerCondition { state.withLock { $0.0 } }

    func changes() -> AsyncStream<PowerCondition> {
        let key = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.1[key] = continuation }
            continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.1.removeValue(forKey: key) } }
        }
    }
}

/// A deterministic "embedding": a one-hot vector per known word.
struct FakeEmbedder: ImageTextEmbedder {
    let vocabulary = ["beach", "mountain", "party"]
    let imageWords: [ObjectIdentifier: String]
    var modelIdentifier: String { "fake-clip-v1" }

    private func vector(_ word: String?) -> [Float] {
        vocabulary.map { $0 == word ? 1 : 0.01 }
    }

    func embed(image: AnalysisImage) async throws -> [Float] { vector(imageWords[ObjectIdentifier(image.cgImage)]) }
    func embed(text: String) async throws -> [Float] {
        vector(vocabulary.first { text.lowercased().contains($0) })
    }
}

let ist = TimeZone(identifier: "Asia/Kolkata")!

/// 2026-11-12T10:00:00+05:30
let fixedNow = Date(timeIntervalSince1970: 1_794_457_800)

func date(_ iso: String) -> Date { ZoroJSON.parseDate(iso)! }

/// A library + analyzer + store wired into a service, with helpers to add photos.
struct Fixture {
    let library = FakeLibrary()
    let analyzer: FakeAnalyzer
    let power: FakePower
    let store: PhotoIndexStore
    let service: PhotoIntelligenceService

    init(
        analyzerDelay: Duration? = nil, power: FakePower = FakePower(), embedder: (any ImageTextEmbedder)? = nil,
        batchSize: Int = 4, pauseRecheck: Duration = .seconds(30)
    ) throws {
        analyzer = FakeAnalyzer(delay: analyzerDelay)
        self.power = power
        store = try PhotoIndexStore()
        service = PhotoIntelligenceService(
            library: library, analyzer: analyzer, sampler: CoreGraphicsPixelSampler(), power: power, store: store,
            embedder: embedder,
            indexerConfiguration: IndexerConfiguration(batchSize: batchSize, maxConcurrency: 2, pauseRecheck: pauseRecheck),
            configuration: PhotoServiceConfiguration(autoIndexOnSearch: false), timeZone: ist, now: { fixedNow })
    }

    @discardableResult
    func addPhoto(
        _ id: String, at captured: String, kind: PhotoMediaKind = .photo, pixels: PixelBuffer = solid(128, 128, 128),
        labels: [(String, Double)] = [], text: [String] = [], featurePrint: [Float]? = nil, modified: Date? = nil,
        analysable: Bool = true
    ) -> CGImage {
        let image = makeImage(pixels)
        let capturedAt = date(captured)
        library.add(
            LibraryAsset(id: id, capturedAt: capturedAt, modifiedAt: modified ?? capturedAt, kind: kind, hasLocation: false),
            image: image)
        if analysable {
            analyzer.register(image, VisualAnalysis(
                labels: labels.map { VisualLabel(name: $0.0, confidence: $0.1) }, textLines: text, featurePrint: featurePrint))
        }
        return image
    }
}

/// A picture with a blue patch in the top-left cell over a white background.
func bluePatchPicture() -> PixelBuffer {
    PixelBuffer(width: 30, height: 30) { x, y in
        (x < 9 && y < 9) ? (20, 60, 200, 255) : (250, 250, 250, 255)
    }
}
