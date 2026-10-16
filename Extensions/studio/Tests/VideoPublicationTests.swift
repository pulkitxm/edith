import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import StudioExtension

@Suite struct VideoPublicationTests {
    struct Fixture {
        let directory: URL
        let projects: [URL]
        let input: URL
        let manifest: URL

        init() throws {
            let directory = try VideoEditorServiceTests.folder()
            self.directory = directory
            projects = ["approved", "new"].map {
                directory.appendingPathComponent("\($0).openscreen")
            }
            input = directory.appendingPathComponent("plan.json")
            manifest = directory.appendingPathComponent("publications.json")
            for (index, project) in projects.enumerated() {
                _ = try VideoEditorService.create(at: project, title: "Synthetic cut \(index)")
            }
            try JSONEncoder().encode(
                VideoPublicationPlan(
                    projects: projects.map {
                        .init(
                            path: $0.lastPathComponent,
                            title: "Upload \($0.deletingPathExtension().lastPathComponent)")
                    })
            ).write(to: input)
        }

        func order(_ ids: [String]) throws -> URL {
            let url = directory.appendingPathComponent("order.json")
            try JSONEncoder().encode(VideoPublicationOrder(projectIDs: ids)).write(to: url)
            return url
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    static func addMusic(to url: URL, in directory: URL) async throws -> [URL] {
        let video = try await VideoEditorServiceTests.movie(in: directory)
        var project = try VideoProject.open(url)
        project.addAsset(video, duration: 1, width: 64, height: 64)
        let original = directory.appendingPathComponent("music.wav")
        let processed = directory.appendingPathComponent("processed.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<48000 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.1 }
        for path in [original, processed] {
            let audio = try AVAudioFile(forWriting: path, settings: format.settings)
            try audio.write(from: buffer)
        }
        project.addAudio(original, duration: 1, at: 0)
        let track = try #require(project.audioTracks.first)
        var assets = project.assets.map(\.raw)
        let index = try #require(assets.firstIndex { $0["id"] as? String == track.assetID })
        assets[index]["edithAudioPath"] = processed.path
        project.root["assets"] = assets
        try project.save(to: url)
        return [original, processed]
    }

    @Test func independentMusicProtectsPublicationCreateAndReorderAliases() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let music = try await Self.addMusic(to: fixture.projects[0], in: fixture.directory)
        var project = try VideoProject.open(fixture.projects[0])
        let track = try #require(project.audioTracks.first)
        var assets = project.assets.map(\.raw)
        let index = try #require(assets.firstIndex { $0["id"] as? String == track.assetID })
        var dependencies: [URL] = []
        for (key, source) in zip(["originalPath", "edithAudioPath"], music) {
            let path = source.appendingPathExtension("json")
            try FileManager.default.copyItem(at: source, to: path)
            assets[index][key] = path.path
            dependencies.append(path)
            for suffix in [".cursor.json", ".session.json"] {
                let sidecar = URL(fileURLWithPath: path.path + suffix)
                try Data("{}".utf8).write(to: sidecar)
                dependencies.append(sidecar)
            }
        }
        project.root["assets"] = assets
        try project.save(to: fixture.projects[0])
        let projectBytes = try Data(contentsOf: fixture.projects[0])
        let created = try await VideoPublicationService.create(
            at: fixture.manifest, input: fixture.input)
        let manifestBytes = try Data(contentsOf: fixture.manifest)
        let order = try fixture.order(Array(created.manifest.items.map(\.projectID).reversed()))
        for (index, dependency) in dependencies.enumerated() {
            let originalBytes = try Data(contentsOf: dependency)
            var outputs = [dependency]
            for symbolic in [false, true] {
                let alias = fixture.directory.appendingPathComponent(
                    "music-\(index)-\(symbolic).json")
                if symbolic {
                    try FileManager.default.createSymbolicLink(
                        at: alias, withDestinationURL: dependency)
                } else {
                    try FileManager.default.linkItem(at: dependency, to: alias)
                }
                outputs.append(alias)
            }
            for output in outputs {
                do {
                    _ = try await VideoPublicationService.create(
                        at: output, input: fixture.input, overwrite: true)
                    Issue.record("Publication replaced independent music")
                } catch let error as VideoEditorService.Failure {
                    #expect(error.code == "invalid_publication_output")
                }
                #expect(try Data(contentsOf: output) == originalBytes)
            }
            try manifestBytes.write(to: dependency)
            for output in outputs {
                do {
                    _ = try await VideoPublicationService.reorder(
                        output, input: order, overwrite: true)
                    Issue.record("Reorder replaced an independent music dependency")
                } catch let error as VideoEditorService.Failure {
                    if try output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
                        == true
                    {
                        #expect(error.code == "invalid_value")
                        #expect(error.message == "Expected a readable regular file: \(output.path)")
                    } else {
                        #expect(error.code == "invalid_publication_output")
                    }
                }
                #expect(try Data(contentsOf: output) == manifestBytes)
                #expect(try Data(contentsOf: dependency) == manifestBytes)
            }
            try originalBytes.write(to: dependency)
        }
        #expect(try Data(contentsOf: fixture.projects[0]) == projectBytes)
        #expect(try Data(contentsOf: fixture.manifest) == manifestBytes)
    }

    @Test func independentMusicAliasesAreProtectedByRenderFrameAndContactSheet() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let music = try await Self.addMusic(to: fixture.projects[0], in: fixture.directory)
        for (index, source) in music.enumerated() {
            let before = try Data(contentsOf: source)
            for symbolic in [false, true] {
                for operation in ["render", "frame", "contact-sheet"] {
                    let suffix = operation == "render" ? "mp4" : "png"
                    let output = fixture.directory.appendingPathComponent(
                        "\(operation)-\(index)-\(symbolic).\(suffix)")
                    if symbolic {
                        try FileManager.default.createSymbolicLink(
                            at: output, withDestinationURL: source)
                    } else {
                        try FileManager.default.linkItem(at: source, to: output)
                    }
                    do {
                        switch operation {
                        case "render":
                            _ = try await VideoEditorService.render(
                                fixture.projects[0], to: output, overwrite: true)
                        case "frame":
                            _ = try await VideoEditorService.frame(
                                fixture.projects[0], at: 0, to: output, overwrite: true)
                        default:
                            _ = try await VideoEditorService.contactSheet(
                                fixture.projects[0], times: [0], to: output, overwrite: true)
                        }
                        Issue.record("Output replaced independent music")
                    } catch let error as VideoEditorService.Failure {
                        #expect(error.code == "invalid_value")
                        #expect(
                            error.message == "Output must not replace source media or sidecars.")
                    }
                    #expect(try Data(contentsOf: output) == before)
                    #expect(try Data(contentsOf: source) == before)
                }
            }
        }
    }

