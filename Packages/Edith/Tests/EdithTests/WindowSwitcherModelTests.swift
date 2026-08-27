import Testing

@testable import EdithKit

@Suite struct WindowSwitcherModelTests {
    private let windows = [
        WindowSwitcherWindow(
            id: "100:0", appName: "Safari", bundleIdentifier: "com.apple.Safari",
            title: "Edith pull request", isMinimized: false, pid: 100),
        WindowSwitcherWindow(
            id: "100:1", appName: "Safari", bundleIdentifier: "com.apple.Safari",
            title: "Documentation", isMinimized: true, pid: 100),
        WindowSwitcherWindow(
            id: "200:0", appName: "Notes", bundleIdentifier: "com.apple.Notes",
            title: "Window plans", isMinimized: false, pid: 200),
    ]

    @Test func searchMatchesApplicationAndWindowTitles() {
        #expect(WindowSwitcherCollection.filtered(windows, query: "safari").count == 2)
        #expect(WindowSwitcherCollection.filtered(windows, query: "plans").map(\.id) == ["200:0"])
        #expect(WindowSwitcherCollection.filtered(windows, query: "  ") == windows)
    }

    @Test func groupingPreservesApplicationAndWindowOrder() {
        let groups = WindowSwitcherCollection.grouped(windows)
        #expect(groups.map(\.appName) == ["Safari", "Notes"])
        #expect(groups[0].windows.map(\.id) == ["100:0", "100:1"])
        #expect(groups[1].windows.map(\.id) == ["200:0"])
    }

    @Test func appRulesNormalizeIdentifiersAndHideWins() {
        let rules = WindowSwitcherRuleSet(
            includedCSV: " com.example.Helper,COM.EXAMPLE.UTILITY ",
            hiddenCSV: "com.example.hidden, com.example.helper")

        #expect(rules.permits(bundleIdentifier: "com.example.Utility", regular: false))
        #expect(!rules.permits(bundleIdentifier: "com.example.Helper", regular: true))
        #expect(!rules.permits(bundleIdentifier: "com.example.Other", regular: false))
        #expect(rules.permits(bundleIdentifier: "com.example.Other", regular: true))
    }

    @Test func payloadRoundTripsMinimizedWindows() {
        let encoded = WindowSwitcherIPC.encode(windows)
        #expect(WindowSwitcherIPC.decode(encoded) == windows)
        #expect(WindowSwitcherIPC.decode("invalid").isEmpty)
    }
}
