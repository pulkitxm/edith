import EdithExtensionSupport
import Foundation

struct QuinjetSettingsStore {
    let string: (String) -> String?
    private let set: (String, String) -> Void

    init(string: @escaping (String) -> String?, set: @escaping (String, String) -> Void) {
        self.string = string
        self.set = set
    }

    init(defaults: UserDefaults) {
        self.init(
            string: defaults.string(forKey:),
            set: { value, key in defaults.set(value, forKey: key) })
    }

    func preference(themes: [String]) -> QuinjetSettingsPreference {
        let terminal =
            QuinjetTerminal(rawValue: string(AppStorageKeys.Quinjet.terminal) ?? "")
            ?? .embedded
        let stored = string(AppStorageKeys.Quinjet.theme) ?? QuinjetThemePreference.app
        return .init(
            terminal: terminal.rawValue,
            theme: stored == QuinjetThemePreference.app || themes.contains(stored)
                ? stored : QuinjetThemePreference.app)
    }

    func execute(_ operation: String, object: [String: Any], themes: [String], cmuxAvailable: Bool)
        throws -> Data
    {
        var value = preference(themes: themes)
        if operation == "quinjet.settings.read" {
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
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
            guard mutation.baseline == value else {
                throw ExtensionPeerError.rejected(
                    "The settings changed in another view. Refresh and try again.")
            }
            value = mutation.preference
            guard let terminal = QuinjetTerminal(rawValue: value.terminal),
                terminal != .cmux || cmuxAvailable
            else { throw ExtensionPeerError.invalidRequest }
        } else {
            throw ExtensionPeerError.invalidRequest
        }
        let state = QuinjetSettingsState(
            preference: value, themes: themes, cmuxAvailable: cmuxAvailable)
        try state.validate()
        let data = try JSONEncoder().encode(state)
        if operation == "quinjet.settings.save" {
            set(value.terminal, AppStorageKeys.Quinjet.terminal)
            set(value.theme, AppStorageKeys.Quinjet.theme)
        }
        return data
    }
}
