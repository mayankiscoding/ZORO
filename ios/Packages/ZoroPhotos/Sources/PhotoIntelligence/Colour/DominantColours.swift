import Foundation

/// 8-bit RGBA pixels, row-major, no padding. Platform-neutral so colour logic is testable.
public struct PixelBuffer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes: R, G, B, A.
    public let rgba: [UInt8]

    public init?(width: Int, height: Int, rgba: [UInt8]) {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// A buffer filled by a per-pixel function (tests and synthetic images).
    public init(width: Int, height: Int, fill: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)) {
        precondition(width > 0 && height > 0)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = fill(x, y)
                let i = (y * width + x) * 4
                bytes[i] = p.0; bytes[i + 1] = p.1; bytes[i + 2] = p.2; bytes[i + 3] = p.3
            }
        }
        self.width = width
        self.height = height
        self.rgba = bytes
    }

    /// Box-filter downsample so the longer side is at most `maxSide` (averaging in linear light,
    /// so a fine black/white pattern becomes grey rather than dark). Alpha is averaged too.
    public func downsampled(maxSide: Int) -> PixelBuffer {
        let longer = max(width, height)
        guard maxSide > 0, longer > maxSide else { return self }
        let scale = Double(longer) / Double(maxSide)
        let w = max(1, Int((Double(width) / scale).rounded()))
        let h = max(1, Int((Double(height) / scale).rounded()))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for oy in 0..<h {
            let y0 = oy * height / h, y1 = max(y0 + 1, (oy + 1) * height / h)
            for ox in 0..<w {
                let x0 = ox * width / w, x1 = max(x0 + 1, (ox + 1) * width / w)
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0, n = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = (y * width + x) * 4
                        r += SRGBTable.linear[Int(rgba[i])]
                        g += SRGBTable.linear[Int(rgba[i + 1])]
                        b += SRGBTable.linear[Int(rgba[i + 2])]
                        a += Double(rgba[i + 3])
                        n += 1
                    }
                }
                let o = (oy * w + ox) * 4
                out[o] = Self.encode(r / n)
                out[o + 1] = Self.encode(g / n)
                out[o + 2] = Self.encode(b / n)
                out[o + 3] = UInt8(min(255, max(0, (a / n).rounded())))
            }
        }
        return PixelBuffer(width: w, height: h, rgba: out)!
    }

    private static func encode(_ linear: Double) -> UInt8 {
        let c = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return UInt8(min(255, max(0, (c * 255).rounded())))
    }
}

/// Finds the named colours of an image, for the whole picture and per cell of a 3×3 grid.
///
/// Pipeline: downsample (linear-light box filter) → convert every pixel to OKLab → quantise to the
/// nearest named colour (`ColourNamer`) → per-region histogram → keep colours above a share threshold.
public struct DominantColourExtractor: Sendable {
    public var sampleSide: Int
    /// Minimum share of the whole image for a colour to be kept.
    public var minimumFullFraction: Double
    /// Minimum share of a grid cell for a colour to be kept for that cell.
    public var minimumCellFraction: Double
    public var namer: ColourNamer

    public init(sampleSide: Int = 48, minimumFullFraction: Double = 0.05, minimumCellFraction: Double = 0.15, namer: ColourNamer = ColourNamer()) {
        self.sampleSide = sampleSide
        self.minimumFullFraction = minimumFullFraction
        self.minimumCellFraction = minimumCellFraction
        self.namer = namer
    }

    public func extract(from image: PixelBuffer) -> [RegionColour] {
        let small = image.downsampled(maxSide: sampleSide)
        let grid = ColourRegion.gridSize
        var full = [NamedColour: Int]()
        var fullCount = 0
        var cells = Array(repeating: [NamedColour: Int](), count: grid * grid)
        var cellCounts = Array(repeating: 0, count: grid * grid)
        for y in 0..<small.height {
            let row = min(grid - 1, y * grid / small.height)
            for x in 0..<small.width {
                let i = (y * small.width + x) * 4
                guard small.rgba[i + 3] >= 128 else { continue }  // transparent pixels carry no colour
                let colour = namer.name(red: small.rgba[i], green: small.rgba[i + 1], blue: small.rgba[i + 2])
                let column = min(grid - 1, x * grid / small.width)
                let cell = row * grid + column
                full[colour, default: 0] += 1
                fullCount += 1
                cells[cell][colour, default: 0] += 1
                cellCounts[cell] += 1
            }
        }
        var result: [RegionColour] = []
        if fullCount > 0 {
            result += Self.shares(full, total: fullCount, minimum: minimumFullFraction, region: .full)
        }
        for cell in 0..<(grid * grid) where cellCounts[cell] > 0 {
            let region = ColourRegion.cell(row: cell / grid, column: cell % grid)
            result += Self.shares(cells[cell], total: cellCounts[cell], minimum: minimumCellFraction, region: region)
        }
        return result
    }

    private static func shares(_ counts: [NamedColour: Int], total: Int, minimum: Double, region: ColourRegion) -> [RegionColour] {
        counts.compactMap { colour, count -> RegionColour? in
            let fraction = Double(count) / Double(total)
            return fraction >= minimum ? RegionColour(region: region, colour: colour, fraction: fraction) : nil
        }
        .sorted { $0.fraction == $1.fraction ? $0.colour.rawValue < $1.colour.rawValue : $0.fraction > $1.fraction }
    }
}
