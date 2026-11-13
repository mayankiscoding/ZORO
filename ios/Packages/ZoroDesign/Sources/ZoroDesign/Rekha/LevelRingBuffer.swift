import CoreGraphics
import Foundation

/// A fixed-capacity ring buffer of audio levels (0...1) for the rekha waveform.
/// Appending past capacity overwrites the oldest value. Non-finite input is stored as 0.
public struct LevelRingBuffer: Sendable, Equatable {
    public let capacity: Int
    private var storage: [Double]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "LevelRingBuffer needs a positive capacity")
        self.capacity = capacity
        storage = Array(repeating: 0, count: capacity)
    }

    public mutating func append(_ level: Double) {
        storage[head] = level.isFinite ? min(max(level, 0), 1) : 0
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    public mutating func append<S: Sequence>(contentsOf levels: S) where S.Element == Double {
        for level in levels { append(level) }
    }

    public mutating func removeAll() {
        storage = Array(repeating: 0, count: capacity)
        head = 0
        count = 0
    }

    public var isEmpty: Bool { count == 0 }

    /// Stored values, oldest first.
    public var values: [Double] {
        let start = (head - count + capacity) % capacity
        return (0..<count).map { storage[(start + $0) % capacity] }
    }

    public var latest: Double? { count == 0 ? nil : storage[(head - 1 + capacity) % capacity] }

    /// Exactly `capacity` values, oldest first, with silence (0) before the first sample, so a
    /// waveform keeps its width from the first frame.
    public var padded: [Double] { Array(repeating: 0, count: capacity - count) + values }
}

/// Bar geometry for the rekha. Pure, so the "hang below / rise above" rule is tested.
public enum RekhaLayout {
    public enum Side: Sendable { case owner, zoro }

    /// Bars laid out left to right (oldest to newest), right-aligned in `width`. Owner bars hang
    /// from the line (minY == lineY); ZORO's bars stand on it (maxY == lineY). Silence draws no
    /// bar, so the line itself stays clean; any sound draws at least `minHeight`.
    public static func bars(
        levels: [Double], side: Side, width: Double, lineY: Double, maxHeight: Double,
        barWidth: Double = 2, gap: Double = 2, minHeight: Double = 1.5
    ) -> [CGRect] {
        guard !levels.isEmpty, width > 0, barWidth > 0 else { return [] }
        let step = barWidth + gap
        let fit = max(Int((width + gap) / step), 0)
        let shown = Array(levels.suffix(fit))
        let startX = width - Double(shown.count) * step + gap
        return shown.enumerated().compactMap { i, raw in
            let level = raw.isFinite ? min(max(raw, 0), 1) : 0
            guard level > 0.01 else { return nil }
            let h = max(minHeight, level * maxHeight)
            let x = startX + Double(i) * step
            switch side {
            case .owner: return CGRect(x: x, y: lineY, width: barWidth, height: h)
            case .zoro: return CGRect(x: x, y: lineY - h, width: barWidth, height: h)
            }
        }
    }
}
