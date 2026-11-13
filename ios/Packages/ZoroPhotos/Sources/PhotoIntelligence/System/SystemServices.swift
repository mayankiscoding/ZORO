import CoreGraphics
import Foundation

/// Draws an image into an 8-bit sRGB RGBA buffer, scaled so the longer side is at most `maxSide`.
public struct CoreGraphicsPixelSampler: PixelSampling {
    public init() {}

    public func pixels(of image: AnalysisImage, maxSide: Int) -> PixelBuffer? {
        let cg = image.cgImage
        guard cg.width > 0, cg.height > 0, maxSide > 0 else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(cg.width, cg.height)))
        let w = max(1, Int((Double(cg.width) * scale).rounded()))
        let h = max(1, Int((Double(cg.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // Un-premultiply so colours of semi-transparent pixels are not darkened.
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Int(bytes[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { bytes[i + c] = UInt8(min(255, Int(bytes[i + c]) * 255 / a)) }
        }
        return PixelBuffer(width: w, height: h, rgba: bytes)
    }
}

/// Low Power Mode and thermal state from `ProcessInfo`.
public final class SystemPowerMonitor: PowerMonitoring, @unchecked Sendable {
    public init() {}

    public func current() async -> PowerCondition {
        let info = ProcessInfo.processInfo
        return PowerCondition(lowPowerMode: info.isLowPowerModeEnabled, thermal: Self.map(info.thermalState))
    }

    public func changes() -> AsyncStream<PowerCondition> {
        AsyncStream { continuation in
            let center = NotificationCenter.default
            let emit: @Sendable (Notification) -> Void = { _ in
                let info = ProcessInfo.processInfo
                continuation.yield(PowerCondition(lowPowerMode: info.isLowPowerModeEnabled, thermal: Self.map(info.thermalState)))
            }
            let tokens = ObserverTokens([
                center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil, using: emit),
                center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil, using: emit),
            ])
            continuation.onTermination = { _ in tokens.remove(from: center) }
        }
    }

    static func map(_ state: ProcessInfo.ThermalState) -> PowerCondition.Thermal {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}

/// Notification observer tokens, removed once when the stream ends.
final class ObserverTokens: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]
    init(_ tokens: [NSObjectProtocol]) { self.tokens = tokens }
    func remove(from center: NotificationCenter) {
        tokens.forEach(center.removeObserver)
    }
}
