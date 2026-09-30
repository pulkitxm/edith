import AVFoundation
import CoreImage
import CryptoKit
import Testing
@testable import Edith

@Suite struct VideoGradingDomainDeliveryTests {
    @Test(.enabled(if: VideoGradingTests.ffmpeg != nil), arguments: [false, true], [false, true])
    func taggedVideoSurvivesDeliveryAndKeepsCaptionsUngraded(_ full: Bool, _ p3: Bool) async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = VideoGradingDomainTests()
        let source = try await harness.fixture(directory, full: full, hevc: true)
        let checksum = SHA256.hash(data: try Data(contentsOf: source))
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(
            width: 1920, height: 1080, colorSpace: p3 ? .displayP3 : .rec709)
        project.addAsset(source, duration: 0.1, width: 1920, height: 1080)
        project.addText("synthetic caption", startMs: 0, endMs: 100)
        project.setAnnotationStyle(
            project.annotations[0].id, key: "backgroundColor", value: "#c86496")
        let controls = [1.02, 1.035, 0.002]
        let data = try harness.reference(
            source, directory: directory, full: full, width: 1920, controls: controls)
        for domain in [VideoVisualEffects.GradingDomain.bt709ToSRGB, .bt709] {
            try project.setVisualEffects(
                .init(
                    brightness: controls[2], contrast: controls[0], saturation: controls[1],
                    gradingMode: .ffmpeg709, gradingDomain: domain), clipID: project.clips[0].id)
            let url = directory.appendingPathComponent("synthetic.openscreen")
            try project.save(to: url)
            project = try VideoProject.open(url)
            let expected = CIImage(
                bitmapData: data, bytesPerRow: 1920 * 4,
                size: CGSize(width: 1920, height: 1080), format: .RGBA8,
                colorSpace: domain == .bt709
                    ? VideoGradingDomainTests.video709 : CGColorSpace(name: CGColorSpace.sRGB)!
            )
            let native = try await VideoGradingRenderTests().frame(project, dimension: 1920)
            let output = directory.appendingPathComponent("\(domain).mp4")
            var settings = VideoDeliverySettings()
            settings.codec = .hevc10
            _ = try await VideoEditorService.render(url, to: output, settings: settings)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let delivered = CIImage(cgImage: try generator.copyCGImage(at: .zero, actualTime: nil))
            for (label, image) in [("native", native), ("delivery", delivered)] {
                let error = harness.errors(
                    harness.samples(image, width: 1920), harness.samples(expected, width: 1920))
                print(
                    "\(label) video full=\(full) P3=\(p3) domain=\(domain): MAE=\(error.mean) max=\(error.maximum)"
                )
                #expect(error.maximum <= 6)
                #expect(error.mean <= 2)
                var caption = [UInt8](repeating: 0, count: 4)
                VideoImageContext.shared.render(
                    image, toBitmap: &caption, rowBytes: 4,
                    bounds: CGRect(x: 400, y: 216, width: 1, height: 1), format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                #expect(
                    zip(caption.prefix(3), [200, 100, 150]).allSatisfy { abs(Int($0) - $1) <= 4 })
            }
        }
        #expect(SHA256.hash(data: try Data(contentsOf: source)) == checksum)
    }
}
