import CoreGraphics
import Foundation
import Testing

struct MusicRenderPixels {
    let colors: Int
    let contrastEdges: Int
    var hasContent: Bool { colors > 3 && contrastEdges >= 32 }

    init(rgba: [UInt8], width: Int, height: Int) {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4)
        var colors = Set<UInt32>()
        var edges = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if colors.count < 4 {
                    colors.insert(
                        UInt32(rgba[offset]) << 24 | UInt32(rgba[offset + 1]) << 16
                            | UInt32(rgba[offset + 2]) << 8 | UInt32(rgba[offset + 3]))
                }
                if x > 0 {
                    let contrast = (0..<3).reduce(0) {
                        $0 + abs(Int(rgba[offset + $1]) - Int(rgba[offset - 4 + $1]))
                    }
                    if contrast >= 96 { edges += 1 }
                }
            }
        }
        self.colors = colors.count
        contrastEdges = edges
    }

    init(image: CGImage) throws {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try #require(
                CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.init(rgba: rgba, width: width, height: height)
    }
}

struct MusicRenderPixelsTests {
    @Test func blankAndSmoothBackgroundsCannotSatisfyContentReadiness() {
        let blank = [UInt8](repeating: 255, count: 100 * 100 * 4)
        #expect(!MusicRenderPixels(rgba: blank, width: 100, height: 100).hasContent)
        var gradient = blank
        for y in 0..<100 {
            for x in 0..<100 {
                let offset = (y * 100 + x) * 4
                gradient[offset] = UInt8(150 + x)
                gradient[offset + 1] = UInt8(150 + x)
                gradient[offset + 2] = UInt8(150 + x)
            }
        }
        #expect(!MusicRenderPixels(rgba: gradient, width: 100, height: 100).hasContent)
    }

    @Test func smallContentBetweenSparseGridSamplesIsStillDetected() {
        var rgba = [UInt8](repeating: 255, count: 100 * 100 * 4)
        for y in 1..<4 {
            for x in 1..<99 {
                let offset = (y * 100 + x) * 4
                let value = UInt8((x % 4) * 50)
                rgba[offset] = value; rgba[offset + 1] = value; rgba[offset + 2] = value
            }
        }
        #expect(MusicRenderPixels(rgba: rgba, width: 100, height: 100).hasContent)
        #expect(
            stride(from: 0, to: 100, by: 5).allSatisfy { y in
                stride(from: 0, to: 100, by: 5).allSatisfy { x in
                    rgba[(y * 100 + x) * 4] == 255
                }
            })
    }
}
