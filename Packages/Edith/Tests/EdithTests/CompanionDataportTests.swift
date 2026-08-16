import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CompanionDataportTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func theExportManifestDecodesWhatTheServerSends() throws {
        let manifest = try decode(
            CompanionExportManifest.self,
            #"{"format":"edith-companion-export","version":1,"counts":{"episodes":2,"media":1},"media":[{"episodeId":"a","uri":"objects/ab/abc/x.wav","sha256":"abc","bytes":9}],"episodes":[]}"#
        )
        #expect(manifest.format == "edith-companion-export")
        #expect(manifest.counts["episodes"] == 2)
        #expect(manifest.media.first?.uri == "objects/ab/abc/x.wav")
    }

    @Test func theImportOutcomeDecodesWhatTheServerSends() throws {
        let outcome = try decode(
            CompanionImportBundleOutcome.self,
            #"{"episodesInserted":2,"episodesSkipped":0,"observationsInserted":2,"conversationsInserted":0,"messagesInserted":0,"beliefsInserted":0,"claimsInserted":0,"claimsSkipped":0,"factsInserted":0,"coreSectionsInserted":0,"settingsInserted":0,"vaultFilesWritten":2,"pendingEpisodes":2}"#
        )
        #expect(outcome.episodesInserted == 2)
        #expect(outcome.pendingEpisodes == 2)
    }

    @Test func theWipeOutcomeDecodesWhatTheServerSends() throws {
        let outcome = try decode(
            CompanionWipeOutcome.self,
            #"{"episodesDropped":1,"sourcesDropped":1,"observationsDropped":2,"conversationsDropped":0,"beliefsDropped":0,"vaultCleared":true}"#
        )
        #expect(outcome.episodesDropped == 1)
        #expect(outcome.vaultCleared)
    }

    @Test func eraseRefusesWithoutYes() async {
        let result = await CLIProbe.run(["companion", "erase", "some-id"])
        #expect(result.code == ExitCodes.usage)
        #expect(result.stderr.contains("cannot be undone"))
        #expect(result.stdout.isEmpty)
    }

    @Test func wipeRefusesWithoutYes() async {
        let result = await CLIProbe.run(["companion", "wipe"])
        #expect(result.code == ExitCodes.usage)
        #expect(result.stderr.contains("export"))
        #expect(result.stdout.isEmpty)
    }

    @Test func importOfNothingIsNotFound() async {
        let result = await CLIProbe.run(
            ["companion", "import", "/nonexistent/path/for/sure"])
        #expect(result.code == ExitCodes.notFound)
    }

    @Test func importOfADirectoryWithoutABundleSaysSo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-import-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await CLIProbe.run(["companion", "import", directory.path])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("bundle.json"))
    }

    @Test func exportAgainstNoBackendIsUnavailableAndWritesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-export-none-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await CLIProbe.run(["companion", "export", directory.path])
        #expect(result.code == ExitCodes.unavailable)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
