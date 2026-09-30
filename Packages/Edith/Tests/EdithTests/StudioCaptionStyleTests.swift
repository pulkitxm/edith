import ArgumentParser
import Foundation
import MCP
import Testing
@testable import Edith
@testable import EdithCLI
@testable import EdithKit

@Suite(.serialized) struct StudioCaptionStyleTests {
    @Test func CLIAndMCPDiscoverAndSaveTheSameStyle() async throws {
        let (directory, url, _) = try await VideoOutputCaptionTests.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("style.json")
        var requested = VideoCaptionStyleTests.styled
        requested.metrics = .fontBounds
        try JSONEncoder().encode(requested).write(to: file)
        let parsed = try #require(
            EdRoot.parseAsRoot([
                "studio", "edit", "captions", "add", url.path, "--text", "SYNTHETIC",
                "--start-frame", "12", "--end-frame", "24", "--style", file.path,
            ]) as? StudioCaptionAdd)
        #expect(parsed.style == file.path)
        for action in ["add", "update"] {
            let node = try #require(CommandTree.node(at: ["studio", "edit", "captions", action]))
            #expect(node.optionValues["--style"] == .localPath)
        }
        let schema = try await call("schema", [])
        #expect(
            NSDictionary(dictionary: schema).isEqual(
                to: try JSONSerialization.jsonObject(with: VideoEditPlan.schema()) as! [String: Any]
            ))
        let created = try await call(
            "captions_add",
            [
                url.path, "--text", "SYNTHETIC\nCAPTION",
                "--start-frame", "12", "--end-frame", "24", "--style", file.path,
            ])
        let id = try #require(created["captionID"] as? String)
        #expect(try VideoEditorService.listCaptions(url).captions[0].style == requested)
        let before = try Data(contentsOf: url)
        var changed = VideoCaptionStyleTests.styled
        changed.fontSize = 112
        try JSONEncoder().encode(changed).write(to: file)
        let preview = try await call(
            "captions_update", [url.path, id, "--style", file.path, "--dry-run"])
        #expect(preview["written"] as? Bool == false)
        #expect(try Data(contentsOf: url) == before)
        _ = try await call("captions_update", [url.path, id, "--style", file.path])
        let saved = try VideoEditorService.listCaptions(url).captions[0]
        #expect(saved.style == changed)
        #expect(saved.anchor?.start.frame == 12 && saved.anchor?.end.frame == 24)
        let valid = try Data(contentsOf: url)
        changed.fontFamily = "Missing Synthetic Font 4921"
        try JSONEncoder().encode(changed).write(to: file)
        let error = try await call(
            "captions_update", [url.path, id, "--style", file.path], expectingError: true)
        #expect((error["error"] as? [String: Any])?["code"] as? String == "font_not_found")
        #expect(try Data(contentsOf: url) == valid)
    }

    @Test func onePlanCreatesAndRestyles47CaptionsAtomically() async throws {
        let (directory, url, _) = try await VideoOutputCaptionTests.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plan.json")
        let rate = try VideoCaptionFrameRate(numerator: 60)
        let operations: [VideoEditPlan.Operation] = try (0..<47).map { index in
            .outputCaption(
                content: "SYNTHETIC \(index + 1)",
                anchor: try VideoCaptionAnchor(
                    start: .init(frame: Int64(index), frameRate: rate),
                    end: .init(frame: Int64(index + 1), frameRate: rate)),
                style: VideoCaptionStyleTests.styled)
        }
        try JSONEncoder().encode(VideoEditPlan(operations: operations)).write(to: file)
        let before = try Data(contentsOf: url)
        _ = try await call("apply", [url.path, "--plan", file.path, "--dry-run"])
        #expect(try Data(contentsOf: url) == before)
        _ = try await call("apply", [url.path, "--plan", file.path, "--overwrite"])
        let saved = try VideoEditorService.listCaptions(url).captions
        #expect(saved.count == 47)
        #expect(
            saved.enumerated().allSatisfy { $0.element.anchor?.start.frame == Int64($0.offset) })
        var changed = VideoCaptionStyleTests.styled
        changed.fontSize = 112
        let updates = saved.map { VideoEditPlan.Operation.captionStyle(id: $0.id, style: changed) }
        try JSONEncoder().encode(VideoEditPlan(operations: updates)).write(to: file)
        _ = try await call("apply", [url.path, "--plan", file.path, "--overwrite"])
        let restyled = try VideoEditorService.listCaptions(url).captions
        #expect(restyled.allSatisfy { $0.style == changed })
        #expect(restyled.map(\.anchor) == saved.map(\.anchor))
        let valid = try Data(contentsOf: url)
        let invalid = updates + [.captionStyle(id: "missing", style: changed)]
        try JSONEncoder().encode(VideoEditPlan(operations: invalid)).write(to: file)
        _ = try await call(
            "apply", [url.path, "--plan", file.path, "--overwrite"], expectingError: true)
        #expect(try Data(contentsOf: url) == valid)
        let anchor = try VideoCaptionAnchor(
            start: .init(frame: 60, frameRate: rate), end: .init(frame: 72, frameRate: rate))
        let replace: VideoEditPlan.Operation = .outputCaption(
            id: saved[0].id, content: "REPLACED", anchor: anchor)
        _ = try await VideoEditorService.apply(
            .init(operations: [replace]), to: url, overwrite: true)
        let replaced = try VideoEditorService.listCaptions(url).captions[0]
        #expect(
            replaced.anchor == anchor && replaced.style == changed && replaced.content == "REPLACED"
        )
    }

    @Test func textStyleAndOutputAnchorsHaveStrictNestedSchemas() throws {
        let rate = try VideoCaptionFrameRate(numerator: 60)
        let anchor = try VideoCaptionAnchor(
            start: .init(frame: 12, frameRate: rate), end: .init(frame: 24, frameRate: rate))
        for operation in [
            VideoEditPlan.Operation.text(
                content: "SYNTHETIC", start: 0, end: 1, style: VideoCaptionStyleTests.styled),
            .outputCaption(
                content: "SYNTHETIC", anchor: anchor, style: VideoCaptionStyleTests.styled),
        ] {
            let encoded = try JSONEncoder().encode(VideoEditPlan(operations: [operation]))
            _ = try VideoEditPlan.decode(encoded)
            var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var operations = root["operations"] as! [[String: Any]]
            let key = operations[0].keys.first!
            var payload = operations[0][key] as! [String: Any]
            var style = payload["style"] as! [String: Any]
            var gradient = style["gradient"] as! [String: Any]
            var stops = gradient["stops"] as! [[String: Any]]
            stops[0]["typo"] = true
            gradient["stops"] = stops
            style["gradient"] = gradient
            payload["style"] = style
            operations[0][key] = payload
            root["operations"] = operations
            #expect(throws: (any Error).self) {
                try VideoEditPlan.decode(JSONSerialization.data(withJSONObject: root))
            }
        }
    }

    private func call(_ operation: String, _ arguments: [String], expectingError: Bool = false)
        async throws -> [String: Any]
    {
        let result = await OperationMCPServer.call(
            CallTool.Parameters(
                name: "edith_studio_edit_\(operation)",
                arguments: ["arguments": .array(arguments.map { .string($0) })]),
            executable: CLIProcessProbe.binary)
        guard case let .text(text, _, _) = try #require(result.content.first) else {
            throw VideoEditorService.Failure("invalid_result", "Expected JSON result.")
        }
        #expect((result.isError == true) == expectingError, "\(text)")
        return try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
