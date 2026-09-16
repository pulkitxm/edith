import Foundation
import Testing

@testable import EdithKit

@Suite struct BifrostMatcherTests {
    private func score(_ name: String, _ query: String) -> Int? {
        BifrostMatcher.score(BifrostMatchTarget(name), query: BifrostMatcher.normalize(query))
    }

    @Test func anExactNameOutranksEverythingElse() throws {
        let exact = try #require(score("Notes", "notes"))
        let prefix = try #require(score("Notes Widget", "notes"))
        #expect(exact > prefix)
    }

    @Test func aPrefixOutranksALaterMatch() throws {
        let prefix = try #require(score("Safari", "saf"))
        let later = try #require(score("Live Safari Helper", "saf"))
        #expect(prefix > later)
    }

    @Test func initialsMatchAcrossWords() throws {
        #expect(score("Google Chrome", "gc") != nil)
        #expect(score("Visual Studio Code", "vsc") != nil)
        #expect(score("Activity Monitor", "am") != nil)
    }

    @Test func aMissingLetterIsNoMatch() {
        #expect(score("Safari", "safz") == nil)
        #expect(score("Notes", "notess") == nil)
    }

    @Test func anEmptyQueryMatchesNeutrally() {
        #expect(score("Safari", "") == 0)
        #expect(score("", "a") == nil)
    }

    @Test func wordStartsSurviveCaseAndSeparators() {
        let target = BifrostMatchTarget("Final-Cut Pro_11")
        #expect(String(target.characters) == "finalcutpro11")
        #expect(target.wordStarts.filter { $0 }.count == 4)
    }

    @Test func scoringIsCaseAndWhitespaceInsensitive() {
        #expect(score("Google Chrome", "GC") == score("Google Chrome", "g c"))
    }

    @Test func aShorterNameWinsAtEqualQuality() throws {
        let short = try #require(score("Mail", "ma"))
        let long = try #require(score("Mail Archive Utility", "ma"))
        #expect(short > long)
    }
}
