import ArgumentParser
import Foundation
import Testing
@testable import Edith
@testable import EdithCLI
import EdithKit

@Suite struct VideoEditorMediaServiceTests {
    static func fixture(_ folder: URL) throws -> URL {
        let media = folder.appendingPathComponent("original.mov")
        try Data("synthetic original".utf8).write(to: media)
        var project = VideoProject.create(title: "Synthetic")
        project.addAsset(media, duration: 1, width: 64, height: 64)
        let url = folder.appendingPathComponent("project.openscreen")
        try project.save(to: url)
        return url
    }

    static func decode<T: Codable & Sendable>(_ type: T.Type, _ data: Data) throws
        -> VideoEditorService.MediaEnvelope<T>
    {
        try JSONDecoder().decode(VideoEditorService.MediaEnvelope<T>.self, from: data)
    }

    @Test func identityDuplicatesProbeAndChronologyReturnTypedEnvelopes() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await VideoEditorServiceTests.movie(in: folder)
        let copy = folder.appendingPathComponent("copy.mov")
        try FileManager.default.copyItem(at: movie, to: copy)
        let identity = try Self.decode(
            VideoEditorService.MediaIdentityResult.self,
            await VideoEditorService.mediaIdentity(movie))
        #expect(identity.version == 1 && identity.operation == "identity" && !identity.written)
        #expect(identity.result.identity == (try VideoMediaLibrary.identity(of: copy)))
        let duplicates = try Self.decode(
            [VideoMediaLibrary.DuplicateGroup].self,
            await VideoEditorService.mediaDuplicates([movie, copy]))
        #expect(duplicates.result.first?.urls.count == 2)
        let probe = try Self.decode(
            VideoMediaLibrary.InspectedMedia.self, await VideoEditorService.mediaProbe(movie))
        #expect(probe.result.metadata.video.first?.width == 64)
        let sorted = try Self.decode(
            [VideoMediaLibrary.InspectedMedia].self,
            await VideoEditorService.mediaChronology([movie, copy]))
        #expect(sorted.result.map(\.url) == [copy, movie])
        var project = VideoProject.create()
        project.addAsset(movie, duration: 1, width: 64, height: 64)
        let projectURL = folder.appendingPathComponent("real.openscreen")
        try project.save(to: projectURL)
        let indexed = try Self.decode(
            VideoMediaLibrary.Manifest.self,
            await VideoEditorService.mediaIndex(projectURL, probe: true, dryRun: true))
        #expect(indexed.result.entries.first?.metadata?.video.first?.width == 64)
    }

    @Test func indexProvenanceAndClonePreserveIdentityAndRewriteWallpaperOwner() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try Self.fixture(folder)
        var project = try VideoProject.open(url)
        project.backgroundColor = project.assets[0].url.path
        try project.save(to: url)
        let original = try Data(contentsOf: url)
        let preview = try Self.decode(
            VideoMediaLibrary.Manifest.self, await VideoEditorService.mediaIndex(url, dryRun: true))
        #expect(!preview.written && preview.result.entries.count == 2)
        #expect(try Data(contentsOf: url) == original)
        _ = try await VideoEditorService.mediaIndex(url, overwrite: true)
        let assetID = project.assets[0].id
        let declared = try Self.decode(
            VideoMediaLibrary.Manifest.self,
            await VideoEditorService.mediaProvenance(
                url, assetID: assetID, familyID: "shoot-one",
                declaration: "Declared alternate export", overwrite: true))
        #expect(declared.result.entries.first?.source.provenance?.sourceFamilyID == "shoot-one")
        let copy = folder.appendingPathComponent("clone.openscreen")
        _ = try VideoEditorService.clone(url, to: copy, title: "Second reel")
        let clone = try VideoProject.open(copy)
        let manifest = try clone.mediaManifest()
        #expect(clone.id != project.id)
        #expect(
            manifest.entries.first { $0.reference.role == .wallpaper }?.reference.assetID
                == clone.id)
        #expect(manifest.entries.first?.source == declared.result.entries.first?.source)
        #expect(try clone.mediaURL(for: manifest.entries.last!.reference) == project.assets[0].url)
        var reindexed = clone
        #expect(try reindexed.indexMedia().entries.count == 2)
    }

    @Test func mutationsRejectStaleRevisionsProtectedOutputsAndInvalidInputs() async throws {
        let folder = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try Self.fixture(folder)
        let original = try Data(contentsOf: url)
        await #expect(throws: (any Error).self) { try await VideoEditorService.mediaIndex(url) }
        #expect(try Data(contentsOf: url) == original)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaProvenance(
                url, assetID: "missing", familyID: "f", declaration: "d", overwrite: true)
        }
        await #expect(throws: (any Error).self) { try await VideoEditorService.mediaDuplicates([]) }
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaChronology(Array(repeating: url, count: 1001))
        }
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaMutation(
                url, output: nil, dryRun: false, overwrite: true, operation: "index"
            ) { project in
                let manifest = try project.indexMedia()
                var external = try VideoProject.open(url)
                external.rename("Concurrent writer")
                try external.save(to: url)
                return manifest
            }
        }
        #expect(try VideoProject.open(url).title == "Concurrent writer")
        var project = try VideoProject.open(url)
        let dependency = folder.appendingPathComponent("image.openscreen")
        try Data("synthetic dependency".utf8).write(to: dependency)
        project.addOverlay(
            type: "image", startMs: 0, endMs: 1000, x: 0, y: 0,
            content: "data:image/png;base64,AA==")
        var entries = project.annotations.map(\.raw)
        entries[0]["content"] = dependency.path
        project.root["annotations"] = entries
        try project.save(to: url)
        await #expect(throws: (any Error).self) {
            try await VideoEditorService.mediaIndex(url, output: dependency, overwrite: true)
        }
        #expect(try String(contentsOf: dependency, encoding: .utf8) == "synthetic dependency")
    }

    @Test func everyMediaRouteHasParsingHelpTreeAndMCPCatalog() throws {
        let examples: [(String, [String])] = [
            (
                "usage",
                [
                    "--project", "/first.openscreen", "--project", "/second.openscreen", "--limit",
                    "1",
                ]
            ),
            ("identity", ["/media.mov"]), ("probe", ["/media.mov"]),
            ("duplicates", ["/a.mov", "/b.mov"]), ("chronology", ["/a.mov"]),
            ("index", ["/project.openscreen", "--probe", "--dry-run"]),
            (
                "provenance",
                [
                    "/project.openscreen", "--asset", "a", "--family", "f", "--declaration",
                    "original", "--dry-run",
                ]
            ),
        ]
        for (name, arguments) in examples {
            let route = ["studio", "edit", "media", name]
            let command = try EdRoot.parseAsRoot(route + arguments + ["--json"])
            #expect(!EdRoot.helpMessage(for: type(of: command)).isEmpty)
            let node = try #require(CommandTree.node(at: route))
            #expect(node.arguments == (name == "usage" ? [] : [.localPath]))
            #expect(node.options.contains("--json"))
            let tool = try #require(
                OperationMCPCatalog.tool(named: "edith_studio_edit_media_\(name)"))
            #expect(tool.route == route)
            #expect(
                OperationMCPRunner.executionTimeout(for: tool)
                    == OperationMCPRunner.videoRenderTimeout)
            #expect(tool.effect == (["index", "provenance"].contains(name) ? .write : .read))
        }
    }

    @Test func mediaRoutesReportOneStructuredRuntimeError() async throws {
        for example in JSONContract.cases where example.label.hasPrefix("ed studio edit media ") {
            let result = await CLIProbe.run(example.arguments)
            #expect(result.code != 0)
            #expect(result.stdout.isEmpty)
            let error = try #require(
                JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any])
            #expect(error["version"] as? Int == 1)
            #expect((error["error"] as? [String: String])?["code"] != nil)
        }
    }
}
