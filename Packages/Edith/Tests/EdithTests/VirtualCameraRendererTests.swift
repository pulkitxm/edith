import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing

@testable import EdithKit

@Suite(.serialized) struct VirtualCameraRendererTests {
    static let renderer = VirtualCameraRenderer()
    let output = CGSize(width: 320, height: 180)

    struct RGB {
        let red: Int
        let green: Int
        let blue: Int

        func near(_ other: RGB, tolerance: Int = 12) -> Bool {
            abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance
                && abs(blue - other.blue) <= tolerance
        }

        static let red = RGB(red: 255, green: 0, blue: 0)
        static let green = RGB(red: 0, green: 255, blue: 0)
        static let blue = RGB(red: 0, green: 0, blue: 255)
        static let white = RGB(red: 255, green: 255, blue: 255)
        static let black = RGB(red: 0, green: 0, blue: 0)
    }

    static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ rect: CGRect) -> CIImage
    {
        CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: rect)
    }

    static func quadrants(width: CGFloat = 1600, height: CGFloat = 900) -> CIImage {
        let halfWidth = width / 2
        let halfHeight = height / 2
        let topLeft = solid(
            1, 0, 0, CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight))
        let topRight = solid(
            0, 1, 0, CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight))
        let bottomLeft = solid(0, 0, 1, CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight))
        let bottomRight = solid(
            1, 1, 1, CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight))
        return topLeft.composited(over: topRight).composited(over: bottomLeft)
            .composited(over: bottomRight)
    }

    static func gray(_ level: CGFloat, size: CGSize = CGSize(width: 640, height: 360)) -> CIImage {
        solid(level, level, level, CGRect(origin: .zero, size: size))
    }

    func pixels(_ image: CIImage, size: CGSize? = nil) throws -> (Int, Int) -> RGB {
        let size = size ?? output
        let cgImage = try #require(Self.renderer.cgImage(image, size: size))
        let width = cgImage.width
        let height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &data, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let copy = data
        return { x, y in
            let offset = (y * width + x) * 4
            return RGB(
                red: Int(copy[offset]), green: Int(copy[offset + 1]), blue: Int(copy[offset + 2]))
        }
    }

    func compose(
        _ composition: VirtualCameraComposition, image: CIImage? = nil, mask: CIImage? = nil
    )
        -> CIImage
    {
        Self.renderer.compose(
            VirtualCameraFrameInput(
                image: image ?? Self.quadrants(), composition: composition, mask: mask),
            output: output)
    }

    @Test func identityFramingKeepsTheQuadrantsInPlace() throws {
        let pixel = try pixels(compose(VirtualCameraComposition()))
        #expect(pixel(40, 30).near(.red))
        #expect(pixel(280, 30).near(.green))
        #expect(pixel(40, 150).near(.blue))
        #expect(pixel(280, 150).near(.white))
    }

    @Test func flipsMirrorTheQuadrants() throws {
        let horizontal = try pixels(
            compose(VirtualCameraComposition(framing: VirtualCameraFraming(flipHorizontal: true))))
        #expect(horizontal(40, 30).near(.green))
        #expect(horizontal(280, 150).near(.blue))
        let vertical = try pixels(
            compose(VirtualCameraComposition(framing: VirtualCameraFraming(flipVertical: true))))
        #expect(vertical(40, 30).near(.blue))
        #expect(vertical(280, 30).near(.white))
    }

    @Test func quarterTurnRotatesClockwise() throws {
        let rotated = VirtualCameraRenderer.oriented(
            Self.quadrants(), framing: VirtualCameraFraming(quarterTurns: 1))
        #expect(rotated.extent == CGRect(x: 0, y: 0, width: 900, height: 1600))
        let size = CGSize(width: 180, height: 320)
        let pixel = try pixels(
            rotated.transformed(by: CGAffineTransform(scaleX: 0.2, y: 0.2)), size: size)
        #expect(pixel(20, 20).near(.blue))
        #expect(pixel(160, 20).near(.red))
        #expect(pixel(160, 300).near(.green))
        #expect(pixel(20, 300).near(.white))
    }

    @Test func zoomCropsIntoTheChosenCenter() throws {
        let topLeft = try pixels(
            compose(
                VirtualCameraComposition(
                    framing: VirtualCameraFraming(zoom: 2.2, centerX: 0.25, centerY: 0.25))))
        for point in [(5, 5), (160, 90), (314, 174)] {
            #expect(topLeft(point.0, point.1).near(.red))
        }
        let bottomRight = try pixels(
            compose(
                VirtualCameraComposition(
                    framing: VirtualCameraFraming(zoom: 2.2, centerX: 0.75, centerY: 0.75))))
        #expect(bottomRight(160, 90).near(.white))
    }

    @Test func tiltNeverShowsEmptyCorners() throws {
        let pixel = try pixels(
            compose(VirtualCameraComposition(framing: VirtualCameraFraming(tilt: 20))))
        for point in [(0, 0), (319, 0), (0, 179), (319, 179)] {
            #expect(!pixel(point.0, point.1).near(.black, tolerance: 30))
        }
    }

    @Test func monoAndNoirRemoveColor() throws {
        for preset in [VirtualCameraLookPreset.mono, .noir] {
            let pixel = try pixels(
                compose(VirtualCameraComposition(look: VirtualCameraLook(preset: preset))))
            let sample = pixel(40, 30)
            #expect(abs(sample.red - sample.green) < 6 && abs(sample.green - sample.blue) < 6)
        }
    }

    @Test func warmthPushesRedAndCoolingPushesBlue() throws {
        let base = Self.gray(0.5)
        let warm = try pixels(
            Self.renderer.compose(
                VirtualCameraFrameInput(
                    image: base,
                    composition: VirtualCameraComposition(look: VirtualCameraLook(warmth: 0.8))),
                output: output))(160, 90)
        let cool = try pixels(
            Self.renderer.compose(
                VirtualCameraFrameInput(
                    image: base,
                    composition: VirtualCameraComposition(look: VirtualCameraLook(warmth: -0.8))),
                output: output))(160, 90)
        #expect(warm.red > warm.blue + 10)
        #expect(cool.blue > cool.red + 10)
        let warmPreset = try pixels(
            Self.renderer.compose(
                VirtualCameraFrameInput(
                    image: base,
                    composition: VirtualCameraComposition(look: VirtualCameraLook(preset: .warm))),
                output: output))(160, 90)
        #expect(warmPreset.red > warmPreset.blue)
    }

    @Test func exposureAndIntensityScaleTheEffect() throws {
        let base = Self.gray(0.3)
        func brightness(_ look: VirtualCameraLook) throws -> Int {
            try pixels(
                Self.renderer.compose(
                    VirtualCameraFrameInput(
                        image: base, composition: VirtualCameraComposition(look: look)),
                    output: output))(160, 90).green
        }
        let neutral = try brightness(VirtualCameraLook())
        #expect(try brightness(VirtualCameraLook(exposure: 1)) > neutral + 20)
        #expect(try brightness(VirtualCameraLook(exposure: -1)) < neutral - 20)
        let full = try brightness(VirtualCameraLook(preset: .bright, intensity: 1))
        let half = try brightness(VirtualCameraLook(preset: .bright, intensity: 0.5))
        #expect(full > half && half > neutral)
    }

    @Test func colorBackgroundReplacesWhatTheMaskExcludes() throws {
        let size = CGSize(width: 1600, height: 900)
        let mask = Self.solid(1, 1, 1, CGRect(x: 0, y: 0, width: 800, height: 900))
            .composited(over: Self.solid(0, 0, 0, CGRect(origin: .zero, size: size)))
            .transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let composition = VirtualCameraComposition(
            background: VirtualCameraBackground(
                mode: .color, color: VirtualCameraColor(hex: "#FF00FF") ?? .black))
        let pixel = try pixels(compose(composition, mask: mask))
        #expect(pixel(40, 30).near(.red))
        #expect(pixel(40, 150).near(.blue))
        #expect(pixel(280, 30).near(RGB(red: 255, green: 0, blue: 255)))
        #expect(pixel(280, 150).near(RGB(red: 255, green: 0, blue: 255)))
        let withoutMask = try pixels(compose(composition))
        #expect(withoutMask(280, 30).near(.green))
    }

    @Test func blurredBackgroundKeepsThePersonSharp() throws {
        let mask = Self.solid(1, 1, 1, CGRect(x: 0, y: 450, width: 800, height: 450))
            .composited(over: Self.solid(0, 0, 0, CGRect(x: 0, y: 0, width: 1600, height: 900)))
        let pixel = try pixels(
            compose(
                VirtualCameraComposition(background: VirtualCameraBackground(mode: .blur, blur: 1)),
                mask: mask))
        #expect(pixel(40, 30).near(.red))
        let blurredEdge = pixel(160, 150)
        #expect(!blurredEdge.near(.blue, tolerance: 20) && !blurredEdge.near(.white, tolerance: 20))
    }

    @Test func imageBackgroundFillsTheFrame() throws {
        let picture = Self.solid(1, 1, 0, CGRect(x: 0, y: 0, width: 400, height: 400))
        let mask = Self.solid(0, 0, 0, CGRect(x: 0, y: 0, width: 1600, height: 900))
        let pixel = try pixels(
            Self.renderer.compose(
                VirtualCameraFrameInput(
                    image: Self.quadrants(),
                    composition: VirtualCameraComposition(
                        background: VirtualCameraBackground(mode: .image, imagePath: "/unused.png")),
                    mask: mask, assets: VirtualCameraAssets(background: picture)),
                output: output))
        #expect(pixel(5, 5).near(RGB(red: 255, green: 255, blue: 0)))
        #expect(pixel(314, 174).near(RGB(red: 255, green: 255, blue: 0)))
    }

    @Test func borderInsetsThePictureInsideTheMatte() throws {
        let border = VirtualCameraBorder(
            enabled: true, width: 0.02, cornerRadius: 0.08, inset: 0.1, color: .white,
            matte: VirtualCameraColor(hex: "#00FF00") ?? .black)
        let pixel = try pixels(
            Self.renderer.compose(
                VirtualCameraFrameInput(
                    image: Self.gray(0.2, size: CGSize(width: 1600, height: 900)),
                    composition: VirtualCameraComposition(
                        overlays: VirtualCameraOverlays(border: border))),
                output: output))
        #expect(pixel(2, 2).near(.green))
        #expect(pixel(160, 90).near(RGB(red: 51, green: 51, blue: 51), tolerance: 14))
        #expect(pixel(160, 19).near(.white, tolerance: 40))
        #expect(
            VirtualCameraRenderer.pictureRect(output: output, border: border)
                == CGRect(x: 18, y: 18, width: 284, height: 144))
        #expect(
            VirtualCameraRenderer.pictureRect(output: output, border: VirtualCameraBorder())
                == CGRect(origin: .zero, size: output))
    }

    @Test func nameTagDrawsInItsCorner() throws {
        let base = Self.gray(0.5, size: CGSize(width: 1600, height: 900))
        func render(_ tag: VirtualCameraNameTag) throws -> (Int, Int) -> RGB {
            try pixels(
                Self.renderer.compose(
                    VirtualCameraFrameInput(
                        image: base,
                        composition: VirtualCameraComposition(
                            overlays: VirtualCameraOverlays(nameTag: tag))),
                    output: output))
        }
        let plain = try render(VirtualCameraNameTag())
        let tagged = try render(
            VirtualCameraNameTag(enabled: true, title: "Ada Lovelace", subtitle: "Engineer"))
        var changedBottomLeft = 0
        var changedTopRight = 0
        for x in stride(from: 10, to: 150, by: 4) {
            for y in stride(from: 140, to: 172, by: 4)
            where !tagged(x, y).near(plain(x, y), tolerance: 4) {
                changedBottomLeft += 1
            }
            for y in stride(from: 4, to: 40, by: 4)
            where !tagged(x + 160, y).near(plain(x + 160, y), tolerance: 4) {
                changedTopRight += 1
            }
        }
        #expect(changedBottomLeft > 20)
        #expect(changedTopRight == 0)
    }

    @Test func logoAndClockLandInTheirCorners() throws {
        let base = Self.gray(0.5, size: CGSize(width: 1600, height: 900))
        let logo = Self.solid(1, 0, 1, CGRect(x: 0, y: 0, width: 200, height: 100))
        let pixel = try pixels(
            Self.renderer.compose(
                VirtualCameraFrameInput(
                    image: base,
                    composition: VirtualCameraComposition(
                        overlays: VirtualCameraOverlays(
                            logo: VirtualCameraLogo(
                                enabled: true, imagePath: "/logo.png", corner: .topRight,
                                size: 0.2, opacity: 1),
                            clock: VirtualCameraClock(enabled: true, corner: .bottomLeft))),
                    date: Date(timeIntervalSince1970: 0),
                    assets: VirtualCameraAssets(logo: logo)),
                output: output))
        #expect(pixel(290, 15).near(RGB(red: 255, green: 0, blue: 255)))
        #expect(pixel(160, 90).near(RGB(red: 128, green: 128, blue: 128), tolerance: 14))
        var clockPixels = 0
        for x in stride(from: 8, to: 60, by: 2)
        where !pixel(x, 166).near(RGB(red: 128, green: 128, blue: 128), tolerance: 10) {
            clockPixels += 1
        }
        #expect(clockPixels > 5)
    }

    @Test func privacyModesHideTheCamera() throws {
        let backdrop = Self.quadrants(width: 320, height: 180)
        let blank = try pixels(
            Self.renderer.privacyImage(.blank, message: "x", backdrop: backdrop, output: output))
        #expect(blank(160, 90).near(.black))
        #expect(blank(40, 30).near(.black))
        let card = try pixels(
            Self.renderer.privacyImage(
                .card, message: "Back in 5", backdrop: backdrop, output: output))
        #expect(card(10, 10).red < 180)
        let frozen = try pixels(
            Self.renderer.privacyImage(.freeze, message: "x", backdrop: backdrop, output: output))
        #expect(frozen(40, 30).near(.red))
        let empty = try pixels(
            Self.renderer.privacyImage(.card, message: "Back soon", backdrop: nil, output: output))
        #expect(empty(5, 5).red < 40)
    }

    @Test func rendersIntoPixelBuffers() throws {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, attributes as CFDictionary,
            &buffer)
        let target = try #require(buffer)
        Self.renderer.render(compose(VirtualCameraComposition()), into: target)
        CVPixelBufferLockBaseAddress(target, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(target, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(target))
        let row = CVPixelBufferGetBytesPerRow(target)
        let topLeft = base.advanced(by: 30 * row + 40 * 4).assumingMemoryBound(to: UInt8.self)
        #expect(topLeft[2] > 240 && topLeft[1] < 15 && topLeft[0] < 15)
        let bottomLeft = base.advanced(by: 150 * row + 40 * 4).assumingMemoryBound(to: UInt8.self)
        #expect(bottomLeft[0] > 240 && bottomLeft[2] < 15)
    }

    @Test func assetsLoadFromDiskOnlyWhenUsed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-camera-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("logo.png")
        let cgImage = try #require(
            Self.renderer.cgImage(
                Self.gray(0.4, size: CGSize(width: 8, height: 8)), size: CGSize(width: 8, height: 8)
            ))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        var composition = VirtualCameraComposition()
        composition.overlays.logo = VirtualCameraLogo(enabled: true, imagePath: url.path)
        composition.background = VirtualCameraBackground(
            mode: .image, imagePath: directory.appendingPathComponent("missing.png").path)
        let assets = VirtualCameraAssets.load(for: composition)
        #expect(assets.logo?.extent.width == 8)
        #expect(assets.background == nil)
        composition.overlays.logo.enabled = false
        #expect(VirtualCameraAssets.load(for: composition).logo == nil)
    }
}
