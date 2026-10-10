import EdithExtensionSupport
import Foundation

@MainActor enum QuinjetSettingsEngine {
    static func preference(_ defaults: UserDefaults, themes: [String]) -> QuinjetSettingsPreference
    {
        let terminal =
            QuinjetTerminal(
                rawValue: defaults.string(forKey: AppStorageKeys.Quinjet.terminal) ?? "")
            ?? .embedded
        let stored =
            defaults.string(forKey: AppStorageKeys.Quinjet.theme) ?? QuinjetThemePreference.app
        return .init(
            terminal: terminal.rawValue,
            theme: stored == QuinjetThemePreference.app || themes.contains(stored)
                ? stored : QuinjetThemePreference.app)
    }

    static func execute(_ operation: String, object: [String: Any], worker: QuinjetWorker)
        async throws -> Data
    {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        if operation == "quinjet.settings.read" {
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
            await worker.model.refreshThemes()
            try Task.checkCancellation()
            guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        } else if operation == "quinjet.settings.save" {
            guard Set(object.keys) == ["baseline", "preference"],
                let baseline = object["baseline"] as? [String: Any],
                let next = object["preference"] as? [String: Any],
                Set(baseline.keys) == ["terminal", "theme"],
                Set(next.keys) == ["terminal", "theme"],
                [baseline, next].allSatisfy({ value in
                    value["terminal"] is String && value["theme"] is String
                })
            else { throw ExtensionPeerError.invalidRequest }
            let mutation = try JSONDecoder().decode(
                QuinjetSettingsMutation.self,
                from: JSONSerialization.data(withJSONObject: object))
            let themes = worker.model.themes.map(\.rawValue)
            guard mutation.baseline == preference(worker.defaults, themes: themes) else {
                throw ExtensionPeerError.rejected(
                    "The settings changed in another view. Refresh and try again.")
            }
            let value = mutation.preference
            guard let terminal = QuinjetTerminal(rawValue: value.terminal),
                terminal != .cmux || terminal.isAvailable,
                value.theme == QuinjetThemePreference.app || themes.contains(value.theme)
            else { throw ExtensionPeerError.invalidRequest }
            worker.defaults.set(value.terminal, forKey: AppStorageKeys.Quinjet.terminal)
            worker.defaults.set(value.theme, forKey: AppStorageKeys.Quinjet.theme)
        } else {
            throw ExtensionPeerError.invalidRequest
        }
        let themes = worker.model.themes.map(\.rawValue)
        let state = QuinjetSettingsState(
            preference: preference(worker.defaults, themes: themes),
            themes: themes, cmuxAvailable: QuinjetTerminal.cmux.isAvailable)
        try state.validate()
        return try JSONEncoder().encode(state)
    }
}
