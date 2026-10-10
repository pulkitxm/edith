import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import Testing
@testable import StudioExtension

@Suite struct VideoGradingMotionTests {
    @Test(.enabled(if: VideoGradingTests.ffmpeg != nil))
    func encodedMotionFrameMatchesIndependentFullRasterReference() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = VideoGradingDomainTests()
        let source = directory.appendingPathComponent("motion.mp4")
        try harness.ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=0.2",
            "-vf", "setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709",
            "-c:v", "libx264", "-crf", "0", "-threads", "2", source.path,
        ])
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 1920, height: 1080)
        project.addAsset(source, duration: 0.2, width: 1920, height: 1080)
        let data = try harness.reference(
            source, directory: directory, full: false, width: 1920,
            controls: [1.02, 1.035, 0.002])
        let expected = CIImage(
            bitmapData: data, bytesPerRow: 1920 * 4,
            size: CGSize(width: 1920, height: 1080), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let wanted = VideoGradingTests().pixels(expected, width: 1920, height: 1080)
        try project.setVisualEffects(
            .init(
                brightness: 0.002, contrast: 1.02, saturation: 1.035,
                gradingMode: .ffmpeg709, gradingDomain: .bt709ToSRGB), clipID: project.clips[0].id)
        let image = try await VideoGradingRenderTests().frame(project, dimension: 1920)
        let actual = VideoGradingTests().pixels(image, width: 1920, height: 1080)
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        for index in actual.indices where index % 4 != 3 {
            let error = abs(Int(actual[index]) - Int(wanted[index]))
            histogram[error] += 1
            total += error
        }
        let count = actual.count / 4 * 3
        let mean = Double(total) / Double(count)
        var cumulative = 0
        let p95 = histogram.indices.first {
            cumulative += histogram[$0]
            return Double(cumulative) >= Double(count) * 0.95
        }!
        print("encoded motion full-raster RGB8 MAE=\(mean) p95=\(p95)")
        #expect(mean <= 2)
        #expect(p95 <= 4)
    }
}
