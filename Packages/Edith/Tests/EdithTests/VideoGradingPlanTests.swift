import CoreImage
import Testing
@testable import Edith

@Suite struct VideoGradingPlanTests {
    @Test func modesRoundTripAndInvalidTransactionsLeaveProjectUntouched() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        try VideoImageContext.shared.writePNGRepresentation(
            of: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32)),
            to: source, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var project = VideoProject.create()
        try project.addStillAsset(
            source, duration: 1, metadata: VideoStillMedia.metadata(at: source))
        let url = directory.appendingPathComponent("synthetic.openscreen")
        try project.save(to: url)
        let id = project.clips[0].id
        func plan(_ effects: [String: Any]) throws -> VideoEditPlan {
            try VideoEditPlan.decode(
                JSONSerialization.data(withJSONObject: [
                    "version": 1,
                    "operations": [["visualEffects": ["clipID": id, "effects": effects]]],
                ]))
        }
        #expect(try VideoVisualEffects.decode([:]).gradingMode == .native)
        #expect(try VideoVisualEffects.decode([:]).gradingDomain == .srgb)
        let edit = try plan([
            "gradingMode": "ffmpeg709", "gradingDomain": "bt709ToSRGB",
            "contrast": 1.02, "saturation": 1.035, "brightness": 0.002,
        ])
        let original = try Data(contentsOf: url)
        _ = try await VideoEditorService.apply(edit, to: url, dryRun: true, overwrite: true)
        #expect(try Data(contentsOf: url) == original)
        _ = try await VideoEditorService.apply(edit, to: url, overwrite: true)
        let saved = try Data(contentsOf: url)
        #expect(try VideoProject.open(url).clips[0].visualEffects.gradingMode == .ffmpeg709)
        #expect(try VideoProject.open(url).clips[0].visualEffects.gradingDomain == .bt709ToSRGB)
        for effects: [String: Any] in [
            ["gradingMode": "ffmpeg"], ["gradingMode": NSNull()], ["gradingMode": 1],
            ["gradingMode": "ffmpeg709", "saturation": 3.001],
            ["gradingMode": "ffmpeg709", "contrast": 4.001],
            ["gradingMode": "ffmpeg709", "brightness": -1.001],
            ["gradingMode": "ffmpeg709", "gradingDomain": "auto"],
            ["gradingMode": "ffmpeg709", "gradingDomain": NSNull()],
            ["gradingMode": "ffmpeg709", "gradingDomain": 709],
            ["gradingDomain": "bt709"],
            ["gradingMode": "native", "gradingDomain": "bt709ToSRGB"],
        ] {
            await #expect(throws: (any Error).self) {
                try await VideoEditorService.apply(try plan(effects), to: url, overwrite: true)
            }
            #expect(try Data(contentsOf: url) == saved)
        }
        let invalid = VideoEditPlan(operations: [
            .visualEffects(clipID: id, effects: .init(contrast: 0.5)),
            .visualEffects(clipID: id, effects: .init(saturation: 4, gradingMode: .ffmpeg709)),
        ])
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.apply(invalid, to: url, overwrite: true)
        }
        #expect(try Data(contentsOf: url) == saved)
        _ = try await VideoEditorService.apply(
            try plan(["saturation": 4]), to: url, overwrite: true)
        #expect(try VideoProject.open(url).clips[0].visualEffects.gradingMode == .native)
        #expect(try VideoProject.open(url).clips[0].visualEffects.gradingDomain == .srgb)
    }
}
