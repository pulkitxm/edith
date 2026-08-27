import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithCLI

@Suite struct CLIMediaTests {
    @Test func parserExposesBothMediaOperations() throws {
        let images = try #require(
            try EdRoot.parseAsRoot([
                "media", "convert-images", "one.png", "two.png", "--to", "out",
                "--format", "heic", "--quality", "0.7", "--max-dimension", "800",
                "--json",
            ]) as? MediaConvertImagesCommand)
        let video = try #require(
            try EdRoot.parseAsRoot([
                "media", "compress-video", "movie.mov", "--to", "out", "--target-mb",
                "12", "--no-audio", "--json",
            ]) as? MediaCompressVideoCommand)

        #expect(images.inputs == ["one.png", "two.png"])
        #expect(images.outputDirectory == "out")
        #expect(images.format == "heic")
        #expect(images.quality == 0.7)
        #expect(images.maxDimension == 800)
        #expect(images.json)
        #expect(video.input == "movie.mov")
        #expect(video.outputDirectory == "out")
        #expect(video.targetMB == 12)
        #expect(video.noAudio)
        #expect(video.json)
    }

    @Test func conversionCommandEmitsJSONAndWritesResizedImage() async throws {
        try await CLIProbe.inWorld { world in
            let input = world.sandbox.appendingPathComponent("input.png")
            let output = world.sandbox.appendingPathComponent("converted")
            try writeImage(input, width: 100, height: 50)

            let result = await CLIProbe.capture([
                "media", "convert-images", input.path, "--to", output.path,
                "--format", "jpeg", "--max-dimension", "20", "--json",
            ])
            let object = try #require(result.object)
            let rows = try #require(object["results"] as? [[String: Any]])
            let outputPath = try #require(rows.first?["output"] as? String)
            let imageSource = try #require(
                CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil))
            let properties = try #require(
                CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])

            #expect(result.code == 0)
            #expect(result.stderr.isEmpty)
            #expect(object["operation"] as? String == "media.convert-images")
            #expect(object["succeeded"] as? Int == 1)
            #expect(object["failed"] as? Int == 0)
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 20)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 10)
        }
    }

    @Test func invalidOptionsAreUsageErrors() async {
        for arguments in [
            ["media", "convert-images", "x.png", "--to", "out", "--format", "webp"],
            ["media", "convert-images", "x.png", "--to", "out", "--quality", "0.01"],
            ["media", "compress-video", "x.mov", "--to", "out", "--target-mb", "0"],
        ] {
            let result = await CLIProbe.run(arguments)
            #expect(result.code == ExitCodes.usage, "\(arguments) exited \(result.code)")
        }
    }

    @Test func missingInputIsNotFound() async {
        let result = await CLIProbe.run([
            "media", "compress-video", "/definitely/missing.mov", "--to", "/tmp",
        ])

        #expect(result.code == ExitCodes.notFound)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("no file at"))
    }

    private func writeImage(_ url: URL, width: Int, height: Int) throws {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