    @Test func movesApprovedCutSecondWithoutChangingAnyProjectBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try await VideoEditorServiceTests.movie(in: fixture.directory)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .addMedia(path: source.path, name: "approved"),
                .trim(clipID: "approved", start: 0.1, end: 0.8),
                .speed(clipID: "approved", rate: 2),
            ]),
            to: fixture.projects[0], overwrite: true)
        let hashes = try fixture.projects.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let preview = try await VideoPublicationService.create(
            at: fixture.manifest, input: fixture.input, dryRun: true)
        #expect(!preview.written)
        #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
        let created = try await VideoPublicationService.create(
            at: fixture.manifest, input: fixture.input)
        let before = try Data(contentsOf: fixture.manifest)
        let ids = created.manifest.items.map(\.projectID).reversed().map { $0 }
        let order = try fixture.order(ids)
        let dryRun = try await VideoPublicationService.reorder(
            fixture.manifest, input: order, dryRun: true, overwrite: true)
        #expect(!dryRun.written)
        #expect(try Data(contentsOf: fixture.manifest) == before)
        let reordered = try await VideoPublicationService.reorder(
            fixture.manifest, input: order, overwrite: true)
        #expect(reordered.manifest.items.map(\.projectID) == ids)
        #expect(reordered.manifest.items[1].title == "Upload approved")
        #expect(try VideoPublicationService.show(fixture.manifest).items.map(\.projectID) == ids)
        #expect(try fixture.projects.map { SHA256.hash(data: try Data(contentsOf: $0)) } == hashes)
    }

    @Test func rejectsDuplicateProjectsIDsStaleIdentityAndMissingFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for paths in [
            [fixture.projects[0], fixture.projects[0]],
            [fixture.projects[0], fixture.directory.appendingPathComponent("missing")],
        ] {
            try JSONEncoder().encode(
                VideoPublicationPlan(projects: paths.map { .init(path: $0.path) })
            ).write(to: fixture.input)
            await #expect(throws: (any Error).self) {
                try await VideoPublicationService.create(at: fixture.manifest, input: fixture.input)
            }
        }
        try FileManager.default.removeItem(at: fixture.projects[1])
        try FileManager.default.copyItem(at: fixture.projects[0], to: fixture.projects[1])
        try JSONEncoder().encode(
            VideoPublicationPlan(projects: fixture.projects.map { .init(path: $0.path) })
        ).write(to: fixture.input)
        do {
            _ = try await VideoPublicationService.create(at: fixture.manifest, input: fixture.input)
            Issue.record("Duplicate project IDs were accepted")
        } catch let error as VideoEditorService.Failure {
            #expect(error.code == "invalid_publication_duplicate")
        }
        _ = try VideoEditorService.create(
            at: fixture.projects[1], title: "Different", overwrite: true)
        let created = try await VideoPublicationService.create(
            at: fixture.manifest, input: fixture.input)
        let before = try Data(contentsOf: fixture.manifest)
        let duplicate = try fixture.order([
            created.manifest.items[0].projectID, created.manifest.items[0].projectID,
        ])
        await #expect(throws: (any Error).self) {
            try await VideoPublicationService.reorder(
                fixture.manifest, input: duplicate, overwrite: true)
        }
        _ = try VideoEditorService.create(
            at: fixture.projects[0], title: "Replacement", overwrite: true)
        do {
            _ = try VideoPublicationService.show(fixture.manifest)
            Issue.record("A stale project ID was accepted")
        } catch let error as VideoEditorService.Failure {
            #expect(error.code == "invalid_publication_identity")
        }
        #expect(try Data(contentsOf: fixture.manifest) == before)
    }

    @Test func rejectsDependencyProjectAndPlanAliases() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try await VideoEditorServiceTests.movie(in: fixture.directory)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: source.path, name: "cut")]),
            to: fixture.projects[0], overwrite: true)
        let sidecar = URL(fileURLWithPath: source.path + ".cursor.json")
        try Data("[]".utf8).write(to: sidecar)
        let session = URL(fileURLWithPath: source.path + ".session.json")
        try Data(#"{"microphone":true,"webcam":false}"#.utf8).write(to: session)
        for (index, protected) in [fixture.projects[0], source, sidecar, session, fixture.input]
            .enumerated()
        {
            let before = try Data(contentsOf: protected)
            await #expect(throws: (any Error).self) {
                try await VideoPublicationService.create(
                    at: protected, input: fixture.input, overwrite: true)
            }
            #expect(try Data(contentsOf: protected) == before)
            for symbolic in [false, true] {
                let alias = fixture.directory.appendingPathComponent(
                    "alias-\(index)-\(symbolic).json")
                if symbolic {
                    try FileManager.default.createSymbolicLink(
                        at: alias, withDestinationURL: protected)
                } else {
                    try FileManager.default.linkItem(at: protected, to: alias)
                }
                await #expect(throws: (any Error).self) {
                    try await VideoPublicationService.create(
                        at: alias, input: fixture.input, overwrite: true)
                }
                #expect(try Data(contentsOf: protected) == before)
                #expect(try Data(contentsOf: alias) == before)
            }
        }
        try FileManager.default.removeItem(at: source)
        await #expect(throws: (any Error).self) {
            try await VideoPublicationService.create(at: fixture.manifest, input: fixture.input)
        }
    }

    @Test func rejectsUnknownFieldsBoundsAndCancellationAndRequiresOverwrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let valid = try Data(contentsOf: fixture.input)
        for invalid in [
            #"{"version":true,"projects":[{"path":"approved.openscreen"}]}"#,
            #"{"version":1.5,"projects":[{"path":"approved.openscreen"}]}"#,
            #"{"version":9999999999999999999999999,"projects":[]}"#,
            #"{"version":1,"projects":[{"path":"approved.openscreen","extra":1}]}"#,
            #"{"version":1,"projects":[],"extra":1}"#,
            String(repeating: " ", count: 1024 * 1024 + 1),
        ] {
            try Data(invalid.utf8).write(to: fixture.input)
            await #expect(throws: (any Error).self) {
                try await VideoPublicationService.create(at: fixture.manifest, input: fixture.input)
            }
        }
        try valid.write(to: fixture.input)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VideoPublicationService.create(
                at: fixture.manifest, input: fixture.input)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.manifest.path))
        let created = try await VideoPublicationService.create(
            at: fixture.manifest, input: fixture.input)
        let before = try Data(contentsOf: fixture.manifest)
        let order = try fixture.order(created.manifest.items.map(\.projectID))
        await #expect(throws: (any Error).self) {
            try await VideoPublicationService.reorder(fixture.manifest, input: order)
        }
        #expect(try Data(contentsOf: fixture.manifest) == before)
    }
}
