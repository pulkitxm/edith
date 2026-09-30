import EdithStudio
import Foundation
import Testing

@testable import Edith
@testable import EdithCLI

@Suite(.serialized, .enabled(if: StudioEnvironment.detect().ffmpeg != nil))
struct VideoAudioMasteringTests {
    private func initialMaster(in directory: URL) async throws
        -> VideoEditorService.AudioMasteringResult
    {
        let source = try await VideoDeliveryServiceTests.project(in: directory)
        let project = try VideoEditorService.open(source)
        let track = try #require(project.audioTracks.first)
        return try await VideoEditorService.masterAudio(
            source, trackID: track.id,
            to: directory.appendingPathComponent("first"), request: .init(durationSeconds: 1))
    }

    private func damage(_ path: String, missing: Bool) throws {
        if missing {
            try FileManager.default.removeItem(atPath: path)
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data([0]))
        }
    }

    @Test(arguments: [true, false])
    func remasterRecoversMissingOrDamagedUnreferencedArtifact(_ missing: Bool) async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await initialMaster(in: directory)
        let input = URL(fileURLWithPath: first.projectPath)
        let before = try Data(contentsOf: input)
        let original = try VideoEditorService.open(
            directory.appendingPathComponent("demo.openscreen"))
        try damage(first.audioPath, missing: missing)
        let destination = directory.appendingPathComponent("recovered")
        let run = await CLIProbe.run([
            "studio", "edit", "audio", "master", input.path, "--track", first.trackID,
            "--duration", "1", "--output", destination.path, "--json",
        ])
        #expect(run.code == 0, "\(run.stderr)")
        let recovered = try JSONDecoder().decode(
            VideoEditorService.AudioMasteringResult.self,
            from: Data(run.stdout.utf8))
        let projectURL = URL(fileURLWithPath: recovered.projectPath)
        let project = try VideoEditorService.open(projectURL)
        #expect(!project.assets.contains { $0.id == first.assetID })
        #expect(Set(original.assets.map(\.id)).isSubset(of: Set(project.assets.map(\.id))))
        #expect(
            project.assets.first { $0.id == recovered.assetID }?.audioURL.path
                == recovered.audioPath)
        #expect(recovered.report.originalSHA256 == first.report.originalSHA256)
        #expect(
            try StudioAudioMastering.sha256(URL(fileURLWithPath: first.report.originalPath))
                == first.report.originalSHA256)
        #expect(try Data(contentsOf: input) == before)
        _ = try await VideoEditorService.validate(projectURL)
        let rendered = try await VideoEditorService.render(
            projectURL,
            to: directory.appendingPathComponent("recovered.mp4"))
        #expect(rendered.videoReport?.frameCount == 60)
        #expect(rendered.videoReport?.audioCodec == "aac ")
    }

    @Test(arguments: ["track", "clip", "assetID", "assetPath", "provenanceAnchor"])
    func referencedSupersededMastersRemainAndBlockInvalidPublication(_ reference: String)
        async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await initialMaster(in: directory)
        let input = directory.appendingPathComponent("referenced.openscreen")
        var project = try VideoEditorService.open(URL(fileURLWithPath: first.projectPath))
        switch reference {
        case "track":
            var duplicate = try #require(project.audioTracks.first).raw
            duplicate["id"] = "retained-track"
            duplicate["muted"] = true
            project.root["audioTracks"] = project.audioTracks.map(\.raw) + [duplicate]
        case "clip":
            var clips = project.clips
            clips[0].raw["assetId"] = first.assetID
            project.setClips(clips)
        case "assetID", "assetPath":
            let originalID = try #require(project.assets.first { $0.id != first.assetID }).id
            project.editRegion("assets", id: originalID) {
                $0["sourceReference"] = reference == "assetID" ? first.assetID : first.audioPath
            }
        default:
            project.root["sourceProvenanceAnchors"] = [
                first.assetID: ["label": "Approved soundtrack"]
            ]
        }
        try VideoEditorService.save(project, to: input, overwrite: false)
        let before = try Data(contentsOf: input)
        if reference != "clip" {
            let retained = try await VideoEditorService.masterAudio(
                input, trackID: first.trackID,
                to: directory.appendingPathComponent("shared"), request: .init(durationSeconds: 1))
            let shared = try VideoEditorService.open(URL(fileURLWithPath: retained.projectPath))
            #expect(shared.assets.contains { $0.id == first.assetID })
            _ = try await VideoEditorService.validate(URL(fileURLWithPath: retained.projectPath))
        }
        try damage(first.audioPath, missing: true)
        let destination = directory.appendingPathComponent("rejected")
        do {
            _ = try await VideoEditorService.masterAudio(
                input, trackID: first.trackID,
                to: destination, request: .init(durationSeconds: 1))
            Issue.record("A referenced missing master unexpectedly published")
        } catch let error as VideoEditorService.Failure {
            #expect(error.code == "invalid_audio_provenance")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: input) == before)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
                !$0.hasSuffix(".mastering")
            })
        #expect(
            try StudioAudioMastering.sha256(URL(fileURLWithPath: first.report.originalPath))
                == first.report.originalSHA256)
    }

    @Test func relocatedOriginalAndArtifactValidateByContentIdentity() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await initialMaster(in: directory)
        var project = try VideoEditorService.open(URL(fileURLWithPath: first.projectPath))
        let source = directory.appendingPathComponent("relocated-original.wav")
        let artifact = directory.appendingPathComponent("relocated-master.wav")
        try FileManager.default.moveItem(
            at: URL(fileURLWithPath: first.report.originalPath), to: source)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: first.audioPath), to: artifact)
        project.root["assets"] = project.assets.map {
            var raw = $0.raw
            if $0.url.path == first.report.originalPath { raw["originalPath"] = source.path }
            if $0.raw["edithAudioPath"] as? String == first.audioPath {
                raw["edithAudioPath"] = artifact.path
            }
            return raw
        }
        let relocated = directory.appendingPathComponent("relocated.openscreen")
        try VideoEditorService.save(project, to: relocated, overwrite: false)
        _ = try await VideoEditorService.validate(relocated)
        let rendered = try await VideoEditorService.render(
            relocated,
            to: directory.appendingPathComponent("relocated.mp4"))
        #expect(rendered.videoReport?.audioCodec == "aac ")
        #expect(try StudioAudioMastering.sha256(source) == first.report.originalSHA256)
        #expect(try StudioAudioMastering.sha256(artifact) == first.report.artifactSHA256)
    }

    @Test func cliRegistersVerifiedReferenceInNewProjectOnly() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await VideoDeliveryServiceTests.project(in: directory)
        let sourceBytes = try Data(contentsOf: source)
        let original = try VideoEditorService.open(source)
        let track = try #require(original.audioTracks.first)
        let bundle = directory.appendingPathComponent("mastered")
        let command = [
            "studio", "edit", "audio", "master", source.path, "--track", track.id,
            "--duration", "1", "--output", bundle.path, "--json",
        ]
        let run = await CLIProbe.run(command)
        #expect(run.code == 0, "\(run.stderr)")
        let result = try JSONDecoder().decode(
            VideoEditorService.AudioMasteringResult.self,
            from: Data(run.stdout.utf8))
        #expect(result.report.verified)
        #expect(try Data(contentsOf: source) == sourceBytes)
        let derived = try VideoEditorService.open(URL(fileURLWithPath: result.projectPath))
        #expect(derived.id != original.id)
        let asset = try #require(derived.assets.first { $0.id == result.assetID })
        #expect(asset.audioURL.path == result.audioPath)
        #expect(asset.raw["edithAudioMastering"] is [String: Any])
        #expect(derived.audioTracks.first?.offsetMs == 0)
        #expect(derived.audioTracks.first?.fadeOutMs == 0)
        _ = try await VideoEditorService.validate(URL(fileURLWithPath: result.projectPath))
        let measured = await CLIProbe.run([
            "studio", "edit", "audio", "measure", result.projectPath,
            "--asset", result.assetID, "--json",
        ])
        #expect(measured.code == 0, "\(measured.stderr)")
        let again = await CLIProbe.run(command)
        #expect(again.code != 0)
        #expect(try Data(contentsOf: source) == sourceBytes)
        let health = await CLIProbe.run(["studio", "edit", "audio", "health", "--json"])
        #expect(health.code == 0)
        for name in ["health", "measure", "master"] {
            #expect(OperationMCPCatalog.tool(named: "edith_studio_edit_audio_\(name)") != nil)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: result.audioPath)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: result.audioPath))
        try file.seekToEnd()
        try file.write(contentsOf: Data([0]))
        try file.close()
        do {
            _ = try await VideoEditorService.validate(URL(fileURLWithPath: result.projectPath))
            Issue.record("Changed derived media unexpectedly validated")
        } catch let error as VideoEditorService.Failure {
            #expect(error.code == "invalid_audio_provenance")
        }
    }
}
