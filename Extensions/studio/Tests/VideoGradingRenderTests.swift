import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import CryptoKit
import Testing
@testable import StudioExtension

@Suite struct VideoGradingRenderTests {
    @Test(.enabled(if: VideoGradingTests.ffmpeg != nil), arguments: [false, true])
    func composedOriginalsMatchReferenceAtNativeAndPreviewSizes(_ wide: Bool) async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic.png")
        let space = CGColorSpace(name: wide ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let bounds = CGRect(x: 0, y: 0, width: 720, height: 480)
        let sky = CIFilter(
            name: "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 720, y: 480),
                "inputColor0": CIColor(red: 0.04, green: 0.1, blue: 0.5, colorSpace: space)!,
                "inputColor1": CIColor(red: 0.9, green: 0.3, blue: 0.05, colorSpace: space)!,
            ])!.outputImage!.cropped(to: bounds)
        let foreground = CIImage(
            color: CIColor(red: 0.1, green: 0.65, blue: 0.18, colorSpace: space)!
        )
        .cropped(to: CGRect(x: 0, y: 0, width: 720, height: 140))
        try VideoImageContext.shared.writePNGRepresentation(
            of: foreground.composited(over: sky), to: source, format: .RGBA16, colorSpace: space)
        let checksum = SHA256.hash(data: try Data(contentsOf: source))
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 2160, height: 3840)
        try project.addStillAsset(
            source, duration: 0.1, metadata: VideoStillMedia.metadata(at: source))
        let id = project.clips[0].id
        let harness = VideoGradingTests()
        for dimension in [3840, 960] {
            let width = dimension * 9 / 16
            var effects = VideoVisualEffects(framing: .fullWidth, background: .init(blurRadius: 65))
            try project.setVisualEffects(effects, clipID: id)
            let ungraded = try await frame(project, dimension: dimension)
            let input = harness.pixels(ungraded, width: width, height: dimension)
            for controls in [[1.0, 1, 0], [1.02, 1.035, 0.002], [1.1, 1.2, 0.03]] {
                effects.gradingMode = .ffmpeg709
                effects.contrast = controls[0]
                effects.saturation = controls[1]
                effects.brightness = controls[2]
                try project.setVisualEffects(effects, clipID: id)
                let rendered = try await frame(project, dimension: dimension)
                let actual = harness.pixels(rendered, width: width, height: dimension)
                let reference = try harness.reference(
                    input, width: width, height: dimension, effects: effects)
                let error = difference(actual, reference)
                print(
                    "composite P3=\(wide) \(width)x\(dimension) \(controls): max=\(error.maximum) MAE=\(error.mean)"
                )
                let maximumBudget = controls[0] == 1 ? 5 : controls[0] == 1.02 ? 6 : 7
                #expect(error.maximum <= maximumBudget)
                #expect(error.mean <= 0.75)
            }
        }
        #expect(SHA256.hash(data: try Data(contentsOf: source)) == checksum)
    }

    func frame(_ project: VideoProject, dimension: Int) async throws -> CIImage {
        let pipeline = try await VideoRenderPipeline.make(project: project, maxDimension: dimension)
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return CIImage(cgImage: try generator.copyCGImage(at: .zero, actualTime: nil))
    }

    func difference(_ actual: [UInt8], _ reference: [UInt8]) -> (maximum: Int, mean: Double) {
        var maximum = 0
        var total = 0
        for index in actual.indices where index % 4 != 3 {
            let error = abs(Int(actual[index]) - Int(reference[index]))
            maximum = max(maximum, error)
            total += error
        }
        return (maximum, Double(total) / Double(actual.count / 4 * 3))
    }
}
