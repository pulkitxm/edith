import Foundation
import Testing

@testable import EdithKit

@Suite struct CommandBarEngineTests {
    private let locale = Locale(identifier: "en_US")

    @Test func ranksExactPrefixAndSubsequenceMatches() {
        let candidates = [
            CommandBarCandidate(
                id: "extensions", title: "Open Extensions", subtitle: "Manage Edith features"),
            CommandBarCandidate(
                id: "music", title: "Open Music", subtitle: "Play the local library"),
            CommandBarCandidate(
                id: "settings", title: "Open Settings", subtitle: "Configure Edith"),
        ]
        let usage = CommandBarUsage()
        #expect(
            CommandBarSearch.rank(candidates, query: "open ex", usage: usage).first?.id
                == "extensions")
        #expect(CommandBarSearch.rank(candidates, query: "omus", usage: usage).first?.id == "music")
        #expect(
            CommandBarSearch.rank(candidates, query: "library", usage: usage).first?.id == "music")
    }

    @Test func learnedRankingStoresOnlyResultIdentifiers() throws {
        var usage = CommandBarUsage()
        usage.record("app.com.example.Editor", at: Date(timeIntervalSince1970: 100))
        usage.record("app.com.example.Editor", at: Date(timeIntervalSince1970: 200))
        let data = try JSONEncoder().encode(usage)
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(encoded.contains("app.com.example.Editor"))
        #expect(!encoded.contains("private search words"))
        #expect(try JSONDecoder().decode(CommandBarUsage.self, from: data) == usage)
    }

    @Test func learnedRankingBreaksEquivalentMatches() {
        let candidates = [
            CommandBarCandidate(id: "a", title: "Editor Alpha", subtitle: ""),
            CommandBarCandidate(id: "b", title: "Editor Beta", subtitle: ""),
        ]
        var usage = CommandBarUsage()
        usage.record("b", at: Date(timeIntervalSince1970: 1_000))
        #expect(
            CommandBarSearch.rank(
                candidates, query: "editor", usage: usage,
                now: Date(timeIntervalSince1970: 1_000)
            ).first?.id == "b")
    }

    @Test func providerAndPinBiasBreakEquivalentMatches() {
        let candidates = [
            CommandBarCandidate(id: "file", title: "Editor", subtitle: "File", bias: -40),
            CommandBarCandidate(id: "action", title: "Editor", subtitle: "Action", bias: 60),
        ]
        #expect(
            CommandBarSearch.rank(
                candidates, query: "editor", usage: CommandBarUsage()
            ).first?.id == "action")
    }

    @Test func usageHistoryIsBounded() {
        var usage = CommandBarUsage()
        for index in 0..<140 {
            usage.record("item.\(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(usage.records.count == 128)
        #expect(usage.records.first?.id == "item.139")
        #expect(!usage.records.contains(where: { $0.id == "item.0" }))
    }

    @Test func evaluatesArithmeticWithPrecedenceAndPowers() {
        let result = CommandBarEvaluator.calculation("2 + 3 * 4", locale: locale)
        #expect(result?.value == 14)
        #expect(CommandBarEvaluator.calculation("2^3^2", locale: locale)?.value == 512)
        #expect(CommandBarEvaluator.calculation("(2 + 3) * 4", locale: locale)?.value == 20)
    }

    @Test func evaluatesRelativePercentages() {
        #expect(CommandBarEvaluator.calculation("480 + 15%", locale: locale)?.value == 552)
        #expect(CommandBarEvaluator.calculation("50 * 20%", locale: locale)?.value == 10)
    }

    @Test func rejectsDatesPlainNumbersAndInvalidExpressions() {
        #expect(CommandBarEvaluator.calculation("2026-08-27", locale: locale) == nil)
        #expect(CommandBarEvaluator.calculation("10:30", locale: locale) == nil)
        #expect(CommandBarEvaluator.calculation("42", locale: locale) == nil)
        #expect(CommandBarEvaluator.calculation("1 / 0", locale: locale) == nil)
        #expect(CommandBarEvaluator.calculation("volume 20", locale: locale) == nil)
    }

    @Test func convertsCommonUnitsAndAttachedUnits() {
        let miles = CommandBarEvaluator.conversion("5 km to mi", locale: locale)
        #expect(abs((miles?.value ?? 0) - 3.106_855_961) < 0.000_001)
        #expect(miles?.formatted.hasSuffix(" mi") == true)
        let temperature = CommandBarEvaluator.conversion("32f in c", locale: locale)
        #expect(abs(temperature?.value ?? 1) < 0.000_001)
        let storage = CommandBarEvaluator.conversion("1 GiB to MB", locale: locale)
        #expect(abs((storage?.value ?? 0) - 1_073.741_824) < 0.000_001)
    }

    @Test func rejectsConversionsAcrossDimensions() {
        #expect(CommandBarEvaluator.conversion("5 km to kg", locale: locale) == nil)
        #expect(CommandBarEvaluator.conversion("5 unknown to m", locale: locale) == nil)
    }

    @Test func fileSearchEscapesMetadataSyntaxAndFiltersPrivatePaths() {
        #expect(
            CommandBarFileSearchSupport.expression(for: "annual *report")
                == "kMDItemFSName == \"*annual*\"cd && kMDItemFSName == \"*\\*report*\"cd")
        #expect(CommandBarFileSearchSupport.expression(for: "a") == nil)
        #expect(
            CommandBarFileSearchSupport.offerable(
                paths: [
                    "/Users/me/Documents/report.pdf", "/Users/me/.private/secret.txt",
                    "/Users/me/project/node_modules/file.js", "/Users/me/Documents/report.pdf",
                ],
                isPackage: { $0.hasSuffix(".app") }
            ) == ["/Users/me/Documents/report.pdf"])
    }

    @Test func resultPreferencesAreStableAndBounded() throws {
        var pins: [String] = []
        for index in 0..<40 {
            pins = CommandBarPreferences.togglingPin("item.\(index)", in: pins)
        }
        #expect(pins.count == CommandBarPreferences.maximumPins)
        #expect(pins.first == "item.10")

        let shortcut = CommandBarResultShortcut(keyCode: 18, modifiers: 6_144, label: "⌃⌥1")
        let assigned = CommandBarPreferences.assigning(shortcut, to: "item.1", in: [:])
        let encoded = try #require(CommandBarPreferences.encodeShortcuts(assigned))
        #expect(CommandBarPreferences.decodeShortcuts(encoded) == assigned)
        #expect(!encoded.contains("private query"))
    }

    @Test func textUtilitiesTransformLocally() {
        #expect(CommandBarTextUtility.uppercase.transform("Hello") == "HELLO")
        #expect(CommandBarTextUtility.lowercase.transform("Hello") == "hello")
        #expect(CommandBarTextUtility.trimWhitespace.transform("  one  \n two ") == "one\ntwo")
        #expect(CommandBarTextUtility.sortLines.transform("z\na") == "a\nz")
        #expect(CommandBarTextUtility.countWords.transform("one two\nthree") == "3")
    }

    @Test func emojiCatalogHasStableUniqueCharacters() {
        #expect(!CommandBarEmoji.common.isEmpty)
        #expect(Set(CommandBarEmoji.common.map(\.character)).count == CommandBarEmoji.common.count)
        #expect(CommandBarEmoji.common.allSatisfy { !$0.keywords.isEmpty })
    }
}
