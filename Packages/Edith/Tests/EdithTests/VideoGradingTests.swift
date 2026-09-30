import AVFoundation
import CoreImage
import Testing
@testable import Edith

@Suite struct VideoGradingTests {
    private static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    @Test(
        .enabled(if: ffmpeg != nil),
        arguments: [
            [1.0, 1, 0], [1.02, 1.035, 0.002], [1.1, 1.2, 0.03],
            [0.8, 0.7, -0.04], [4, 3, 0.5], [0, 0, -1], [1.0001, 1.0001, 0.00001],
        ])
    func encodedEQMatchesIndependentReference(_ controls: [Double]) throws {
        let width = 512
        let height = 128
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                bytes += [UInt8(x % 256), UInt8(y * 2), UInt8((x / 2 + y) % 256), 255]
            }
        }
        let image = CIImage(
            bitmapData: Data(bytes), bytesPerRow: width * 4,
            size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: space)
        let effects = VideoVisualEffects(
            brightness: controls[2], contrast: controls[0], saturation: controls[1],
            gradingMode: .ffmpeg709)
        let graded = try #require(VideoGrading.apply(image, effects: effects))
        let native = pixels(graded, width: width, height: height)
        let reference = try reference(bytes, width: width, height: height, effects: effects)
        let errors = zip(native, reference).enumerated().filter { $0.offset % 4 != 3 }
            .map { abs(Int($0.element.0) - Int($0.element.1)) }
        let maximum = errors.max() ?? 0
        let mean = Double(errors.reduce(0, +)) / Double(errors.count)
        print("EQ reference \(controls): RGB8 maximum \(maximum), MAE \(mean)")
        #expect(maximum <= 1)
        #expect(mean <= 0.01)
    }

    private func pixels(_ image: CIImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        VideoImageContext.shared.render(
            image, toBitmap: &bytes, rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: space)
        return bytes
    }

    private func reference(_ bytes: [UInt8], width: Int, height: Int, effects: VideoVisualEffects)
        throws -> [UInt8]
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.rgba")
        let output = directory.appendingPathComponent("output.rgba")
        try Data(bytes).write(to: source)
        let filters =
            "scale=in_range=full:out_range=limited:out_color_matrix=bt709,format=yuv444p,eq=brightness=\(effects.brightness):contrast=\(effects.contrast):saturation=\(effects.saturation),scale=in_range=limited:out_range=full:in_color_matrix=bt709,format=rgba"
        let result = try CLIProcessProbe.run(
            [
                "-v", "error", "-f", "rawvideo", "-pixel_format", "rgba", "-video_size",
                "\(width)x\(height)",
                "-i", source.path, "-vf", filters, "-frames:v", "1", "-f", "rawvideo", output.path,
            ], executable: try #require(Self.ffmpeg), timeout: 60)
        try #require(result.code == 0, "\(result.stderr)")
        let data = try Data(contentsOf: output)
        try #require(data.count == bytes.count)
        return Array(data)
    }
}
