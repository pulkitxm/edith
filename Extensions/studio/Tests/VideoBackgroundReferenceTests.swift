import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
import Testing
@testable import StudioExtension

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
        let edges: [[Int]]
    }

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let native = CGSize(width: 2160, height: 3840)

    @Test(arguments: ["step", "boundary", "texture", "p3"])
    func nativeAndQuarterPreviewMatchIndependentPillowReference(name: String) throws {
        let reference = try reference()
        #expect(reference.pillow == "11.3.0" && reference.radius == 65)
        let original = CIImage(cgImage: try source(name))
        let grids = reference.cases.filter { $0.name == name }
        try #require(grids.count == 2 && Set(grids.map(\.divisor)) == [1, 4])
        for grid in grids {
            try #require(grid.rows.count == grid.ys.count && !grid.ys.isEmpty && !grid.xs.isEmpty)
            try #require(grid.rows.allSatisfy { $0.count == grid.xs.count * 3 })
            let canvas = CGSize(width: 2160 / grid.divisor, height: 3840 / grid.divisor)
            let rendered = VideoBackground().render(
                original: original, canvas: canvas, nativeCanvas: native)
            let errors = differences(rendered, grid: grid)
            let mean = Double(errors.reduce(0, +)) / Double(errors.count)
            let p95 = errors.sorted()[errors.count * 95 / 100]
            #expect(mean <= 2, "\(name) 1/\(grid.divisor): mean \(mean)")
            #expect(p95 <= 5, "\(name) 1/\(grid.divisor): P95 \(p95)")
            let maximum = (errors + edgeDifferences(rendered, grid: grid)).max()!
            #expect(maximum <= 36, "\(name) 1/\(grid.divisor): maximum \(maximum)")
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

    @Test func nativePreviewAndEncodedExportPreserveForegroundAndMatchBackgroundReference()
        async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic-p3.png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try source("p3"), nil)
        try #require(CGImageDestinationFinalize(destination))
        let checksum = SHA256.hash(data: try Data(contentsOf: url))
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 2160, height: 3840, colorSpace: .displayP3)
        try project.addStillAsset(url, duration: 0.1, metadata: VideoStillMedia.metadata(at: url))
        let id = project.clips[0].id
        project.crop(clipID: id, x: 0, y: 0.25, width: 1, height: 0.5)
        try project.setVisualEffects(.init(framing: .fullWidth, background: .init()), clipID: id)
        let reference = try reference()
        for divisor in [1, 4] {
            let pipeline = try await VideoRenderPipeline.make(
                project: project, maxDimension: 3840 / divisor, previewOnly: divisor == 4)
            let rendered = try frame(pipeline)
            #expect(rendered.extent.size == CGSize(width: 2160 / divisor, height: 3840 / divisor))
            let grid = try #require(
                reference.cases.first { $0.name == "p3" && $0.divisor == divisor })
            let errors = differences(rendered, grid: grid) { y in
                y < 1000 / divisor || y >= 2840 / divisor
            }
            #expect(
                Double(errors.reduce(0, +)) / Double(errors.count) <= 3,
                "preview divisor \(divisor)")
            #expect(errors.sorted()[errors.count * 95 / 100] <= 7, "preview divisor \(divisor)")
            let edges = edgeDifferences(rendered, grid: grid) {
                $0 < 1000 / divisor || $0 >= 2840 / divisor
            }
            #expect(edges.max()! <= 36, "preview divisor \(divisor): edge maximum \(edges.max()!)")
            var foregroundOnly = project
            try foregroundOnly.setVisualEffects(.init(framing: .fullWidth), clipID: id)
            let plain = try frame(
                await VideoRenderPipeline.make(
                    project: foregroundOnly, maxDimension: 3840 / divisor, previewOnly: divisor == 4
                ))
            let foregroundRow = CGRect(x: 0, y: 1920 / divisor, width: 2160 / divisor, height: 1)
            let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
            #expect(
                pixels(rendered, bounds: foregroundRow, colorSpace: p3)
                    == pixels(plain, bounds: foregroundRow, colorSpace: p3))
        }
        let projectURL = directory.appendingPathComponent("synthetic.openscreen")
        try project.save(to: projectURL)
        let projectBytes = try Data(contentsOf: projectURL)
        let output = directory.appendingPathComponent("synthetic.mp4")
        var settings = VideoDeliverySettings()
        settings.codec = .hevc10
        let result = try await VideoEditorService.render(projectURL, to: output, settings: settings)
        #expect(result.videoReport?.colorPrimaries == AVVideoColorPrimaries_P3_D65)
        let asset = AVURLAsset(url: output)
        let reader = try AVAssetReader(asset: asset)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let decoded = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                AVVideoAllowWideColorKey: true,
            ])
        reader.add(decoded)
        try #require(reader.startReading())
        defer { reader.cancelReading() }
        let sample = try #require(decoded.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        #expect(CVPixelBufferGetWidth(buffer) == 2160 && CVPixelBufferGetHeight(buffer) == 3840)
        let grid = try #require(reference.cases.first { $0.name == "p3" && $0.divisor == 1 })
        let errors = differences(CIImage(cvPixelBuffer: buffer), grid: grid) {
            $0 < 1000 || $0 >= 2840
        }
        #expect(Double(errors.reduce(0, +)) / Double(errors.count) <= 3)
        #expect(errors.sorted()[errors.count * 95 / 100] <= 7)
        #expect(SHA256.hash(data: try Data(contentsOf: url)) == checksum)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
    }

    private func frame(_ pipeline: VideoRenderPipeline) throws -> CIImage {
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return CIImage(cgImage: try generator.copyCGImage(at: .zero, actualTime: nil))
    }

    private func reference() throws -> Reference {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("scripts/fixtures/background-blur-reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    private func source(_ name: String) throws -> CGImage {
        let colors: [[UInt8]] =
            name == "p3"
            ? [[230, 64, 32], [32, 192, 224], [64, 32, 224], [224, 208, 64]]
            : [[255, 0, 0], [0, 255, 255], [0, 0, 255], [255, 255, 0]]
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

    private func differences(
        _ image: CIImage, grid: SampleGrid, includeRow: (Int) -> Bool = { _ in true }
    ) -> [Int] {
        let width = 2160 / grid.divisor
        let height = 3840 / grid.divisor
        let bytes = pixels(image, bounds: CGRect(x: 0, y: 0, width: width, height: height))
        var errors: [Int] = []
        for (row, y) in grid.ys.enumerated() {
            guard includeRow(y) else { continue }
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

    private func edgeDifferences(
        _ image: CIImage, grid: SampleGrid, includeRow: (Int) -> Bool = { _ in true }
    ) -> [Int] {
        let width = 2160 / grid.divisor
        let height = 3840 / grid.divisor
        let bytes = pixels(image, bounds: CGRect(x: 0, y: 0, width: width, height: height))
        var errors: [Int] = []
        for sample in grid.edges where includeRow(sample[1]) {
            let offset = (sample[1] * width + sample[0]) * 4
            #expect(bytes[offset + 3] == 255)
            for channel in 0..<3 {
                errors.append(abs(Int(bytes[offset + channel]) - sample[channel + 2]))
            }
        }
        return errors
    }
}
