import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite struct CommandBarProviderTests {
    @Test func applicationProviderAddsRuntimeActionsOnlyForRunningApps() async {
        let installed = CommandBarApplication(
            id: "app.installed", title: "Installed", url: URL(fileURLWithPath: "/Installed.app"),
            bundleIdentifier: "com.example.installed", runningPID: nil)
        let running = CommandBarApplication(
            id: "app.running", title: "Running", url: URL(fileURLWithPath: "/Running.app"),
            bundleIdentifier: "com.example.running", runningPID: 42)
        let results = await CommandBarApplicationProvider().results(
            for: context(query: "", applications: [installed, running]))

        #expect(results.filter { $0.id.contains("installed") }.count == 2)
        #expect(results.filter { $0.id.contains("running") }.count == 4)
        #expect(results.contains { $0.id == "app-action.quit.app.running" })
        #expect(results.contains { $0.id == "app-action.relaunch.app.running" })
    }

    @Test func clipboardProviderUsesAvailableHistory() async {
        let entry = ClipboardEntry(
            id: "clipboard-1", sha256: "hash", types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: "Editor", sourceBundleID: "com.example.editor", size: 12,
            preview: "release notes")
        let results = await CommandBarClipboardProvider().results(
            for: context(query: "release", clipboardEntries: [entry]))

        #expect(results.map(\.id) == ["clipboard.clipboard-1"])
        #expect(results.first?.title == "release notes")
    }

    @Test func emojiProviderMatchesKeywordsAndKeepsStableIdentifiers() async {
        let results = await CommandBarEmojiProvider().results(for: context(query: "rocket"))

        #expect(results.contains { $0.title == "🚀" && $0.id == "emoji.1f680" })
        #expect(Set(results.map(\.id)).count == results.count)
    }

    @Test func selectedTextProviderOffersEveryLocalTransformation() async {
        let selection = CommandBarSelection(processIdentifier: 42, text: "hello world")
        let results = await CommandBarTextUtilityProvider().results(
            for: context(query: "", selection: selection))

        #expect(results.count == CommandBarTextUtility.allCases.count)
        #expect(results.contains { $0.id == "text-utility.uppercase" })
        #expect(results.contains { $0.id == "text-utility.countWords" })
    }

    @Test func systemSettingsProviderReturnsLocalDestinations() async {
        let results = await CommandBarSystemSettingsProvider().results(
            for: context(query: "display"))

        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.id.hasPrefix("system-settings.") })
    }

    private func context(
        query: String, applications: [CommandBarApplication] = [],
        clipboardEntries: [ClipboardEntry] = [], selection: CommandBarSelection? = nil
    ) -> CommandBarProviderContext {
        CommandBarProviderContext(
            query: query, applications: applications, clipboardEntries: clipboardEntries,
            selection: selection, fileScopes: [])
    }
}
