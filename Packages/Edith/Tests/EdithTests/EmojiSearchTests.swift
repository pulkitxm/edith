import Foundation
import Testing

@testable import EdithKit

private let corpus = [
    Emoji(character: "😀", name: "grinning face", groupIndex: 0, unicodeVersion: 1),
    Emoji(
        character: "😃", name: "grinning face with big eyes", groupIndex: 0, unicodeVersion: 1,
        terms: ["happy"]),
    Emoji(
        character: "👍", name: "thumbs up", groupIndex: 1, unicodeVersion: 0.6,
        terms: ["+1", "like", "thumbsup"], toneVariants: ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"]),
    Emoji(
        character: "🚀", name: "rocket", groupIndex: 4, unicodeVersion: 0.6,
        terms: ["launch", "space"]),
    Emoji(
        character: "🎉", name: "party popper", groupIndex: 5, unicodeVersion: 0.6,
        terms: ["celebration", "tada"]),
]

@Suite struct EmojiSearchTests {
    @Test func normalizeStripsColonsUnderscoresAndCase() {
        #expect(EmojiSearch.normalize("  :Thumbs_Up: ") == "thumbs up")
        #expect(EmojiSearch.normalize("ROCKET") == "rocket")
        #expect(EmojiSearch.normalize("   ").isEmpty)
    }

    @Test func exactNameOutranksPrefixWhichOutranksTerms() {
        #expect(EmojiSearch.score(corpus[0], query: "grinning face") == 0)
        #expect(EmojiSearch.score(corpus[1], query: "grinning") == 1)
        #expect(EmojiSearch.score(corpus[2], query: "up") == 2)
        #expect(EmojiSearch.score(corpus[4], query: "tada") == 3)
        #expect(EmojiSearch.score(corpus[3], query: "spa") == 4)
        #expect(EmojiSearch.score(corpus[1], query: "big eyes") == 5)
        #expect(EmojiSearch.score(corpus[4], query: "lebrat") == 6)
        #expect(EmojiSearch.score(corpus[3], query: "banana") == nil)
    }

    @Test func emptyQueryReturnsTheCorpusInCatalogOrder() {
        let unfiltered = EmojiSearch.results(in: corpus, query: "")
        #expect(unfiltered.map(\.character) == corpus.map(\.character))
        #expect(EmojiSearch.results(in: corpus, query: "   ").count == corpus.count)
    }

    @Test func resultsAreRankedThenStableByCatalogOrder() {
        let results = EmojiSearch.results(in: corpus, query: "grinning")
        #expect(results.map(\.character) == ["😀", "😃"])
        #expect(EmojiSearch.results(in: corpus, query: ":tada:").map(\.character) == ["🎉"])
        #expect(EmojiSearch.results(in: corpus, query: "+1").map(\.character) == ["👍"])
    }

    @Test func resultsHonourTheRequestedLimit() {
        #expect(EmojiSearch.results(in: corpus, query: "", limit: 2).count == 2)
        #expect(EmojiSearch.results(in: corpus, query: "grinning", limit: 1).count == 1)
        #expect(EmojiSearch.results(in: corpus, query: "nothing here").isEmpty)
    }

    @Test func bundledCatalogAnswersCommonSearches() {
        let catalog = EmojiCatalog.shared
        for query in ["thumbs up", "rocket", "party", "heart", "smile", "fire", "india"] {
            #expect(!EmojiSearch.results(in: catalog.emoji, query: query).isEmpty)
        }
        #expect(EmojiSearch.results(in: catalog.emoji, query: "rocket").first?.character == "🚀")
    }
}

@Suite struct EmojiOperationResolveTests {
    private let catalog = EmojiCatalog(
        groups: [EmojiGroup(id: "people-body", name: "People", symbolName: "hand.wave")],
        emoji: [
            Emoji(
                character: "👍\u{FE0F}", name: "thumbs up", groupIndex: 0, unicodeVersion: 0.6,
                terms: ["like"], toneVariants: ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"]),
            Emoji(
                character: "🚀", name: "rocket", groupIndex: 0, unicodeVersion: 0.6,
                terms: ["launch"]),
        ])

    private func scratch() -> UserDefaults {
        let name = "test.emoji.resolve.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func resolvesTheCharacterItselfAHexcodeAndAName() throws {
        let store = scratch()
        #expect(try EmojiOperationExecution.resolve("🚀", in: catalog, store: store) == "🚀")
        #expect(
            try EmojiOperationExecution.resolve("1F680", in: catalog, store: store) == "🚀")
        #expect(try EmojiOperationExecution.resolve("rocket", in: catalog, store: store) == "🚀")
        #expect(try EmojiOperationExecution.resolve("launch", in: catalog, store: store) == "🚀")
    }

    @Test func hexcodeMatchesWithOrWithoutTheVariationSelector() throws {
        let store = scratch()
        #expect(
            try EmojiOperationExecution.resolve("1F44D", in: catalog, store: store) == "👍\u{FE0F}")
        #expect(
            try EmojiOperationExecution.resolve("1F44D-FE0F", in: catalog, store: store)
                == "👍\u{FE0F}")
        #expect(try EmojiOperationExecution.resolve("👍", in: catalog, store: store) == "👍\u{FE0F}")
    }

    @Test func storedToneAppliesToBaseCharactersButNotToAnExplicitVariant() throws {
        let store = scratch()
        store.set(EmojiSkinTone.dark.rawValue, forKey: AppStorageKeys.Emoji.skinTone)
        #expect(try EmojiOperationExecution.resolve("1F44D", in: catalog, store: store) == "👍🏿")
        #expect(try EmojiOperationExecution.resolve("👍🏻", in: catalog, store: store) == "👍🏻")
        #expect(try EmojiOperationExecution.resolve("🚀", in: catalog, store: store) == "🚀")
    }

    @Test func unknownInputThrows() {
        let store = scratch()
        #expect(throws: EmojiOperationError.self) {
            try EmojiOperationExecution.resolve("aardvark", in: catalog, store: store)
        }
        #expect(throws: EmojiOperationError.self) {
            try EmojiOperationExecution.resolve("  ", in: catalog, store: store)
        }
    }

    @Test func hexcodeParsingRejectsNonsense() {
        #expect(EmojiOperationExecution.character(fromHexcode: "1F600") == "😀")
        #expect(EmojiOperationExecution.character(fromHexcode: "1F1EE-1F1F3") == "🇮🇳")
        #expect(EmojiOperationExecution.character(fromHexcode: "zzz") == nil)
        #expect(EmojiOperationExecution.character(fromHexcode: "") == nil)
        #expect(EmojiOperationExecution.character(fromHexcode: "110000") == nil)
    }

    @Test func skinToneTokensRoundTrip() {
        for tone in EmojiSkinTone.allCases {
            #expect(EmojiSkinTone(token: tone.token) == tone)
            #expect(EmojiSkinTone(token: tone.token.uppercased()) == tone)
        }
        #expect(EmojiSkinTone(token: "beige") == nil)
    }
}

