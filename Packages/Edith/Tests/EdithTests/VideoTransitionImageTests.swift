import CoreImage
import Testing
@testable import Edith

@Suite struct VideoTransitionImageTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    private func red(_ image: CIImage, x: Int, y: Int) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Int(pixel[0])
    }

    @Test func blurFadeSuppressesDetailAndPreservesOpaqueCanvas() throws {
        let bounds = CGRect(x: 0, y: 0, width: 128, height: 128)
        let checker = try #require(
            CIFilter(
                name: "CICheckerboardGenerator",
                parameters: ["inputWidth": 2, "inputSharpness": 1])?.outputImage
        ).cropped(to: bounds)
        let faded = VideoTransitionImage.apply(checker, kind: "fade", intensity: 0.5)
        let blurred = VideoTransitionImage.apply(checker, kind: "blur", intensity: 0.5)
        #expect(blurred.extent == bounds)
        let originalContrast = abs(red(faded, x: 64, y: 64) - red(faded, x: 66, y: 64))
        let blurredContrast = abs(red(blurred, x: 64, y: 64) - red(blurred, x: 66, y: 64))
        #expect(originalContrast > 50)
        #expect(blurredContrast < originalContrast / 2)
    }

    @Test func zoomFadeMagnifiesAroundCanvasCenter() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let image = CIImage(color: .white).cropped(to: CGRect(x: 40, y: 40, width: 20, height: 20))
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        let faded = VideoTransitionImage.apply(image, kind: "fade", intensity: 0.5)
        let zoomed = VideoTransitionImage.apply(image, kind: "zoom", intensity: 0.5)
        #expect(zoomed.extent == bounds)
        #expect(red(faded, x: 39, y: 50) == 0)
        #expect(red(zoomed, x: 39, y: 50) > 50)
        #expect(abs(red(zoomed, x: 50, y: 50) - red(faded, x: 50, y: 50)) <= 1)
    }

    @Test(arguments: VideoTransitionImage.kinds)
    func endpointsPreserveSourceAndConcealTheCut(_ kind: String) {
        let image = CIImage(color: CIColor(red: 0.6, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        #expect(
            red(VideoTransitionImage.apply(image, kind: kind, intensity: 0), x: 32, y: 32) == 153)
        #expect(
            red(VideoTransitionImage.apply(image, kind: kind, intensity: 1), x: 32, y: 32)
                == (kind == "flash" ? 255 : 0))
    }
}
