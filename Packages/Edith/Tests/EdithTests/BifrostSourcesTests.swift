import CoreGraphics
import Foundation
import Testing

@testable import EdithKit

@Suite struct BifrostSourceTests {
    @Test func everySourceOwnsADistinctKey() {
        let keys = BifrostSource.allCases.map(\.defaultsKey)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.hasPrefix("bifrostSource") })
    }

    @Test func onlyOpenWindowsIsOffByDefault() {
        let off = BifrostSource.allCases.filter { !$0.isOnByDefault }
        #expect(off == [.openWindows])
    }

    @Test func storedValuesOverrideTheDefault() {
        let name = "BifrostSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(BifrostSource.snippets.isEnabled(in: defaults))
        defaults.set(false, forKey: BifrostSource.snippets.defaultsKey)
        defaults.set(true, forKey: BifrostSource.openWindows.defaultsKey)
        let enabled = BifrostSource.enabled(in: defaults)
        #expect(!enabled.contains(.snippets))
        #expect(enabled.contains(.openWindows))
    }

    @Test func accessibilityIsFlaggedWhereItIsNeeded() {
        #expect(BifrostSource.windowActions.needsAccessibility)
        #expect(BifrostSource.snippets.needsAccessibility)
        #expect(!BifrostSource.quicklinks.needsAccessibility)
    }
}

@Suite struct BifrostEntryCatalogTests {
    private let quicklink = BifrostQuicklink(
        id: "one", name: "GitHub", target: "https://github.com/search?q={query}", keyword: "gh")
    private let snippet = BifrostSnippet(
        id: "two", name: "Signature", content: "Sent on {date}", keyword: "sig")
    private let shell = BifrostShellCommand(
        id: "three", name: "Free space", script: "df -h", keyword: "df")

    @Test func disabledSourcesContributeNothing() {
        let entries = BifrostEntryCatalog.entries(
            sources: [.systemActions], quicklinks: [quicklink], snippets: [snippet],
            shellCommands: [shell])
        #expect(entries.allSatisfy { $0.kind == .systemAction })
        #expect(entries.count == BifrostSystemAction.allCases.count)
    }

    @Test func eachSourceBecomesItsOwnEntries() {
        let entries = BifrostEntryCatalog.entries(
            sources: Set(BifrostSource.allCases), quicklinks: [quicklink], snippets: [snippet],
            shellCommands: [shell], shortcuts: ["Start Focus"],
            runningApplications: [
                BifrostRunningApplication(bundleID: "com.apple.Safari", name: "Safari")
            ],
            openWindows: [
                BifrostWindowHandle(
                    processID: 42, ownerName: "Safari", title: "Inbox", windowNumber: 7)
            ])
        let kinds = Set(entries.map(\.kind))
        #expect(kinds.contains(.quicklink))
        #expect(kinds.contains(.snippet))
        #expect(kinds.contains(.shellCommand))
        #expect(kinds.contains(.shortcut))
        #expect(kinds.contains(.windowAction))
        #expect(kinds.contains(.systemAction))
        #expect(kinds.contains(.runningApp))
        #expect(kinds.contains(.openWindow))
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    @Test func aRunningApplicationOffersSwitchingAndQuitting() {
        let entries = BifrostEntryCatalog.entries(
            sources: [.runningApplications],
            runningApplications: [
                BifrostRunningApplication(bundleID: "com.apple.Safari", name: "Safari")
            ])
        #expect(entries.count == 2)
        #expect(entries[0].action == .activate(bundleID: "com.apple.Safari"))
        #expect(entries[1].action == .quit(bundleID: "com.apple.Safari"))
        #expect(entries[1].title == "Quit Safari")
    }

    @Test func invalidLibraryEntriesAreSkipped() {
        let entries = BifrostEntryCatalog.entries(
            sources: [.quicklinks, .snippets, .shellCommands],
            quicklinks: [BifrostQuicklink(name: "  ", target: "https://example.com")],
            snippets: [BifrostSnippet(name: "Empty", content: "")],
            shellCommands: [BifrostShellCommand(name: "Empty", script: "   ")])
        #expect(entries.isEmpty)
    }

    @Test func keywordsMapBackToTheirEntry() {
        let entries = BifrostEntryCatalog.entries(
            sources: [.quicklinks, .snippets, .shellCommands], quicklinks: [quicklink],
            snippets: [snippet], shellCommands: [shell])
        let keywords = BifrostEntryCatalog.keywords(in: entries)
        #expect(keywords.count == 3)
        #expect(keywords["gh"]?.title == "GitHub")
        #expect(keywords["sig"]?.kind == .snippet)
        #expect(keywords["df"]?.action == .shell(id: "three"))
    }

    @Test func entriesWithoutAKeywordAreNotRoutable() {
        let entries = BifrostEntryCatalog.entries(sources: [.windowActions])
        #expect(BifrostEntryCatalog.keywords(in: entries).isEmpty)
    }
}

@Suite struct BifrostActionTests {
    @Test func everyActionHasADistinctTargetKey() {
        let actions: [BifrostAction] = [
            .launch(path: "/Applications/Safari.app"), .run(commandID: "panel.open"),
            .copy(text: "hello"), .quicklink(id: "a"), .snippet(id: "a"), .shell(id: "a"),
            .shortcut(name: "a"), .window(.leftHalf), .system(.lockScreen),
            .activate(bundleID: "a"), .quit(bundleID: "a"),
            .focusWindow(processID: 1, title: "a"),
        ]
        let keys = actions.map(\.targetKey)
        #expect(Set(keys).count == keys.count)
    }

