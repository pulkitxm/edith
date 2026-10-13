import Foundation

public enum HerdrLaunchSettings {
    public static let kinds = HerdrKind.filterLabels + [AgentLaunchKind.amp.rawValue]

    public static func sharedArguments(in defaults: UserDefaults = SharedDefaults.store) -> String {
        defaults.string(forKey: "herdr.sharedClaudeArguments") ?? ""
    }

    public static func sharedEnvironment(in defaults: UserDefaults = SharedDefaults.store) -> String
    {
        defaults.string(forKey: "herdr.sharedClaudeEnvironment") ?? ""
    }

    public static func setSharedClaudeLaunch(
        arguments: String, environment: String, in defaults: UserDefaults = SharedDefaults.store
    ) throws {
        guard arguments.utf8.count <= 8192, environment.utf8.count <= 8192,
            !arguments.utf8.contains(0)
        else {
            throw ClaudeAccountError.rejected("Launch settings are too large or invalid.")
        }
        _ = try environmentAssignments(environment)
        defaults.set(arguments, forKey: "herdr.sharedClaudeArguments")
        defaults.set(environment, forKey: "herdr.sharedClaudeEnvironment")
    }

    public static func launchArguments(
        kind: String, options: AgentLaunchOptions, catalog: AgentLaunchCatalog? = nil,
        in defaults: UserDefaults = SharedDefaults.store
    ) -> [String] {
        AgentLaunchArguments.launchArguments(kind: kind, options: options, catalog: catalog)
            + (kind == "Claude Code"
                ? sharedArguments(in: defaults).split(separator: "\n").map(String.init) : [])
    }

    public static func launchCommand(
        for kind: String, in defaults: UserDefaults = SharedDefaults.store
    ) -> String {
        let command = command(for: kind, in: defaults)
        guard kind == "Claude Code",
            let values = try? environmentAssignments(sharedEnvironment(in: defaults)),
            !values.isEmpty
        else { return command }
        return values.map { "export " + $0.0 + "=" + ShellQuote.quote($0.1) + "; " }.joined()
            + command
    }

    static func environmentAssignments(_ text: String) throws -> [(String, String)] {
        let reserved: Set<String> = [
            "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES", "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
        ]
        return try text.split(separator: "\n").map { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard parts.count == 2,
                name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                !reserved.contains(name), !line.utf8.contains(0)
            else {
                throw ClaudeAccountError.rejected(
                    "Use NAME=value per line. Account credentials and directories are managed separately."
                )
            }
            return (name, String(parts[1]))
        }
    }

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
            && (displayKind != "Claude Code" || sharedEnvironment(in: defaults).isEmpty)
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
