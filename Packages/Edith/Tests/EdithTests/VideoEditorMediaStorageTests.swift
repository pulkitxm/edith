import ArgumentParser
import Foundation
import Testing
@testable import Edith
@testable import EdithCLI

@Suite struct VideoEditorMediaStorageTests {
    @Test func packageMoveOpenAndRelinkAreHeadlessAndPreserveSources() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try VideoEditorMediaServiceTests.fixture(folder)
        let bytes = try Data(contentsOf: source)
        let target = folder.appendingPathComponent("package")
        let report = try VideoEditorMediaServiceTests.decode(
            VideoMediaLibrary.PackageResult.self,
            await VideoEditorService.mediaPackage(source, to: target))
        #expect(report.written && report.result.copiedFileCount == 1)
        #expect(try Data(contentsOf: source) == bytes)
        let moved = folder.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: target, to: moved)
        let movedProject = moved.appendingPathComponent("project.openscreen")
        let before = try Data(contentsOf: movedProject)
        let preview = try VideoEditorMediaServiceTests.decode(
            VideoMediaLibrary.Manifest.self,
            await VideoEditorService.mediaOpen(moved, dryRun: true))
        #expect(!preview.written)
        #expect(try Data(contentsOf: movedProject) == before)
        _ = try await VideoEditorService.mediaOpen(moved, overwrite: true)
        let project = try VideoProject.open(movedProject)
        #expect(project.assets[0].url.path.hasPrefix(moved.path + "/originals/"))
        let copy = folder.appendingPathComponent("copy.mov")
        try FileManager.default.copyItem(at: project.assets[0].url, to: copy)
        let output = folder.appendingPathComponent("relinked.openscreen")
        let relink = try VideoEditorMediaServiceTests.decode(
            VideoMediaLibrary.RelinkResult.self,
            await VideoEditorService.mediaRelink(
                movedProject, referenceID: project.assets[0].id, to: copy, output: output))
        #expect(!relink.result.contentChanged && relink.written)
        #expect(try VideoProject.open(output).assets[0].url == copy)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaPackage(source, to: moved)
        }
        try Data("tampered".utf8).write(to: project.assets[0].url)
        let unchanged = try Data(contentsOf: movedProject)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaOpen(moved, overwrite: true)
        }
        #expect(try Data(contentsOf: movedProject) == unchanged)
    }

    @Test func relinkRejectsUnknownPolicyPartialIdentitiesAndProtectedOutputs() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try VideoEditorMediaServiceTests.fixture(folder)
        let project = try VideoProject.open(source)
        let asset = project.assets[0]
        let changed = folder.appendingPathComponent("changed.openscreen")
        try Data("different media".utf8).write(to: changed)
        let original = try Data(contentsOf: source)
        for policy in ["requireIdentity", "typo"] {
            await #expect(throws: (any Error).self) {
                try await VideoEditorService.mediaRelink(
                    source, referenceID: asset.id, to: changed, policy: policy, overwrite: true)
            }
        }
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaRelink(
                source, referenceID: asset.id, to: changed,
                policy: "allowReplacement", output: changed, overwrite: true)
        }
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaRelink(
                source, referenceID: asset.id, to: changed,
                expectedSHA256: String(repeating: "0", count: 64), overwrite: true)
        }
        #expect(try Data(contentsOf: source) == original)
        let replacement = try VideoEditorMediaServiceTests.decode(
            VideoMediaLibrary.RelinkResult.self,
            await VideoEditorService.mediaRelink(
                source, referenceID: asset.id, to: changed, policy: "allowReplacement",
                overwrite: true))
        #expect(replacement.result.contentChanged)
    }

    @Test func packageValidationFailureLeavesNoPublishedOrStagedDirectory() throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try VideoEditorMediaServiceTests.fixture(folder)
        let project = try VideoProject.open(source)
        let target = folder.appendingPathComponent("package")
        #expect(throws: (any Error).self) {
            try project.packageOriginalMedia(
                to: target,
                validatePackage: { _, _ in
                    throw VideoEditorService.Failure(
                        "invalid_value", "Synthetic validation failure")
                })
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy {
                !$0.hasPrefix(".media-stage-")
            })
    }

    @Test func storageRoutesHaveHelpTreeCatalogAndStructuredRuntimeErrors() async throws {
        let examples = [
            ("package", ["/nonexistent/project.openscreen", "--output", "/nonexistent/package"]),
            ("open", ["/nonexistent/package", "--dry-run"]),
            (
                "relink",
                [
                    "/nonexistent/project.openscreen", "--reference", "a", "--path",
                    "/nonexistent/movie.mov",
                ]
            ),
        ]
        for (name, arguments) in examples {
            let route = ["studio", "edit", "media", name]
            let command = try EdRoot.parseAsRoot(route + arguments + ["--json"])
            #expect(!EdRoot.helpMessage(for: type(of: command)).isEmpty)
            #expect(CommandTree.node(at: route)?.options.contains("--json") == true)
            let tool = try #require(
                OperationMCPCatalog.tool(named: "edith_studio_edit_media_\(name)"))
            #expect(tool.effect == .write && tool.route == route)
            let result = await CLIProbe.run(route + arguments + ["--json"])
            #expect(result.code != 0 && result.stdout.isEmpty)
            let error = try #require(
                JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any])
            #expect(error["version"] as? Int == 1 && error["error"] is [String: String])
        }
    }
}