    @Test func onlyCopyingIsNotRepeatable() {
        #expect(!BifrostAction.copy(text: "x").isRepeatable)
        #expect(BifrostAction.window(.maximize).isRepeatable)
        #expect(BifrostAction.snippet(id: "a").isRepeatable)
    }

    @Test func theVerbMatchesWhatTheActionDoes() {
        #expect(BifrostAction.quicklink(id: "a").primaryVerb == "Open")
        #expect(BifrostAction.snippet(id: "a").primaryVerb == "Insert")
        #expect(BifrostAction.shell(id: "a").primaryVerb == "Run")
        #expect(BifrostAction.system(.sleepMac).primaryVerb == "Run")
        #expect(BifrostAction.quit(bundleID: "a").primaryVerb == "Quit")
        #expect(BifrostAction.activate(bundleID: "a").primaryVerb == "Switch")
        #expect(BifrostAction.copy(text: "a").primaryVerb == "Copy")
    }

    @Test func resultsCarryTheEntryCopyText() {
        let entry = BifrostEntryCatalog.entry(
            for: BifrostQuicklink(id: "a", name: "Docs", target: "https://docs.example"))
        let result = BifrostQuery.entryResult(entry, score: 10)
        #expect(result.copyText == "https://docs.example")
        let plain = BifrostResult(
            id: "x", kind: .command, title: "T", subtitle: "S", symbolName: "gear",
            action: .copy(text: "plain"), score: 1)
        #expect(plain.copyText == "plain")
    }
}

@Suite struct BifrostKeywordRoutingTests {
    private func entries() -> [BifrostEntry] {
        BifrostEntryCatalog.entries(
            sources: [.quicklinks, .systemActions],
            quicklinks: [
                BifrostQuicklink(
                    id: "one", name: "GitHub", target: "https://github.com/search?q={query}",
                    keyword: "gh")
            ])
    }

    @Test func aKeywordRoutesStraightToItsEntry() {
        let results = BifrostQuery.results(
            query: "gh edith", applications: [], entries: entries(), limit: 8)
        #expect(results.count == 1)
        #expect(results.first?.title == "GitHub")
        #expect(results.first?.subtitle.hasSuffix("edith") == true)
    }

    @Test func anUnknownFirstWordSearchesNormally() {
        let results = BifrostQuery.results(
            query: "lock screen", applications: [], entries: entries(), limit: 8)
        #expect(results.contains { $0.title == "Lock Screen" })
    }

    @Test func aKeywordOnItsOwnDoesNotRoute() {
        #expect(BifrostQuery.keywordRoute("gh", entries: entries()) == nil)
        #expect(BifrostQuery.keywordArgument("gh") == "")
        #expect(BifrostQuery.keywordArgument("gh two words") == "two words")
    }
}

@Suite struct BifrostEntryRankingTests {
    private let applications = [
        BifrostApplication(name: "Safari", path: "/Applications/Safari.app")
    ]

    private func entries() -> [BifrostEntry] {
        BifrostEntryCatalog.entries(sources: [.windowActions, .systemActions])
    }

    @Test func entriesRankAlongsideApplications() {
        let results = BifrostQuery.results(
            query: "left half", applications: applications, entries: entries(), limit: 8)
        #expect(results.first?.title == "Left Half")
        #expect(results.first?.kind == .windowAction)
    }

    @Test func answersStillOutrankEverythingElse() {
        let results = BifrostQuery.results(
            query: "2+2", applications: applications, entries: entries(), limit: 8)
        #expect(results.first?.kind == .calculation)
    }

