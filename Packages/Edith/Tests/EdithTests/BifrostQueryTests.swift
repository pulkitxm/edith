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

    private static let commands = [
        BifrostCommand(
            id: "emoji.pick", title: "Emoji Picker", subtitle: "Type an emoji",
            symbolName: "face.smiling", abilityID: "emoji",
            notification: Notification.Name("fixture.emoji"), terms: ["emoji"]),
        BifrostCommand(
            id: "clipboard.open", title: "Clipboard History", subtitle: "Paste something",
            symbolName: "doc.on.clipboard", abilityID: "clipboard",
            notification: Notification.Name("fixture.clipboard"), terms: ["paste"]),
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

    @Test func commandsRankAlongsideApplications() {
        let results = BifrostQuery.results(
            query: "emoji", applications: Self.applications, commands: Self.commands)

        #expect(results.first?.title == "Emoji Picker")
        #expect(results.first?.kind == .command)
        #expect(results.first?.action == .run(commandID: "emoji.pick"))
    }

    @Test func aCommandIsFoundByWhatItDoesNotOnlyItsName() {
        let results = BifrostQuery.results(
            query: "paste", applications: Self.applications, commands: Self.commands)

        #expect(results.first?.title == "Clipboard History")
    }

    @Test func picKingOneResultTeachesTheQuery() {
        var ledger = BifrostUsageLedger()
        let now = Date()
        let plain = BifrostQuery.results(
            query: "c", applications: Self.applications, commands: Self.commands, limit: 5)
        ledger.record("app:/Applications/Google Chrome.app", query: "c", at: now)

        let taught = BifrostQuery.results(
            query: "c", applications: Self.applications, commands: Self.commands,
            ledger: ledger, now: now, limit: 5)

        #expect(plain.first?.title == "Calculator")
        #expect(taught.first?.title == "Google Chrome")
    }

    @Test func whatWasTaughtForALongerQueryStillHelpsAShorterOne() {
        var ledger = BifrostUsageLedger()
        let now = Date()
        ledger.record("app:/System/Applications/Notes.app", query: "note", at: now)

        let results = BifrostQuery.results(
            query: "n", applications: Self.applications, ledger: ledger, now: now, limit: 5)

        #expect(results.first?.title == "Notes")
    }

    @Test func aLessonForOneQueryDoesNotLeakIntoAnother() {
        var ledger = BifrostUsageLedger()
        let now = Date()
        ledger.record("app:/System/Applications/Notes.app", query: "note", at: now)

        #expect(
            ledger.queryBoost(for: "app:/System/Applications/Notes.app", query: "s", now: now) == 0)
        #expect(
            ledger.queryBoost(for: "app:/Applications/Safari.app", query: "note", now: now) == 0)
    }

    @Test func initialsFindAnApplication() {
        #expect(titles("gc").first == "Google Chrome")
        #expect(titles("vsc").first == "Visual Studio Code")
    }

    @Test func resultsNeverInterleaveTheirKinds() {
        let results = BifrostQuery.results(
            query: "c", applications: Self.applications, commands: Self.commands, limit: 8)
        let sections = BifrostSectionBuilder.sections(from: results, query: "c")

        #expect(!results.isEmpty)
        #expect(sections.count == Set(sections.map(\.id)).count)
        #expect(sections.map(\.id) == ["application", "command"])
    }

    @Test func aQueryThatStartsMidWordIsNotAMatch() {
        #expect(BifrostQuery.results(query: "aaa", applications: Self.applications).isEmpty)
        #expect(BifrostQuery.results(query: "hrome", applications: Self.applications).isEmpty)
        #expect(titles("chrome").first == "Google Chrome")
    }

    @Test func anAnswerLeadsWhateverElseMatches() {
        let results = BifrostQuery.results(
            query: "2+2", applications: Self.applications, commands: Self.commands, limit: 8)

        #expect(results.first?.kind == .calculation)
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
