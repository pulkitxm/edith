import Foundation
import EdithExtensionSupport
import Testing

@testable import CompanionExtension

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

}