    @Test func anEmptyQueryLeansOnTheLedger() {
        var ledger = BifrostUsageLedger()
        let now = Date()
        ledger.record(BifrostAction.system(.lockScreen).targetKey, query: "", at: now)
        let results = BifrostQuery.results(
            query: "", applications: applications, entries: entries(), ledger: ledger, now: now,
            limit: 8)
        #expect(results.first?.title == "Lock Screen")
    }

    @Test func theLimitIsHonoured() {
        let results = BifrostQuery.results(
            query: "window", applications: applications, entries: entries(), limit: 4)
        #expect(results.count <= 4)
    }
}

@Suite struct BifrostLibraryTests {
    @Test func theLibraryRoundTripsThroughDefaults() {
        let name = "BifrostLibraryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let links = [BifrostQuicklink(id: "one", name: "One", target: "https://one.test")]
        BifrostLibrary.save(links, key: AppStorageKeys.Bifrost.quicklinks, defaults: defaults)
        #expect(BifrostLibraryStore.quicklinks(defaults) == links)
        #expect(BifrostLibraryStore.quicklink(id: "one", in: defaults)?.name == "One")
        #expect(BifrostLibraryStore.quicklink(id: "nope", in: defaults) == nil)
    }

    @Test func brokenJSONDecodesToNothing() {
        let name = "BifrostLibraryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("not json", forKey: AppStorageKeys.Bifrost.snippets)
        #expect(BifrostLibraryStore.snippets(defaults).isEmpty)
    }

    @Test func quicklinksKnowWhenTheyTakeInput() {
        let plain = BifrostQuicklink(name: "Docs", target: "https://docs.example")
        let templated = BifrostQuicklink(name: "Search", target: "https://e.test/?q={query}")
        #expect(!plain.takesArgument)
        #expect(templated.takesArgument)
        #expect(templated.isWebTarget)
    }

    @Test func webQuicklinksEncodeTheirArgument() {
        let link = BifrostQuicklink(name: "Search", target: "https://e.test/?q={query}")
        let resolved = link.resolved(context: BifrostPlaceholderContext(query: "a b"))
        #expect(resolved == "https://e.test/?q=a%20b")
    }

    @Test func fileQuicklinksDoNotEncode() {
        let link = BifrostQuicklink(name: "Notes", target: "~/Notes/{query}.md")
        let resolved = link.resolved(context: BifrostPlaceholderContext(query: "a b"))
        #expect(resolved == "~/Notes/a b.md")
    }

    @Test func snippetsPreviewOnOneLine() {
        let snippet = BifrostSnippet(name: "Multi", content: "one\ntwo")
        #expect(snippet.preview == "one two")
    }
}
@Suite struct BifrostPlaceholderTests {
    private func context() -> BifrostPlaceholderContext {
        BifrostPlaceholderContext(
            query: "a b", clipboard: "copied", selection: "",
            date: Date(timeIntervalSince1970: 0), uuid: "fixed",
            timeZone: TimeZone(identifier: "UTC") ?? .current)
    }

    @Test func placeholdersExpandInPlace() {
        let expanded = BifrostPlaceholder.expand(
            "say {query} and {clipboard} on {date}", context: context())
        #expect(expanded == "say a b and copied on 1970-01-01")
    }

    @Test func webTargetsPercentEncodeTheQuery() {
        let expanded = BifrostPlaceholder.expand(
            "https://example.com/?q={query}", context: context(), encoding: .urlQuery)
        #expect(expanded == "https://example.com/?q=a%20b")
    }

    @Test func customDateFormatsAreHonoured() {
        let expanded = BifrostPlaceholder.expand("{date:yyyy}", context: context())
        #expect(expanded == "1970")
    }

    @Test func selectionFallsBackToTheClipboard() {
        #expect(BifrostPlaceholder.expand("{selection}", context: context()) == "copied")
    }

    @Test func unknownBracesAreLeftAlone() {
        #expect(BifrostPlaceholder.expand("{nope}", context: context()) == "{nope}")
    }

