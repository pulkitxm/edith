import Foundation
import Testing
@testable import Edith
@testable import EdithCLI

@Suite struct VideoEditorServiceSafetyTests {
    @Test func simultaneousCLIPlansBothCommitTheirChanges() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await VideoEditorServiceTests.movie(in: directory)
        let project = directory.appendingPathComponent("demo.openscreen")
        _ = try VideoEditorService.create(at: project, title: "Concurrent edits")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: source.path, name: "intro")]), to: project,
            overwrite: true)
        let first = directory.appendingPathComponent("first.json")
        let second = directory.appendingPathComponent("second.json")
        try JSONEncoder().encode(
            VideoEditPlan(operations: [.text(content: "First", start: 0, end: 0.4)])
        ).write(to: first)
        try JSONEncoder().encode(
            VideoEditPlan(operations: [.text(content: "Second", start: 0.5, end: 0.9)])
        ).write(to: second)
        let tool = try #require(OperationMCPCatalog.tool(named: "edith_studio_edit_apply"))
        async let firstResult = OperationMCPRunner.run(
            tool, arguments: [project.path, "--plan", first.path, "--overwrite"], confirm: false,
            executable: CLIProcessProbe.binary)
        async let secondResult = OperationMCPRunner.run(
            tool, arguments: [project.path, "--plan", second.path, "--overwrite"], confirm: false,
            executable: CLIProcessProbe.binary)
        let results = await [firstResult, secondResult]
        #expect(results.allSatisfy { !$0.failed }, "\(results)")
        #expect(Set(try VideoProject.open(project).annotations.map(\.text)) == ["First", "Second"])
    }

    @Test func frameCannotReplaceWallpaperOrEitherImageAnnotationPath() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await VideoEditorServiceTests.movie(in: directory)
        let image = directory.appendingPathComponent("synthetic.png")
        let original = try Data(contentsOf: image)
        let url = directory.appendingPathComponent("demo.openscreen")
        for dependency in ["wallpaper", "imageContent", "content"] {
            var project = VideoProject.create()
            project.addAsset(movie, duration: 1, width: 64, height: 64)
            if dependency == "wallpaper" {
                project.backgroundColor = image.path
            } else {
                project.root["annotations"] = [
                    [
                        "id": "image", "type": "image", "startMs": 0, "endMs": 1000,
                        dependency: image.path,
                    ]
                ]
            }
            try project.save(to: url)
            do {
                _ = try await VideoEditorService.frame(url, at: 0.1, to: image, overwrite: true)
                Issue.record("Render input was overwritten: \(dependency)")
            } catch let error as VideoEditorService.Failure {
                #expect(error.code == "invalid_value")
                #expect(error.message.contains("source media"))
            }
            #expect(try Data(contentsOf: image) == original)
        }
        var project = VideoProject.create()
        project.backgroundColor = "#123456"
        project.root["annotations"] = [
            [
                "type": "image",
                "imageContent": "data:image/png;base64," + original.base64EncodedString(),
                "content": image.path,
            ]
        ]
        try VideoEditorService.protectSources(project, destination: image)
    }

    @Test func nativeSaveParticipatesInPublicationLockAndInvalidatesStaleEdits() throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Original")
        let snapshot = try VideoEditorService.readProject(url)
        var edited = snapshot.project
        edited.rename("CLI edit")
        var external = snapshot.project
        external.rename("UI edit")
        try external.save(to: url)
        let uiBytes = try Data(contentsOf: url)
        do {
            try VideoEditorService.saveEncoded(
                VideoEditorService.encodedProject(edited), to: url, overwrite: true,
                expectedSource: snapshot.revision)
            Issue.record("A stale CLI edit replaced the UI save")
        } catch let error as VideoEditorService.Failure {
            #expect(error.code == "project_changed")
        }
        #expect(try Data(contentsOf: url) == uiBytes)
        try VideoProjectFileAccess.publication(url) {
            #expect(throws: (any Error).self) { try external.save(to: url) }
        }
        try external.save(to: url)
    }

    @Test func oversizedSerializedPlansFailWithoutChangingTheirInput() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await VideoEditorServiceTests.movie(in: directory)
        let url = directory.appendingPathComponent("large.openscreen")
        let limit = 32 * 1024 * 1024
        for prettyExpansion in [false, true] {
            var project = VideoProject.create()
            project.addAsset(movie, duration: 1, width: 64, height: 64)
            project.root["formatting"] = prettyExpansion ? Array(repeating: "x", count: 3000) : []
            project.root["paddingData"] = ""
            let base = try JSONSerialization.data(withJSONObject: project.root).count
            project.root["paddingData"] = String(repeating: "x", count: limit - base - 1024)
            let original = try JSONSerialization.data(withJSONObject: project.root)
            #expect(original.count == limit - 1024)
            try original.write(to: url, options: .atomic)
            let operations: [VideoEditPlan.Operation] =
                prettyExpansion
                ? []
                : [
                    .text(content: String(repeating: "x", count: 10000), start: 0, end: 0.5)
                ]
            for dryRun in [true, false] {
                do {
                    _ = try await VideoEditorService.apply(
                        VideoEditPlan(operations: operations), to: url, dryRun: dryRun,
                        overwrite: true)
                    Issue.record("An oversized serialized project was accepted")
                } catch let error as VideoEditorService.Failure {
                    #expect(error.code == "project_too_large")
                }
                #expect(try Data(contentsOf: url) == original)
            }
        }
    }

    @Test func staleNativeEditsCannotReplaceALaterCLICommit() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await VideoEditorServiceTests.movie(in: directory)
        let url = directory.appendingPathComponent("demo.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Original")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: movie.path, name: "clip")]), to: url,
            overwrite: true)
        var native = try VideoProject.open(url)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.rename(title: "CLI title")]), to: url, overwrite: true)
        native.crop(
            clipID: try #require(native.clips.first?.id), x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        do {
            try native.save(to: url)
            Issue.record("The stale native save replaced the CLI commit")
        } catch let error as VideoEditorService.Failure {
            #expect(error.code == "project_changed")
        }
        let saved = try VideoProject.open(url)
        #expect(saved.title == "CLI title")
        #expect(saved.clips.first?.crop == nil)
        var active = saved
        var undo = active
        active.rename("Native title")
        try active.save(to: url)
        try undo.save(to: url)
        #expect(try VideoProject.open(url).title == "CLI title")
    }

    @Test func readOnlySourceSupportsASeparateWritableOutput() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputDirectory = directory.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(
            at: inputDirectory, withIntermediateDirectories: true)
        let input = inputDirectory.appendingPathComponent("original.openscreen")
        let output = directory.appendingPathComponent("edited.openscreen")
        _ = try VideoEditorService.create(at: input, title: "Original")
        let original = try Data(contentsOf: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: input.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: inputDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: inputDirectory.path)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: input.path)
        }
        let result = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.rename(title: "Edited copy")]), to: input, output: output)
        #expect(result.written)
        #expect(try Data(contentsOf: input) == original)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: inputDirectory.path) == [
                "original.openscreen"
            ])
        #expect(try VideoProject.open(output).title == "Edited copy")
    }
}
