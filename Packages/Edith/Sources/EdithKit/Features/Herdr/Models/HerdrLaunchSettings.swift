import Foundation

public enum HerdrLaunchSettings {
    public static let kinds = HerdrKind.filterLabels + [AgentLaunchKind.amp.rawValue]

    public static func defaultHerdrSlug(for displayKind: String) -> String? {
        switch displayKind {
        case "Claude Code": "claude"
        case "Codex": "codex"
        case "OpenCode": "opencode"
        case "Cursor Agent": "cursor"
        case "Copilot CLI": "copilot"
        case "Pi": "pi"
        case "Gemini": "gemini"
        case "Grok": "grok"
        case "Cline": "cline"
        case "Amp": "amp"
        default: nil
        }
    }

    public static func command(
        for displayKind: String, in defaults: UserDefaults = SharedDefaults.store
    ) -> String {
        let stored =
            defaults.dictionary(forKey: AppStorageKeys.Herdr.launchCommands) as? [String: String]
        return stored?[displayKind] ?? defaultHerdrSlug(for: displayKind) ?? ""
    }

    public static func setCommand(
        _ command: String, for displayKind: String, in defaults: UserDefaults = SharedDefaults.store
    ) {
        var stored =
            defaults.dictionary(forKey: AppStorageKeys.Herdr.launchCommands) as? [String: String]
            ?? [:]
        stored[displayKind] = command
        defaults.set(stored, forKey: AppStorageKeys.Herdr.launchCommands)
    }

    public static func resetToDefault(
        for displayKind: String, in defaults: UserDefaults = SharedDefaults.store
    ) {
        var stored =
            defaults.dictionary(forKey: AppStorageKeys.Herdr.launchCommands) as? [String: String]
            ?? [:]
        stored.removeValue(forKey: displayKind)
        defaults.set(stored, forKey: AppStorageKeys.Herdr.launchCommands)
    }

    public static func usesHerdrAgentStart(
        for displayKind: String, in defaults: UserDefaults = SharedDefaults.store
    ) -> Bool {
        guard let slug = defaultHerdrSlug(for: displayKind) else { return false }
        return command(for: displayKind, in: defaults) == slug
    }

    public static func options(
        for displayKind: String, in defaults: UserDefaults = SharedDefaults.store
    ) -> AgentLaunchOptions {
        let stored =
            defaults.dictionary(forKey: AppStorageKeys.Herdr.launchDefaults)?[displayKind]
            as? [String: Any] ?? [:]
        return AgentLaunchOptions(
            model: stored["model"] as? String, effort: stored["effort"] as? String,
            fast: stored["fast"] as? Bool ?? false)
    }

    public static func setOptions(
        _ options: AgentLaunchOptions, for displayKind: String,
        in defaults: UserDefaults = SharedDefaults.store
    ) {
        var stored = defaults.dictionary(forKey: AppStorageKeys.Herdr.launchDefaults) ?? [:]
        if options.isEmpty {
            stored.removeValue(forKey: displayKind)
        } else {
            var entry: [String: Any] = ["fast": options.fast]
            entry["model"] = options.model
            entry["effort"] = options.effort
            stored[displayKind] = entry
        }
        defaults.set(stored, forKey: AppStorageKeys.Herdr.launchDefaults)
    }
}