    @Test func tokensAreReportedOnce() {
        #expect(BifrostPlaceholder.tokens(in: "{query} {query} {uuid}") == ["query", "uuid"])
        #expect(BifrostPlaceholder.usesQuery("{argument}"))
        #expect(!BifrostPlaceholder.usesQuery("{clipboard}"))
    }
}

@Suite struct BifrostWindowActionTests {
    private let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    @Test func halvesAndQuartersDivideTheVisibleFrame() {
        let current = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(
            BifrostWindowAction.leftHalf.frame(in: visible, current: current)
                == CGRect(x: 0, y: 0, width: 800, height: 1000))
        #expect(
            BifrostWindowAction.bottomRightQuarter.frame(in: visible, current: current)
                == CGRect(x: 800, y: 500, width: 800, height: 500))
        #expect(
            BifrostWindowAction.maximize.frame(in: visible, current: current) == visible)
    }

    @Test func thirdsCoverTheWholeWidth() {
        let current = CGRect(x: 0, y: 0, width: 100, height: 100)
        let first = BifrostWindowAction.firstThird.frame(in: visible, current: current)
        let last = BifrostWindowAction.lastThird.frame(in: visible, current: current)
        #expect(first?.minX == 0)
        #expect(abs((first?.width ?? 0) - visible.width / 3) <= 1)
        #expect(abs((last?.maxX ?? 0) - visible.maxX) <= 1)
    }

    @Test func nudgesStayInsideTheVisibleFrame() throws {
        let current = CGRect(x: 0, y: 0, width: 400, height: 300)
        let moved = try #require(
            BifrostWindowAction.nudgeLeft.frame(in: visible, current: current))
        #expect(moved.minX == 0)
        let down = try #require(
            BifrostWindowAction.nudgeDown.frame(in: visible, current: current))
        #expect(down.minY == 40)
    }

    @Test func actionsHandledElsewhereReturnNoFrame() {
        let current = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(BifrostWindowAction.restore.frame(in: visible, current: current) == nil)
        #expect(BifrostWindowAction.nextDisplay.frame(in: visible, current: current) == nil)
        #expect(BifrostWindowAction.restore.restoresPrevious)
        #expect(BifrostWindowAction.previousDisplay.movesDisplay)
    }

    @Test func movingBetweenDisplaysKeepsProportionsInside() {
        let source = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let target = CGRect(x: 1600, y: 0, width: 800, height: 600)
        let mapped = BifrostWindowAction.proportional(
            CGRect(x: 800, y: 500, width: 800, height: 500), from: source, to: target)
        #expect(target.contains(mapped))
    }

    @Test func everyActionHasATitleAndSymbol() {
        for action in BifrostWindowAction.allCases {
            #expect(!action.title.isEmpty)
            #expect(!action.symbolName.isEmpty)
        }
        #expect(BifrostWindowAction.allCases.count == 27)
    }
}

@Suite struct BifrostShellCommandTests {
    @Test func placeholdersBecomeQuotedVariableReferences() {
        let command = BifrostShellCommand(
            name: "Echo", script: "echo {query} '{query}' \"{clipboard}\"")
        let invocation = command.resolved(
            context: BifrostPlaceholderContext(query: "q", clipboard: "c"))
        #expect(
            invocation.script
                == "echo \"${EDITH_BIFROST_1}\" ''\"${EDITH_BIFROST_2}\"'' \"${EDITH_BIFROST_3}\"")
        #expect(
            invocation.environment
                == ["EDITH_BIFROST_1": "q", "EDITH_BIFROST_2": "q", "EDITH_BIFROST_3": "c"])
    }

    @Test(arguments: [
        ("printf %s {clipboard}", ""),
        ("printf %s \"{clipboard}\"", ""),
        ("printf %s '{clipboard}'", ""),
        ("printf %s \"said: {clipboard}\"", "said: "),
        ("printf %s 'said: {clipboard}'", "said: "),
    ])
    func hostileClipboardTextStaysData(script: String, prefix: String) async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("bifrost-\(UUID().uuidString)").path
        let hostile = "a b; touch \(marker) $(touch \(marker)) `touch \(marker)` 'q' \"d\""
        let invocation = BifrostShellCommand(name: "Paste", script: script)
            .resolved(context: BifrostPlaceholderContext(clipboard: hostile))
        let output = try await LocalMachineCommandExecution.run(
            invocation.script, environment: invocation.environment, timeout: 20
        ).get()
        #expect(output == prefix + hostile)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func formattedPlaceholdersStillExpand() {
        let invocation = BifrostShellCommand(name: "Stamp", script: "echo {date:yyyy}")
            .resolved(
                context: BifrostPlaceholderContext(
                    date: Date(timeIntervalSince1970: 1_790_000_000),
                    timeZone: TimeZone(identifier: "UTC")!))
        #expect(invocation.script == "echo \"${EDITH_BIFROST_1}\"")
        #expect(invocation.environment["EDITH_BIFROST_1"] == "2026")
    }
}
