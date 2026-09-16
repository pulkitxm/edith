import Foundation
import Testing

@testable import EdithKit

@Suite struct BifrostQueryTests {
    private static let applications = [
        BifrostApplication(name: "Safari", path: "/Applications/Safari.app"),
        BifrostApplication(name: "Google Chrome", path: "/Applications/Google Chrome.app"),
        BifrostApplication(
            name: "System Settings", path: "/System/Applications/System Settings.app"),
        BifrostApplication(name: "Notes", path: "/System/Applications/Notes.app"),
        BifrostApplication(name: "Calculator", path: "/System/Applications/Calculator.app"),
        BifrostApplication(
            name: "Activity Monitor", path: "/System/Applications/Utilities/Activity Monitor.app"),
        BifrostApplication(
            name: "Visual Studio Code", path: "/Applications/Visual Studio Code.app"),
    ]

    private func titles(_ query: String, limit: Int = 8) -> [String] {
        BifrostQuery.results(query: query, applications: Self.applications, limit: limit)
            .map(\.title)
    }

    @Test(arguments: [
        ("safari", "Safari"),
        ("saf", "Safari"),
        ("chrome", "Google Chrome"),
        ("gc", "Google Chrome"),
        ("sys", "System Settings"),
        ("vsc", "Visual Studio Code"),
        ("activity", "Activity Monitor"),
        ("am", "Activity Monitor"),
        ("note", "Notes"),
        ("calc", "Calculator"),
    ]) func rankingPutsTheObviousApplicationFirst(query: String, expected: String) {
        #expect(titles(query).first == expected, "\(query)")
    }

    @Test func refusesApplicationsThatDoNotMatch() {
        #expect(titles("zzzz").isEmpty)
    }

    @Test func aCalculationLeadsTheResults() throws {
        let results = BifrostQuery.results(query: "2+2", applications: Self.applications)
        let first = try #require(results.first)
        #expect(first.kind == .calculation)
        #expect(first.title == "4")
        #expect(first.action == .copy(text: "4"))
    }

    @Test func aConversionLeadsTheResults() throws {
        let results = BifrostQuery.results(query: "12 km in miles", applications: Self.applications)
        let first = try #require(results.first)
        #expect(first.kind == .conversion)
        #expect(first.action == .copy(text: "7.456454307"))
    }

    @Test func applicationResultsOpenTheirBundle() throws {
        let result = try #require(
            BifrostQuery.results(query: "safari", applications: Self.applications).first)
        #expect(result.kind == .application)
        #expect(result.action == .launch(path: "/Applications/Safari.app"))
        #expect(result.subtitle == "/Applications")
    }

    @Test func everyResultKnowsWhatCopyingItMeans() throws {
        let application = try #require(
            BifrostQuery.results(query: "safari", applications: Self.applications).first)
        let answer = try #require(
            BifrostQuery.results(query: "2+2", applications: Self.applications).first)

        #expect(application.action.copyText == "/Applications/Safari.app")
        #expect(answer.action.copyText == "4")
    }

    @Test func theLimitIsHonouredIncludingTheLeadingResult() {
        let results = BifrostQuery.results(
            query: "s", applications: Self.applications, limit: 3)
        #expect(results.count == 3)
        let withCalculation = BifrostQuery.results(
            query: "2+2", applications: Self.applications, limit: 1)
        #expect(withCalculation.count == 1)
        #expect(withCalculation.first?.kind == .calculation)
    }

    @Test func anEmptyQueryShowsWhatYouOpenMost() {
        var ledger = BifrostUsageLedger()
        let now = Date()
        ledger.record("app:/System/Applications/Notes.app", at: now)
        ledger.record("app:/System/Applications/Notes.app", at: now)
        ledger.record("app:/Applications/Safari.app", at: now)

        let results = BifrostQuery.results(
            query: "  ", applications: Self.applications, ledger: ledger, now: now)
        #expect(results.map(\.title) == ["Notes", "Safari"])
    }

    @Test func frequencyBreaksTiesBetweenEqualMatches() {
        var ledger = BifrostUsageLedger()
        let now = Date()
        for _ in 0..<12 { ledger.record("app:/Applications/Google Chrome.app", at: now) }

        let plain = BifrostQuery.results(query: "c", applications: Self.applications, limit: 5)
        let boosted = BifrostQuery.results(
            query: "c", applications: Self.applications, ledger: ledger, now: now, limit: 5)
        #expect(plain.first?.title == "Calculator")
        #expect(boosted.first?.title == "Google Chrome")
    }

    @Test func anOverlongQueryIsRefusedRatherThanScanned() {
        let long = String(repeating: "a", count: BifrostQuery.maximumQueryLength + 1)
        #expect(BifrostQuery.results(query: long, applications: Self.applications).isEmpty)
    }

    @Test func resultIdentifiersAreStableAndUnique() {
        let results = BifrostQuery.results(query: "s", applications: Self.applications)
        #expect(Set(results.map(\.id)).count == results.count)
        #expect(
            results.map(\.id)
                == BifrostQuery.results(query: "s", applications: Self.applications).map(\.id))
    }
}
