import AVFoundation
import CoreImage
import ImageIO
import Testing
@testable import Edith

@Suite struct VideoVisualPlanTests {
    @Test func nestedVisualPlansRejectUnknownMissingAndMistypedFields() throws {
        let plan = VideoEditPlan(operations: [
            .videoSettings(settings: VideoSettings()),
            .visualEffects(
                clipID: "clip", effects: VideoVisualEffects(keyframes: [.init(time: 1)])),
            .addStill(path: "still.png", name: "still", duration: 5),
            .stillDuration(clipID: "still", duration: 8),
        ])
        let encoded = try JSONEncoder().encode(plan)
        #expect(try VideoEditPlan.decode(encoded).operations.count == 4)
        let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var operations = root["operations"] as! [[String: Any]]
        for (index, field, replacement) in [
            (0, "settings", ["width": 64] as [String: Any]),
            (0, "settings", VideoSettings().raw.merging(["typo": true]) { _, new in new }),
            (1, "effects", VideoVisualEffects().raw.merging(["typo": true]) { _, new in new }),
            (
                1, "effects",
                VideoVisualEffects().raw.merging(["framing": "stretch"]) { _, new in new }
            ),
        ] {
            var mutated = root
            var entries = operations
            let name = entries[index].keys.first!
            var fields = entries[index][name] as! [String: Any]
            fields[field] = replacement
            entries[index][name] = fields
            mutated["operations"] = entries
            #expect(throws: VideoEditorService.Failure.self) {
                try VideoEditPlan.decode(JSONSerialization.data(withJSONObject: mutated))
            }
        }
        for key in ["time", "scale", "positionX", "positionY", "rotation", "interpolation", "typo"]
        {
            var effects = VideoVisualEffects(keyframes: [.init(time: 1)]).raw
            var keyframe = (effects["keyframes"] as! [[String: Any]])[0]
            keyframe[key] = key == "typo" ? true : nil
            effects["keyframes"] = [keyframe]
            operations[1] = ["visualEffects": ["clipID": "clip", "effects": effects]]
            var mutated = root
            mutated["operations"] = operations
            let data = try JSONSerialization.data(withJSONObject: mutated)
            if key == "time" || key == "typo" {
                #expect(throws: VideoEditorService.Failure.self) { try VideoEditPlan.decode(data) }
            } else {
                #expect(try VideoEditPlan.decode(data).operations.count == 4)
            }
        }
        var unknownRoot = root
        unknownRoot["unexpected"] = true
        #expect(throws: VideoEditorService.Failure.self) {
            try VideoEditPlan.decode(JSONSerialization.data(withJSONObject: unknownRoot))
        }
    }

    @Test func schemaSeparatesPixelsDurationsAndNormalizedFields() throws {
        let root = try #require(
            JSONSerialization.jsonObject(with: VideoEditPlan.schema()) as? [String: Any])
        let properties = root["properties"] as! [String: [String: Any]]
        let items = properties["operations"]!["items"] as! [String: Any]
        let variants = items["oneOf"] as! [[String: Any]]
        func fields(_ name: String) -> [String: [String: Any]] {
            let variant = variants.first { ($0["properties"] as! [String: Any])[name] != nil }!
            let operation = (variant["properties"] as! [String: [String: Any]])[name]!
            return operation["properties"] as! [String: [String: Any]]
        }
        let settings =
            fields("videoSettings")["settings"]!["properties"] as! [String: [String: Any]]
        #expect(settings["width"]?["type"] as? String == "integer")
        #expect(settings["width"]?["multipleOf"] as? Int == 2)
        #expect(settings["height"]?["maximum"] as? Int == 16384)
        #expect(fields("crop")["width"]?["maximum"] as? Double == 1)
        #expect(fields("addStill")["duration"]?["maximum"] as? Int == 604800)
        #expect(fields("transition")["duration"]?["maximum"] as? Double == 2)
        let effects = fields("visualEffects")["effects"]!
        #expect(effects["additionalProperties"] as? Bool == false)
        let effectFields = effects["properties"] as! [String: [String: Any]]
        let keyframe = effectFields["keyframes"]!["items"] as! [String: Any]
        #expect(keyframe["additionalProperties"] as? Bool == false)
        #expect(keyframe["required"] as? [String] == ["time"])
        #expect(effects["required"] as? [String] == [])
    }

    @Test func appliesNativeStillSettingsAndAnimationWithoutChangingOriginal() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("still.png")
        try VideoImageContext.shared.writePNGRepresentation(
            of: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)),
            to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let original = try Data(contentsOf: url)
        let projectURL = directory.appendingPathComponent("project.openscreen")
        _ = try VideoEditorService.create(at: projectURL, title: "Synthetic still edit")
        let initial = try Data(contentsOf: projectURL)
        let settings = VideoSettings(
            width: 64, height: 64, frameRateNumerator: 60000, frameRateDenominator: 1001)
        let effects = VideoVisualEffects(keyframes: [
            .init(time: 1, scale: 0.5), .init(time: 2, scale: 0.5, positionX: 0.5),
        ])
        let plan = VideoEditPlan(operations: [
            .addStill(path: "still.png", name: "photo", duration: 1),
            .videoSettings(settings: settings),
            .trim(clipID: "photo", start: 1, end: 3),
            .stillDuration(clipID: "photo", duration: 6),
            .speed(clipID: "photo", rate: 2),
            .visualEffects(clipID: "photo", effects: effects),
        ])
        _ = try await VideoEditorService.apply(plan, to: projectURL, dryRun: true)
        #expect(try Data(contentsOf: projectURL) == initial)
        let decoded = try VideoEditPlan.decode(JSONEncoder().encode(plan))
        let result = try await VideoEditorService.apply(decoded, to: projectURL, overwrite: true)
        let project = try VideoProject.open(projectURL)
        #expect(project.assets[0].isStill && project.assets[0].url == url)
        #expect(project.assets[0].duration == 1)
        #expect(project.clips[0].start == 1 && project.clips[0].end == 7)
        #expect(project.clips[0].visualEffects == effects)
        #expect(project.videoSettings == settings)
        #expect(result.aliases["photo"] == project.clips[0].id)
        for (time, x) in [(0.0, 32), (2.0, 60)] {
            let frameURL = directory.appendingPathComponent("frame-\(x).png")
            _ = try await VideoEditorService.frame(projectURL, at: time, to: frameURL)
            let frame = try #require(CIImage(contentsOf: frameURL))
            var pixel = [UInt8](repeating: 0, count: 4)
            VideoImageContext.shared.render(
                frame, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: x, y: 32, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            #expect(pixel[0] > 220 && pixel[2] < 30)
        }
        #expect(try Data(contentsOf: url) == original)
        let before = try Data(contentsOf: projectURL)
        let invalidOperations: [VideoEditPlan.Operation] = [
            .stillDuration(clipID: "missing", duration: 1),
            .stillDuration(clipID: project.clips[0].id, duration: 0),
            .videoSettings(settings: VideoSettings(width: 63)),
            .videoSettings(settings: VideoSettings(frameRateDenominator: 0)),
            .visualEffects(clipID: project.clips[0].id, effects: VideoVisualEffects(saturation: 5)),
            .visualEffects(
                clipID: project.clips[0].id,
                effects: VideoVisualEffects(keyframes: [.init(time: 1), .init(time: 1)])),
        ]
        for operation in invalidOperations {
            await #expect(throws: VideoEditorService.Failure.self) {
                try await VideoEditorService.apply(
                    VideoEditPlan(operations: [operation]), to: projectURL, overwrite: true)
            }
            #expect(try Data(contentsOf: projectURL) == before)
        }
    }
}
