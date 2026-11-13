import CoreGraphics
import Testing
@testable import ZoroDesign

@Suite("Level ring buffer")
struct LevelRingBufferTests {
    @Test func startsEmpty() {
        let b = LevelRingBuffer(capacity: 4)
        #expect(b.isEmpty && b.count == 0 && b.values.isEmpty && b.latest == nil)
        #expect(b.padded == [0, 0, 0, 0])
    }

    @Test func keepsOrderBeforeWrapping() {
        var b = LevelRingBuffer(capacity: 4)
        b.append(contentsOf: [0.1, 0.2, 0.3])
        #expect(b.values == [0.1, 0.2, 0.3])
        #expect(b.padded == [0, 0.1, 0.2, 0.3])
        #expect(b.latest == 0.3)
    }

    @Test("overwrites the oldest once full, many times over")
    func wraps() {
        var b = LevelRingBuffer(capacity: 3)
        b.append(contentsOf: [0.1, 0.2, 0.3, 0.4, 0.5])
        #expect(b.count == 3)
        #expect(b.values == [0.3, 0.4, 0.5])
        for i in 0..<100 { b.append(Double(i % 10) / 10) }
        #expect(b.values == [0.7, 0.8, 0.9])
        #expect(b.padded.count == 3)
    }

    @Test("clamps out-of-range and non-finite levels")
    func clamps() {
        var b = LevelRingBuffer(capacity: 4)
        b.append(contentsOf: [-1, 2, .nan, .infinity])
        #expect(b.values == [0, 1, 0, 0])
    }

    @Test func removeAllResets() {
        var b = LevelRingBuffer(capacity: 2)
        b.append(contentsOf: [0.5, 0.6, 0.7])
        b.removeAll()
        #expect(b.isEmpty && b.padded == [0, 0])
        b.append(0.9)
        #expect(b.values == [0.9])
    }

    @Test func capacityOne() {
        var b = LevelRingBuffer(capacity: 1)
        b.append(contentsOf: [0.2, 0.4])
        #expect(b.values == [0.4] && b.latest == 0.4)
    }
}

@Suite("Rekha layout")
struct RekhaLayoutTests {
    @Test("the owner's voice hangs below the line, ZORO's rises above it")
    func sides() {
        let levels = [0.0, 0.02, 0.5, 1.0]
        let owner = RekhaLayout.bars(levels: levels, side: .owner, width: 100, lineY: 30, maxHeight: 20)
        let zoro = RekhaLayout.bars(levels: levels, side: .zoro, width: 100, lineY: 30, maxHeight: 20)
        #expect(owner.allSatisfy { $0.minY == 30 })
        #expect(zoro.allSatisfy { $0.maxY == 30 })
        // Silence draws nothing (the line stays clean); faint sound gets the 1.5 pt minimum.
        #expect(owner.map(\.height) == [1.5, 10, 20])
        #expect(owner.first!.minX == zoro.first!.minX)
    }

    @Test("newest bar sits at the trailing edge; only what fits is drawn")
    func trailing() {
        let bars = RekhaLayout.bars(levels: Array(repeating: 0.5, count: 100), side: .owner, width: 40, lineY: 0, maxHeight: 10, barWidth: 2, gap: 2)
        #expect(bars.count == 10)
        #expect(abs(Double(bars.last!.maxX) - 40) < 1e-9)
        #expect(bars.first!.minX >= 0)
    }

    @Test("empty or degenerate input draws nothing; bad levels clamp")
    func degenerate() {
        #expect(RekhaLayout.bars(levels: [], side: .zoro, width: 100, lineY: 0, maxHeight: 10).isEmpty)
        #expect(RekhaLayout.bars(levels: [1], side: .zoro, width: 0, lineY: 0, maxHeight: 10).isEmpty)
        let b = RekhaLayout.bars(levels: [.nan, 9], side: .zoro, width: 100, lineY: 0, maxHeight: 10)
        #expect(b.map(\.height) == [10])
        #expect(RekhaLayout.bars(levels: [0, 0, 0], side: .owner, width: 100, lineY: 0, maxHeight: 10).isEmpty)
    }
}
