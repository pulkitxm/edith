import EdithExtensionUI
import EdithExtensionSupport
import CoreImage
import CryptoKit
import ImageIO
import Testing
@testable import StudioExtension

@Suite struct VideoEditorReviewTests {
    @Test func cloneKeepsTheEditButCreatesIndependentProjectIdentity() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await VideoEditorServiceTests.movie(in: directory)
        let original = directory.appendingPathComponent("original.openscreen")
        let copy = directory.appendingPathComponent("copy.openscreen")
        _ = try VideoEditorService.create(at: original, title: "First cut")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: source.path, name: "intro"),
                .speed(clipID: "intro", rate: 2),
            ]), to: original, overwrite: true)
        let before = try Data(contentsOf: original)
        _ = try VideoEditorService.clone(original, to: copy, title: "Second cut")
        let first = try VideoProject.open(original)
        let second = try VideoProject.open(copy)
        #expect(first.id != second.id)
        #expect(second.title == "Second cut")
        #expect(second.clips.map(\.id) == first.clips.map(\.id))
        #expect(second.clips.first?.rate == 2)
        #expect(second.assets.first?.url == source)
        #expect(try Data(contentsOf: original) == before)
        #expect(throws: (any Error).self) {
            try VideoEditorService.clone(original, to: original, title: "Wrong", overwrite: true)
        }
        #expect(throws: (any Error).self) {
            try VideoEditorService.clone(original, to: copy, title: "Wrong")
        }
        let invalid = directory.appendingPathComponent("invalid.openscreen")
        try Data("broken project".utf8).write(to: invalid)
        let listing = try VideoEditorService.list(in: directory)
        #expect(listing.count == 3)
        #expect(
            listing.filter { $0.error != nil }.map {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath()
            } == [invalid.resolvingSymlinksInPath()])
        #expect(Set(listing.compactMap(\.id)) == [first.id, second.id])
    }

    @Test func contactSheetUsesOutputFramesAndPreservesSourceAndExistingOutputs() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await VideoEditorServiceTests.movie(in: directory)
        let project = directory.appendingPathComponent("review.openscreen")
        _ = try VideoEditorService.create(at: project, title: "Synthetic review")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: source.path, name: "intro"),
                .canvas(aspectRatio: "native", padding: 0, backgroundColor: "#000000"),
                .speed(clipID: "intro", rate: 2),
            ]), to: project, overwrite: true)
        let output = directory.appendingPathComponent("sheet.png")
        let report = try await VideoEditorService.contactSheet(
            project, times: [0.01, 0.25, 0.499999999], columns: 2, cellWidth: 64, to: output)
        #expect(report.frames.map(\.frame) == [0, 15, 29])
        #expect(report.width >= 190)
        #expect(report.height == 220)
        let data = try Data(contentsOf: output)
        #expect(
            report.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(image.width == report.width && image.height == report.height)
        let context = CIContext()
        let tileWidth = (report.width - 36) / 2
        let left = 12 + tileWidth / 2
        let right = 24 + tileWidth + tileWidth / 2
        for point in [
            CGPoint(x: left, y: 176), CGPoint(x: right, y: 176), CGPoint(x: left, y: 72),
        ] {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(
                CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
            #expect(pixel[0] > 180 && pixel[1] < 90 && pixel[2] < 60)
        }
        for times in [[], [-1], [0.5], [Double.nan], Array(repeating: 0.0, count: 65)] {
            await #expect(throws: (any Error).self) {
                try await VideoEditorService.contactSheet(
                    project, times: times, to: output, overwrite: true)
            }
            #expect(try Data(contentsOf: output) == data)
        }
        let originalImage = directory.appendingPathComponent("synthetic.png")
        var document = try VideoProject.open(project)
        var assets = document.root["assets"] as! [[String: Any]]
        assets[0]["edithSourceImagePath"] = originalImage.path
        document.root["assets"] = assets
        try document.save(to: project)
        let imageBefore = try Data(contentsOf: originalImage)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.contactSheet(
                project, times: [0], to: originalImage, overwrite: true)
        }
        #expect(try Data(contentsOf: originalImage) == imageBefore)
    }

    @Test func thumbnailsResizeCompletedCaptionFramesAndPortraitLabelsFit() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("wide.png")
        try CIContext().writePNGRepresentation(
            of: CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.6)).cropped(
                to: CGRect(x: 0, y: 0, width: 1280, height: 720)),
            to: imageURL, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let project = directory.appendingPathComponent("captioned.openscreen")
        var document = VideoProject.create(title: "Caption review")
        document.videoSettings = VideoSettings(width: 1280, height: 720)
        try document.addStillAsset(
            imageURL, duration: 1, metadata: VideoStillMedia.metadata(at: imageURL))
        try document.save(to: project)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .text(
                    content: "A caption that keeps its exact layout in smaller review frames",
                    start: 0, end: 1)
            ]), to: project, overwrite: true)
        let frameURL = directory.appendingPathComponent("frame.png")
        _ = try await VideoEditorService.frame(project, at: 0.25, to: frameURL)
        let sheetURL = directory.appendingPathComponent("sheet.png")
        _ = try await VideoEditorService.contactSheet(
            project, times: [0.25], cellWidth: 320, to: sheetURL)
        func image(_ url: URL) throws -> CGImage {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let reference = try #require(
            CGContext(
                data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        reference.interpolationQuality = .high
        reference.draw(try image(frameURL), in: CGRect(x: 0, y: 0, width: 320, height: 180))
        let expected = try #require(reference.makeImage())
        let actual = try #require(
            try image(sheetURL).cropping(to: CGRect(x: 12, y: 12, width: 320, height: 180)))
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
            CIContext().render(
                CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 1280,
                bounds: CGRect(x: 0, y: 0, width: 320, height: 180), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return bytes
        }
        let differences = zip(pixels(expected), pixels(actual)).map { abs(Int($0) - Int($1)) }
        #expect(differences.max()! <= 2)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .canvas(aspectRatio: "9:16", padding: 0, backgroundColor: "#111111")
            ]), to: project, overwrite: true)
        let portrait = try await VideoEditorService.contactSheet(
            project, times: [0, 0.5], columns: 2, cellWidth: 64,
            to: directory.appendingPathComponent("portrait.png"))
        #expect(portrait.width >= 180)
        #expect(portrait.height == 116)
    }

}
