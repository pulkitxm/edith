import Foundation

public enum HerdrLaunchSettings {
    // Deliberately separate from HerdrKind.logoName(for:) — that also returns "fx" for FX.sh, which is
    // not a real herdr --kind slug (the live CLI's --kind enum has no fx/fx.sh entry). Reusing it would
    // silently build a broken `agent start --kind fx`.
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
}
