import EdithExtensionSupport
import Foundation
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetPreferenceRetentionTests {
    private final class Preferences {
        var values: [String: String]
        var writes = 0
        init(terminal: String, theme: String) {
            values = [
                AppStorageKeys.Quinjet.terminal: terminal, AppStorageKeys.Quinjet.theme: theme,
                AppStorageKeys.General.appearance: "dark",
            ]
        }
        var store: QuinjetSettingsStore {
            .init(
                string: { self.values[$0] },
                set: {
                    self.values[$1] = $0; self.writes += 1
                })
        }
    }

    private func client(_ engine: Preferences, cmuxAvailable: Bool = true) -> QuinjetUIClient {
        .init { operation, payload in
            let object = try #require(
                JSONSerialization.jsonObject(with: payload) as? [String: Any])
            return try engine.store.execute(
                operation, object: object, themes: ["dracula", "github"],
                cmuxAvailable: cmuxAvailable)
        }
    }

    private func settle(_ model: QuinjetSettingsModel) async {
        for _ in 0..<10000 {
            if !model.loading { break }
            await Task.yield()
        }
        #expect(!model.loading)
    }

    @Test func engineChoicesRestorePersistFeedOriginalLaunchArgumentsAndSurviveRecreation()
        async throws
    {
        let engine = Preferences(terminal: "cmux", theme: "dracula")
        let ui = Preferences(terminal: "embedded", theme: "github")
        let originalUI = ui.values
        let transport = client(engine)
        let model = transport.makeSettingsModel()
        await model.read()
        #expect(model.state?.preference == .init(terminal: "cmux", theme: "dracula"))
        #expect(engine.writes == 0)
        model.setTerminal("embedded")
        #expect(model.state?.preference.terminal == "cmux" && model.loading)
        await settle(model)
        model.setTheme("github")
        #expect(model.state?.preference.theme == "dracula" && model.loading)
        await settle(model)
        #expect(model.state?.preference == .init(terminal: "embedded", theme: "github"))
        let saved = try JSONDecoder().decode(
            QuinjetSettingsState.self,
            from: engine.store.execute(
                "quinjet.settings.read", object: [:], themes: ["dracula", "github"],
                cmuxAvailable: true))
        #expect(saved.preference == model.state?.preference)
        let configuration = QuinjetLaunchConfiguration.preferred(
            sharedPreference: engine.store.string, systemAppearance: nil)
        #expect(configuration.terminal == .embedded && configuration.theme == .github)
        #expect(
            configuration.arguments(
                worktreePath: "/synthetic/review", managedByEdith: true, supportsHostTheme: true)
                == [
                    "--client", "edith", "-C", "/synthetic/review", "tui", "--theme", "github",
                    "--appearance", "dark",
                ])
        model.shutdown()
        transport.stop()
        let recreatedTransport = client(engine)
        let recreated = recreatedTransport.makeSettingsModel()
        await recreated.read()
        #expect(recreated.state?.preference == saved.preference)
        recreated.setTerminal("cmux")
        await settle(recreated)
        #expect(engine.values[AppStorageKeys.Quinjet.terminal] == "cmux")
        #expect(
            QuinjetLaunchConfiguration.preferred(
                sharedPreference: engine.store.string, systemAppearance: nil
            ).terminal == .cmux)
        recreated.setTheme(QuinjetThemePreference.app)
        await settle(recreated)
        let appConfiguration = QuinjetLaunchConfiguration.preferred(
            sharedPreference: engine.store.string, systemAppearance: nil)
        #expect(appConfiguration.hostTheme != nil)
        #expect(
            appConfiguration.arguments(
                worktreePath: "/synthetic/review", managedByEdith: false, supportsHostTheme: true
            )
            .contains("--theme-palette"))
        #expect(ui.values == originalUI && ui.writes == 0)
        #expect(recreated.error == nil)
        recreated.shutdown()
        recreatedTransport.stop()
    }

    @Test func unavailableTerminalInvalidThemeAndDisabledEngineRetainConfirmedChoices()
        async throws
    {
        let engine = Preferences(terminal: "embedded", theme: "dracula")
        var enabled = true
        let transport = QuinjetUIClient { operation, payload in
            guard enabled else { throw ExtensionPeerError.unavailable }
            return try engine.store.execute(
                operation,
                object: #require(JSONSerialization.jsonObject(with: payload) as? [String: Any]),
                themes: ["dracula", "github"], cmuxAvailable: false)
        }
        let model = transport.makeSettingsModel()
        await model.read()
        let confirmed = try #require(model.state?.preference)
        for selection in ["cmux", "unknown-terminal"] {
            model.setTerminal(selection)
            await settle(model)
            #expect(model.state?.preference == confirmed && model.error != nil)
            #expect(engine.writes == 0)
        }
        model.setTheme("unadvertised")
        await settle(model)
        #expect(model.state?.preference == confirmed && model.error != nil)
        #expect(engine.writes == 0)
        enabled = false
        model.setTheme("github")
        await settle(model)
        #expect(model.state?.preference == confirmed && model.error != nil)
        #expect(engine.values[AppStorageKeys.Quinjet.theme] == "dracula" && engine.writes == 0)
        model.shutdown()
        transport.stop()
        model.setTheme("github")
        #expect(engine.writes == 0)
        let disabled = transport.makeSettingsModel()
        await disabled.read()
        #expect(disabled.state == nil && disabled.error != nil)
        disabled.shutdown()
    }

    @Test func concurrentViewChangesRejectStaleBaselineAndRestoreOnRead() async throws {
        let engine = Preferences(terminal: "embedded", theme: "dracula")
        let firstTransport = client(engine)
        let secondTransport = client(engine)
        let first = firstTransport.makeSettingsModel()
        let second = secondTransport.makeSettingsModel()
        await first.read()
        await second.read()
        first.setTheme("github")
        first.setTerminal("cmux")
        await settle(first)
        #expect(first.state?.preference == .init(terminal: "embedded", theme: "github"))
        second.setTerminal("cmux")
        await settle(second)
        #expect(second.error != nil)
        #expect(second.state?.preference == .init(terminal: "embedded", theme: "dracula"))
        #expect(engine.writes == 2)
        await second.read()
        #expect(second.error == nil && second.state?.preference == first.state?.preference)
        first.shutdown()
        second.shutdown()
        firstTransport.stop()
        secondTransport.stop()
    }
}