@Suite struct EmojiUsageLedgerTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func recordingCountsRepeatUsesAndKeepsTheLatestTimestamp() {
        var ledger = EmojiUsageLedger()
        ledger.record("😀", at: epoch)
        ledger.record("😀", at: epoch.addingTimeInterval(60))
        ledger.record("🚀", at: epoch)
        #expect(ledger.entries.count == 2)
        let grinning = ledger.entries.first { $0.character == "😀" }
        #expect(grinning?.count == 2)
        #expect(grinning?.lastUsedAt == epoch.addingTimeInterval(60))
    }

    @Test func rankingPutsTheMostUsedFirst() {
        var ledger = EmojiUsageLedger()
        for _ in 0..<3 { ledger.record("🚀", at: epoch) }
        ledger.record("😀", at: epoch)
        #expect(ledger.ranked(now: epoch, limit: 10) == ["🚀", "😀"])
        #expect(ledger.ranked(now: epoch, limit: 1) == ["🚀"])
        #expect(ledger.ranked(now: epoch, limit: 0).isEmpty)
    }

    @Test func recencyDecayLetsAFreshEmojiOvertakeAStaleFavourite() {
        var ledger = EmojiUsageLedger()
        let longAgo = epoch.addingTimeInterval(-200 * 86_400)
        for _ in 0..<8 { ledger.record("🚀", at: longAgo) }
        for _ in 0..<2 { ledger.record("😀", at: epoch) }
        #expect(ledger.ranked(now: epoch, limit: 2) == ["😀", "🚀"])
    }

    @Test func scoreHalvesAfterOneHalfLife() {
        let usage = EmojiUsage(
            character: "😀", count: 4,
            lastUsedAt: epoch.addingTimeInterval(-EmojiUsageLedger.halfLifeDays * 86_400))
        #expect(abs(EmojiUsageLedger.score(usage, now: epoch) - 2) < 0.0001)
    }

    @Test func ledgerEvictsTheWeakestEntriesBeyondCapacity() {
        var ledger = EmojiUsageLedger()
        let rare = 10
        for index in 0..<(EmojiUsageLedger.capacity + rare) {
            let character = "e\(index)"
            for _ in 0..<(index < rare ? 1 : 5) { ledger.record(character, at: epoch) }
        }
        #expect(ledger.entries.count == EmojiUsageLedger.capacity)
        #expect(!ledger.entries.contains { $0.count == 1 })
        #expect(ledger.entries.contains { $0.character == "e50" })
    }

    @Test func evictionNeverDropsTheEmojiJustRecorded() {
        var ledger = EmojiUsageLedger()
        for index in 0..<EmojiUsageLedger.capacity {
            for _ in 0..<9 { ledger.record("e\(index)", at: epoch) }
        }
        ledger.record("🆕", at: epoch)
        #expect(ledger.entries.count == EmojiUsageLedger.capacity)
        #expect(ledger.entries.contains { $0.character == "🆕" })
    }

    @Test func forgetAndClearRemoveEntries() {
        var ledger = EmojiUsageLedger()
        ledger.record("😀", at: epoch)
        ledger.record("🚀", at: epoch)
        ledger.forget("😀")
        #expect(ledger.ranked(now: epoch, limit: 10) == ["🚀"])
        ledger.clear()
        #expect(ledger.entries.isEmpty)
    }

    @Test func ledgerRoundTripsThroughDefaults() {
        let key = "emojiUsageLedgerRoundTrip"
        let store = SharedDefaults.store
        defer { store.removeObject(forKey: key) }
        var ledger = EmojiUsageLedger()
        ledger.record("🎉", at: epoch)
        ledger.record("🎉", at: epoch)
        ledger.save(to: store, key: key)
        let loaded = EmojiUsageLedger.load(from: store, key: key)
        #expect(loaded.entries.count == 1)
        #expect(loaded.entries.first?.count == 2)
        store.removeObject(forKey: key)
        #expect(EmojiUsageLedger.load(from: store, key: key).entries.isEmpty)
    }
}
