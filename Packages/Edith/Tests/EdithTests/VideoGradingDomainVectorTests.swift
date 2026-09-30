import CoreImage
import Testing
@testable import Edith

@Suite struct VideoGradingDomainVectorTests {
    @Test(arguments: [VideoVisualEffects.GradingDomain.bt709, .bt709ToSRGB])
    func videoTransferIsRecoveredBeforeEQ(_ domain: VideoVisualEffects.GradingDomain) throws {
        let source: [UInt8] = [
            32, 32, 32, 255, 128, 128, 128, 255, 180, 65, 55, 255,
            50, 90, 180, 255, 160, 65, 150, 255, 194, 150, 130, 255,
        ]
        let reference: [UInt8] = [
            26, 29, 26, 255, 125, 128, 125, 255, 179, 62, 48, 255,
            45, 89, 181, 255, 157, 62, 148, 255, 194, 151, 129, 255,
        ]
        let image = CIImage(
            bitmapData: Data(source), bytesPerRow: 24,
            size: CGSize(width: 6, height: 1), format: .RGBA8,
            colorSpace: VideoGradingDomainTests.video709)
        let expected = CIImage(
            bitmapData: Data(reference), bytesPerRow: 24,
            size: CGSize(width: 6, height: 1), format: .RGBA8,
            colorSpace: domain == .bt709
                ? VideoGradingDomainTests.video709 : CGColorSpace(name: CGColorSpace.sRGB)!)
        let effects = VideoVisualEffects(
            brightness: 0.002, contrast: 1.02, saturation: 1.035,
            gradingMode: .ffmpeg709, gradingDomain: domain)
        let graded = try #require(VideoGrading.apply(image, effects: effects))
        let harness = VideoGradingTests()
        let actual = harness.pixels(graded, width: 6, height: 1)
        let wanted = harness.pixels(expected, width: 6, height: 1)
        #expect(zip(actual, wanted).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }
}
