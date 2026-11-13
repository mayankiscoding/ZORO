import Testing
@testable import PhotoIntelligence

@Suite("Colour quantisation and naming")
struct ColourTests {
    let namer = ColourNamer()

    @Test("reference colours get the names people use", arguments: [
        ((255, 0, 0), NamedColour.red), ((128, 0, 0), .red), ((220, 20, 60), .red),
        ((255, 192, 203), .pink), ((255, 105, 180), .pink), ((255, 0, 255), .pink),
        ((128, 0, 128), .purple), ((138, 43, 226), .purple), ((181, 126, 220), .purple),
        ((0, 0, 255), .blue), ((0, 0, 128), .blue), ((135, 206, 235), .blue), ((65, 105, 225), .blue),
        ((0, 128, 128), .teal), ((0, 255, 255), .teal), ((64, 224, 208), .teal),
        ((0, 128, 0), .green), ((0, 255, 0), .green), ((128, 128, 0), .green),
        ((255, 255, 0), .yellow), ((255, 215, 0), .yellow), ((225, 173, 1), .yellow),
        ((255, 165, 0), .orange), ((255, 140, 0), .orange), ((217, 138, 0), .orange),
        ((139, 69, 19), .brown), ((210, 105, 30), .brown), ((210, 180, 140), .beige),
        ((255, 255, 255), .white), ((245, 245, 240), .white), ((211, 211, 211), .grey), ((128, 128, 128), .grey),
        ((112, 128, 144), .grey), ((30, 30, 30), .black), ((0, 0, 0), .black),
    ] as [((Int, Int, Int), NamedColour)])
    func naming(_ rgb: (Int, Int, Int), _ expected: NamedColour) {
        #expect(namer.name(red: UInt8(rgb.0), green: UInt8(rgb.1), blue: UInt8(rgb.2)) == expected)
    }

    @Test func okLabOfWhiteAndBlack() {
        let white = OKLab(red: 255, green: 255, blue: 255)
        #expect(abs(white.l - 1) < 0.001)
        #expect(white.chroma < 0.001)
        #expect(OKLab(red: 0, green: 0, blue: 0).l < 0.001)
    }

    @Test func halfBlueHalfWhite() {
        let buffer = PixelBuffer(width: 20, height: 20) { x, _ in x < 10 ? (10, 40, 220, 255) : (255, 255, 255, 255) }
        let full = DominantColourExtractor().extract(from: buffer).filter { $0.region == .full }
        #expect(Set(full.map(\.colour)) == [.blue, .white])
        for c in full { #expect(abs(c.fraction - 0.5) < 0.05) }
    }

    @Test("a small object is kept for its grid cell even when it is minor overall")
    func smallObjectInOneCell() {
        let colours = DominantColourExtractor().extract(from: bluePatchPicture())
        let fullBlue = colours.first { $0.region == .full && $0.colour == .blue }
        let cellBlue = colours.first { $0.region == .cell(row: 0, column: 0) && $0.colour == .blue }
        #expect((fullBlue?.fraction ?? 0) < 0.15)
        #expect((cellBlue?.fraction ?? 0) > 0.75)
        #expect(!colours.contains { $0.region == .cell(row: 2, column: 2) && $0.colour == .blue })
    }

    @Test func transparentPixelsAreIgnored() {
        let buffer = PixelBuffer(width: 10, height: 10) { x, _ in x < 5 ? (255, 0, 0, 255) : (0, 0, 255, 0) }
        let full = DominantColourExtractor().extract(from: buffer).filter { $0.region == .full }
        #expect(full.map(\.colour) == [.red])
        #expect(full.first?.fraction == 1)
    }

    @Test("downsampling averages in linear light, so a fine checkerboard is grey")
    func downsampleCheckerboard() {
        let checker = PixelBuffer(width: 64, height: 64) { x, y in (x + y) % 2 == 0 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        let small = checker.downsampled(maxSide: 8)
        #expect(small.width == 8 && small.height == 8)
        // Linear mid-grey is about 188 in sRGB, not the naive 128.
        #expect((180...195).contains(Int(small.rgba[0])))
        #expect(namer.name(red: small.rgba[0], green: small.rgba[1], blue: small.rgba[2]) == .grey)
    }

    @Test func regionNamesRoundTrip() {
        for region in [ColourRegion.full, .cell(row: 0, column: 2), .cell(row: 2, column: 1)] {
            #expect(ColourRegion(region.description) == region)
        }
        #expect(ColourRegion("r3c0") == nil)
        #expect(ColourRegion("bogus") == nil)
    }

    @Test func pixelSamplerReadsCGImage() {
        let image = makeImage(bluePatchPicture())
        let pixels = CoreGraphicsPixelSampler().pixels(of: AnalysisImage(image), maxSide: 15)
        #expect(pixels?.width == 15)
        let colours = DominantColourExtractor().extract(from: pixels!)
        #expect(colours.contains { $0.region == .cell(row: 0, column: 0) && $0.colour == .blue })
    }

    @Test func invalidBufferIsRejected() {
        #expect(PixelBuffer(width: 2, height: 2, rgba: [0, 0, 0]) == nil)
    }
}
