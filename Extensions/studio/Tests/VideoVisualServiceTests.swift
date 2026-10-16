import EdithExtensionUI
import EdithExtensionSupport
import CoreImage
import ImageIO
import Testing
@testable import StudioExtension

@Suite struct VideoVisualServiceTests {
    @Test func facadeValidatesAndRendersExtendedOriginalStills() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("original.png")
        try VideoImageContext.shared.writePNGRepresentation(
            of: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32)),
            to: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(
            width: 160, height: 90, frameRateNumerator: 60000,
            frameRateDenominator: 1001, colorSpace: .displayP3)
        try project.addStillAsset(image, duration: 1, metadata: VideoStillMedia.metadata(at: image))
        let url = directory.appendingPathComponent("still.openscreen")
        try project.save(to: url)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .trim(clipID: project.clips[0].id, start: 2, end: 42),
                .canvas(aspectRatio: "9:16", padding: 0, backgroundColor: "#000000"),
            ]), to: url, overwrite: true)
        let restored = try VideoProject.open(url)
        #expect(restored.assets[0].isStill && restored.assets[0].url == image)
        #expect(restored.clips[0].duration == 40)
        #expect(restored.videoSettings.width == 90 && restored.videoSettings.height == 160)
        #expect(restored.frameDuration == project.frameDuration)
        #expect(restored.videoSettings.colorSpace == .displayP3)
        _ = try await VideoEditorService.validate(url)
        let linked = directory.appendingPathComponent("linked.png")
        try FileManager.default.linkItem(at: image, to: linked)
        #expect(throws: VideoEditorService.Failure.self) {
            try VideoEditorService.protectSources(restored, destination: linked)
        }
        #expect(throws: VideoEditorService.Failure.self) {
            try VideoEditorService.protectSources(
                restored, destination: URL(fileURLWithPath: image.path + ".session.json"))
        }
        let output = directory.appendingPathComponent("extended.png")
        _ = try await VideoEditorService.frame(url, at: 30, to: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(frame.width == 90 && frame.height == 160)
        var native = restored
        try native.setCanvasAspectRatio("native")
        #expect(native.videoSettings.width == 64 && native.videoSettings.height == 32)
        try native.addStillAsset(image, duration: 1, metadata: VideoStillMedia.metadata(at: image))
        let settings = native.videoSettings
        native.setClips(native.clips.reversed())
        #expect(native.videoSettings == settings)
        try Data("not an image".utf8).write(to: image)
        await #expect(throws: (any Error).self) { try await VideoEditorService.validate(url) }
    }

    @Test func facadeRejectsMalformedPersistedSettingsAndEffects() throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("invalid.openscreen")
        let invalidSettings: [[String: Any]] = [
            ["edithVideoSettings": ["width": 0]],
            ["edithVideoSettings": "invalid"],
        ]
        for raw in invalidSettings {
            var project = VideoProject.create()
            project.root.merge(raw) { _, new in new }
            try JSONSerialization.data(withJSONObject: project.root).write(to: url)
            #expect(throws: (any Error).self) { try VideoEditorService.show(url) }
            #expect(throws: (any Error).self) { try project.encodedForSaving() }
        }
        var project = VideoProject.create()
        project.addAsset(
            directory.appendingPathComponent("movie.mov"), duration: 1, width: 64, height: 64)
        var clips = project.clips
        clips[0].raw["edithVisualEffects"] = ["framing": "invalid"]
        project.setClips(clips)
        try JSONSerialization.data(withJSONObject: project.root).write(to: url)
        #expect(throws: (any Error).self) { try VideoEditorService.show(url) }
    }
}
