import EdithStudio
import Foundation
import Testing

@testable import Edith
@testable import EdithCLI

@Suite(.serialized, .enabled(if: StudioEnvironment.detect().ffmpeg != nil))
struct VideoAudioMasteringTests {
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
    }
}
