import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetPagePreferenceTests {
    @Test func originalPageRestoresEnginePreferencesAndUpdatesLiveTabsAndOriginalCLI()
        async throws
    {
        defer { QuinjetWorkOwnership.enable() }
        let engineSuite = "quinjet.page.engine.fixture." + UUID().uuidString
        let uiSuite = "quinjet.page.ui.fixture." + UUID().uuidString
        let engineDefaults = try #require(UserDefaults(suiteName: engineSuite))
        let uiDefaults = try #require(UserDefaults(suiteName: uiSuite))
        defer {
            engineDefaults.removePersistentDomain(forName: engineSuite)
            uiDefaults.removePersistentDomain(forName: uiSuite)
        }
        engineDefaults.set("cmux", forKey: AppStorageKeys.Quinjet.terminal)
        engineDefaults.set("dracula", forKey: AppStorageKeys.Quinjet.theme)
        uiDefaults.set("embedded", forKey: AppStorageKeys.Quinjet.terminal)
        uiDefaults.set("github", forKey: AppStorageKeys.Quinjet.theme)
        let tree = QuinjetWorktree(
            path: "/private/tmp/synthetic-review", head: "1234567", branch: "synthetic",
            current: true, bare: false, detached: false, locked: nil, prunable: nil)
        let worker = QuinjetWorker(
            defaults: engineDefaults,
            client: .init(execute: { arguments in
                if arguments == ["capabilities", "--json"] {
                    return Data(
                        #"{"commands":[{"path":"quinjet tui","arguments":[{"id":"theme","possibleValues":["dracula","github"]}]}]}"#
                            .utf8)
                }
                #expect(arguments == ["-C", tree.path, "worktree", "list", "--json"])
                return try JSONEncoder().encode([tree])
            }), automaticActions: false)
        let model = QuinjetPageModel(uiClient: .init { try await worker.execute($0, payload: $1) })
        await model.preferences.read()
        #expect(model.preferences.state?.preference == .init(terminal: "cmux", theme: "dracula"))
        model.preferences.setTerminal("embedded")
        await settle(model.preferences)
        model.preferences.setTheme("github")
        await settle(model.preferences)
        #expect(model.preferences.error == nil)
        let configuration = QuinjetLaunchConfiguration.preferred(
            sharedDefaults: engineDefaults, standardDefaults: engineDefaults)
        #expect(configuration.terminal == .embedded && configuration.theme == .github)
        worker.model.open(
            tree, projectName: "Synthetic review", available: [tree],
            in: try #require(worker.model.selectedTab), launchEnabled: false)
        await model.refreshUI()
        model.apply(configuration, launchEnabled: false)
        for _ in 0..<10000 {
            if worker.model.selectedTab?.launchConfiguration == configuration { break }
            await Task.yield()
        }
        await model.refreshUI()
        #expect(model.selectedTab?.launchConfiguration == configuration)
        #expect(worker.model.selectedTab?.holder.descriptor == nil)
        let previousExecutable = CLIEnvironment.executableNamed
        CLIEnvironment.executableNamed = { _ in URL(fileURLWithPath: "/synthetic/quinjet") }
        defer { CLIEnvironment.executableNamed = previousExecutable }
        let reply = try await QuinjetCLIExecution.run(
            .init(arguments: ["open", tree.path, "--json"]), worker: worker)
        #expect(reply.exitCode == 0)
        let result = try #require(
            JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any])
        let arguments = try #require(result["arguments"] as? [String])
        #expect(arguments.contains("--theme") && arguments.contains("github"))
        #expect(!arguments.contains("dracula"))
        await model.shutdown()
        let recreated = QuinjetPageModel(
            uiClient: .init { try await worker.execute($0, payload: $1) })
        await recreated.preferences.read()
        #expect(
            recreated.preferences.state?.preference == .init(terminal: "embedded", theme: "github"))
        #expect(uiDefaults.string(forKey: AppStorageKeys.Quinjet.terminal) == "embedded")
        #expect(uiDefaults.string(forKey: AppStorageKeys.Quinjet.theme) == "github")
        await worker.shutdown()
        recreated.preferences.setTheme("dracula")
        await settle(recreated.preferences)
        #expect(recreated.preferences.error != nil)
        #expect(recreated.preferences.state?.preference.theme == "github")
        #expect(engineDefaults.string(forKey: AppStorageKeys.Quinjet.theme) == "github")
        await recreated.shutdown()
    }

    private func settle(_ model: QuinjetSettingsModel) async {
        for _ in 0..<10000 {
            if !model.loading { break }
            await Task.yield()
        }
        #expect(!model.loading)
    }
}
