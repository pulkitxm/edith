import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
import Testing
@testable import Edith

@Suite struct VideoBackgroundReferenceTests {
    struct Reference: Decodable {
        let pillow: String
        let radius: Double
        let cases: [SampleGrid]
    }

    struct SampleGrid: Decodable {
        let name: String
        let divisor: Int
        let xs: [Int]
        let ys: [Int]
        let rows: [[Int]]
    }

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let native = CGSize(width: 2160, height: 3840)

    @Test(arguments: ["step", "boundary", "texture", "p3"])
    func nativeAndQuarterPreviewMatchIndependentPillowReference(name: String) throws {
        let reference = try reference()
        #expect(reference.pillow == "11.3.0" && reference.radius == 65)
        let original = CIImage(cgImage: try source(name))
        for grid in reference.cases where grid.name == name {
            let canvas = CGSize(width: 2160 / grid.divisor, height: 3840 / grid.divisor)
            let rendered = VideoBackground().render(
                original: original, canvas: canvas, nativeCanvas: native)
            let errors = differences(rendered, grid: grid)
            let mean = Double(errors.reduce(0, +)) / Double(errors.count)
            let p95 = errors.sorted()[errors.count * 95 / 100]
            #expect(mean <= 2, "\(name) 1/\(grid.divisor): mean \(mean)")
            let p95Limit = name == "boundary" && grid.divisor == 4 ? 8 : 5
            #expect(p95 <= p95Limit, "\(name) 1/\(grid.divisor): P95 \(p95)")
            #expect(errors.max()! <= 36, "\(name) 1/\(grid.divisor): maximum \(errors.max()!)")
        }
    }

    @Test func zeroRadiusPreservesWideGamutValues() throws {
        let original = CIImage(cgImage: try source("p3"))
        let rendered = VideoBackground(blurRadius: 0).render(
            original: original, canvas: native, nativeCanvas: native)
        let placed = original.transformed(by: CGAffineTransform(translationX: -120, y: 0))
        let bounds = CGRect(x: 0, y: 0, width: 2160, height: 1)
        #expect(
            pixels(
                rendered, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
                == pixels(
                    placed, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        )
    }

    private func reference() throws -> Reference {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("scripts/fixtures/background-blur-reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    private func source(_ name: String) throws -> CGImage {
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 255], [0, 0, 255], [255, 255, 0]]
        var rows: [Data] = []
        for row in 0..<4 {
            var data = Data()
            for x in 0..<2400 {
                let color: [UInt8]
                switch name {
                case "step": color = x < 1200 ? [0, 0, 0] : [255, 255, 255]
                case "boundary": color = x < 120 || x >= 2280 ? [255, 255, 255] : [0, 0, 0]
                default:
                    color = x < 120 || x >= 2280 ? [255, 255, 255] : colors[(x / 24 + row) % 4]
                }
                data.append(contentsOf: color)
            }
            rows.append(data)
        }
        var data = Data()
        for y in 0..<3840 { data.append(rows[y / 40 % 4]) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(
            CGImage(
                width: 2400, height: 3840, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 7200,
                space: name == "p3" ? CGColorSpace(name: CGColorSpace.displayP3)! : srgb,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CIImage, bounds: CGRect, colorSpace: CGColorSpace? = nil)
        -> [UInt8]
    {
        var bytes = [UInt8](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        VideoImageContext.shared.render(
            image, toBitmap: &bytes, rowBytes: Int(bounds.width) * 4, bounds: bounds,
            format: .RGBA8, colorSpace: colorSpace ?? srgb)
        return bytes
    }

    private func differences(_ image: CIImage, grid: SampleGrid) -> [Int] {
        let width = 2160 / grid.divisor
        let height = 3840 / grid.divisor
        let bytes = pixels(image, bounds: CGRect(x: 0, y: 0, width: width, height: height))
        var errors: [Int] = []
        for (row, y) in grid.ys.enumerated() {
            for (column, x) in grid.xs.enumerated() {
                let offset = (y * width + x) * 4
                #expect(bytes[offset + 3] == 255)
                for channel in 0..<3 {
                    errors.append(
                        abs(Int(bytes[offset + channel]) - grid.rows[row][column * 3 + channel]))
                }
            }
        }
        return errors
    }
}
