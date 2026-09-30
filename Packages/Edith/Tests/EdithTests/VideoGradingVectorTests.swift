import CoreImage
import Testing
@testable import Edith

@Suite struct VideoGradingVectorTests {
    @Test func pinnedFFmpegNineRGB8Vectors() throws {
        let source: [[UInt8]] = [
            [32, 32, 32], [64, 64, 64], [96, 96, 96], [128, 128, 128], [192, 192, 192],
            [224, 224, 224],
            [180, 65, 55], [70, 150, 75], [50, 90, 180], [180, 150, 50], [160, 65, 150],
            [60, 155, 165],
            [115, 82, 68], [194, 150, 130], [98, 122, 157], [87, 108, 67], [133, 128, 177],
            [103, 189, 170],
            [214, 126, 44], [80, 91, 166], [193, 90, 99], [94, 60, 108], [157, 188, 64],
            [224, 163, 46],
        ]
        let references: [[UInt8]] = [
            [
                31, 31, 31, 64, 64, 64, 95, 95, 95, 128, 128, 128, 192, 192, 192, 224, 224, 224,
                180, 65, 55, 71, 150, 75, 51, 90, 181, 180, 150, 50, 159, 65, 150, 60, 154, 165,
                115, 82, 69, 194, 150, 131, 98, 122, 158, 86, 108, 66, 133, 128, 177, 103, 189, 169,
                214, 126, 44, 80, 91, 166, 194, 90, 100, 94, 60, 109, 156, 188, 65, 225, 163, 45,
            ],
            [
                26, 29, 26, 60, 62, 60, 91, 94, 91, 125, 128, 125, 190, 193, 190, 223, 225, 223,
                179, 62, 48, 66, 151, 70, 45, 89, 181, 178, 149, 42, 157, 62, 148, 55, 155, 161,
                111, 81, 65, 194, 151, 129, 95, 122, 157, 83, 108, 61, 130, 128, 176, 99, 190, 167,
                213, 125, 36, 76, 90, 164, 194, 89, 97, 90, 58, 107, 154, 189, 58, 225, 164, 39,
            ],
            [
                25, 28, 25, 61, 64, 61, 95, 97, 95, 131, 133, 131, 202, 205, 202, 236, 238, 235,
                197, 62, 47, 63, 160, 67, 43, 92, 200, 190, 158, 36, 173, 61, 162, 49, 165, 175,
                120, 83, 64, 208, 158, 131, 97, 127, 168, 83, 113, 60, 136, 133, 188, 97, 202, 176,
                232, 130, 28, 76, 93, 180, 211, 90, 100, 97, 57, 114, 160, 201, 51, 242, 171, 26,
            ],
        ]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CIImage(
            bitmapData: Data(source.flatMap { $0 + [255] }), bytesPerRow: 96,
            size: CGSize(width: 24, height: 1), format: .RGBA8, colorSpace: space)
        for (controls, reference) in zip(
            [[1.0, 1, 0], [1.02, 1.035, 0.002], [1.1, 1.2, 0.03]], references)
        {
            let grade = VideoVisualEffects(
                brightness: controls[2], contrast: controls[0], saturation: controls[1],
                gradingMode: .ffmpeg709)
            let graded = try #require(VideoGrading.apply(image, effects: grade))
            var rgba = [UInt8](repeating: 0, count: 96)
            VideoImageContext.shared.render(
                graded, toBitmap: &rgba, rowBytes: 96,
                bounds: CGRect(x: 0, y: 0, width: 24, height: 1), format: .RGBA8, colorSpace: space)
            let actual = rgba.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
            #expect(zip(actual, reference).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        }
    }
}
