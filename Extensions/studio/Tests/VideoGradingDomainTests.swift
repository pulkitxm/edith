import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import Testing
@testable import StudioExtension

@Suite struct VideoGradingDomainTests {
    static let video709 = CVImageBufferCreateColorSpaceFromAttachments(
        [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary)!.takeRetainedValue()

    static let colors: [[UInt8]] = [
        [32, 32, 32], [64, 64, 64], [96, 96, 96], [128, 128, 128], [192, 192, 192],
        [224, 224, 224],
        [180, 65, 55], [70, 150, 75], [50, 90, 180], [180, 150, 50], [160, 65, 150],
        [60, 155, 165],
        [115, 82, 68], [194, 150, 130], [98, 122, 157], [87, 108, 67], [133, 128, 177],
        [103, 189, 170],
        [214, 126, 44], [80, 91, 166], [193, 90, 99], [94, 60, 108], [157, 188, 64],
        [224, 163, 46],
    ]

    @Test(.enabled(if: VideoGradingTests.ffmpeg != nil), arguments: [false, true], [false, true])
    func taggedVideoMatchesEncodedAndColorManagedReferences(_ full: Bool, _ hevc: Bool) async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await fixture(directory, full: full, hevc: hevc)
        var project = VideoProject.create()
        project.addAsset(source, duration: 0.1, width: 1920, height: 1080)
        let id = project.clips[0].id
        for width in [1920, 3840] {
            let height = width * 9 / 16
            project.videoSettings = VideoSettings(width: width, height: height)
            for controls in [[1.0, 1, 0], [1.02, 1.035, 0.002], [1.1, 1.2, 0.03]] {
                let data = try reference(
                    source, directory: directory, full: full, width: width, controls: controls)
                for domain in [VideoVisualEffects.GradingDomain.bt709ToSRGB, .bt709] {
                    let expected = CIImage(
                        bitmapData: data, bytesPerRow: width * 4,
                        size: CGSize(width: width, height: height), format: .RGBA8,
                        colorSpace: domain == .bt709
                            ? Self.video709 : CGColorSpace(name: CGColorSpace.sRGB)!
                    )
                    try project.setVisualEffects(
                        .init(
                            contrast: controls[0], saturation: controls[1],
                            gradingMode: .ffmpeg709, gradingDomain: domain), clipID: id)
                    var effects = project.clips[0].visualEffects
                    effects.brightness = controls[2]
                    try project.setVisualEffects(effects, clipID: id)
                    let image = try await VideoGradingRenderTests().frame(project, dimension: width)
                    let error = errors(
                        samples(image, width: width), samples(expected, width: width))
                    print(
                        "video full=\(full) HEVC10=\(hevc) width=\(width) domain=\(domain) \(controls): MAE=\(error.mean) max=\(error.maximum)"
                    )
                    #expect(error.maximum <= 6)
                    #expect(error.mean <= 1.5)
                }
            }
        }
    }

    func fixture(_ directory: URL, full: Bool, hevc: Bool = false) async throws -> URL {
        let chart = directory.appendingPathComponent("chart.png")
        let rgba: [UInt8] = Self.colors.flatMap { $0 + [255] }
        let image = CIImage(
            bitmapData: Data(rgba), bytesPerRow: 6 * 4,
            size: CGSize(width: 6, height: 4), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        try VideoImageContext.shared.writePNGRepresentation(
            of: image, to: chart, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let source = directory.appendingPathComponent("source.mp4")
        let range = full ? "full" : "limited"
        let format = hevc ? "yuv420p10le" : "yuv420p"
        let filter =
            "scale=1920:1080:flags=neighbor:in_range=full:out_range=\(range):out_color_matrix=bt709,format=\(format),setparams=range=\(range):color_primaries=bt709:color_trc=bt709:colorspace=bt709"
        let codec =
            hevc
            ? [
                "-c:v", "libx265", "-x265-params", "lossless=1:pools=2:log-level=error", "-tag:v",
                "hvc1",
            ] : ["-c:v", "libx264", "-crf", "0", "-threads", "2"]
        try ffmpeg(
            ["-loop", "1", "-i", chart.path, "-vf", filter, "-frames:v", "3", "-r", "30"] + codec
                + [source.path])
        let track = try #require(
            try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let metadata = try #require(CMFormatDescriptionGetExtensions(description)) as NSDictionary
        #expect(
            metadata[kCMFormatDescriptionExtension_ColorPrimaries] as? String
                == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(
            metadata[kCMFormatDescriptionExtension_TransferFunction] as? String
                == AVVideoTransferFunction_ITU_R_709_2)
        #expect(
            metadata[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
                == AVVideoYCbCrMatrix_ITU_R_709_2)
        #expect((metadata[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool ?? false) == full)
        return source
    }

    func reference(_ source: URL, directory: URL, full: Bool, width: Int, controls: [Double]) throws
        -> Data
    {
        let output = directory.appendingPathComponent("reference.rgba")
        let filter =
            "scale=\(width):\(width * 9 / 16):flags=lanczos:in_color_matrix=bt709:out_color_matrix=bt709:in_range=\(full ? "full" : "limited"):out_range=limited,eq=contrast=\(controls[0]):saturation=\(controls[1]):brightness=\(controls[2]),scale=in_color_matrix=bt709:in_range=limited:out_range=full,format=rgba"
        try ffmpeg([
            "-i", source.path, "-vf", filter, "-frames:v", "1", "-f", "rawvideo", output.path,
        ])
        return try Data(contentsOf: output)
    }

    func ffmpeg(_ arguments: [String]) throws {
        let result = try CLIProcessProbe.run(
            ["-v", "error", "-y"] + arguments,
            executable: try #require(VideoGradingTests.ffmpeg), timeout: 120)
        try #require(result.code == 0, "\(result.stderr)")
    }

    func samples(_ image: CIImage, width: Int) -> [UInt8] {
        var result: [UInt8] = []
        for row in 0..<4 {
            for column in 0..<6 {
                var pixel = [UInt8](repeating: 0, count: 4)
                VideoImageContext.shared.render(
                    image, toBitmap: &pixel, rowBytes: 4,
                    bounds: CGRect(
                        x: (column * 2 + 1) * width / 12,
                        y: (row * 2 + 1) * width * 9 / 128, width: 1, height: 1),
                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                result += pixel.prefix(3)
            }
        }
        return result
    }

    func errors(_ actual: [UInt8], _ expected: [UInt8]) -> (maximum: Int, mean: Double) {
        let values = zip(actual, expected).map { abs(Int($0) - Int($1)) }
        return (values.max()!, Double(values.reduce(0, +)) / Double(values.count))
    }
}
