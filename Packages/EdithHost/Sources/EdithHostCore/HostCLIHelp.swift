import Foundation

public enum HostCLIHelp {
    private struct Definition {
        let route: [String]
        let summary: String
        let flags: [String]
        let options: [String]
        let words: [String]
        init(
            _ route: String, _ summary: String, flags: [String] = ["json"],
            options: [String] = [], words: [String] = []
        ) {
            self.route = route.split(separator: " ").map(String.init); self.summary = summary
            self.flags = flags; self.options = options; self.words = words
        }
    }

    public static func document(version: String, registry: HostCLIProviderRegistry?) throws
        -> HostCLIJSON
    {
        var root = coreCommand()
        var issues = registry?.issues ?? [:]
        for provider in registry?.providers ?? [] {
            if let core = provider.catalog.coreOwner {
                if let command = core.parserHelp?.object?["command"] {
                    root = merge(root, command)
                } else {
                    for command in core.routes ?? [] {
                        issues[provider.state.id + ".agent"] =
                            "Original agent parser metadata is unavailable."
                        root = insert(
                            root, route: command.route,
                            leaf: .object([
                                "commandName": .string(command.route.last!),
                                "abstract": .string(command.summary), "shouldDisplay": .bool(true),
                                "metadataComplete": .bool(false),
                            ]))
                    }
                }
            }
            if let documents = provider.catalog.parserHelp, !documents.isEmpty {
                for document in documents {
                    if let command = document.object?["command"] { root = merge(root, command) }
                }
            } else {
                issues[provider.state.id] = "Original parser argument metadata is unavailable."
                for command in provider.catalog.commands {
                    root = insert(
                        root, route: command.route,
                        leaf: .object([
                            "commandName": .string(command.route.last!),
                            "abstract": .string(command.summary), "shouldDisplay": .bool(true),
                            "metadataComplete": .bool(false),
                        ]))
                }
            }
        }
        var object = root.object!
        object["version"] = .string(version)
        return .object([
            "serializationVersion": .integer(0), "command": .object(object),
            "providerIssues": .object(issues.mapValues(HostCLIJSON.string)),
        ])
    }

    public static func text(_ route: [String]) throws -> String {
        var normalized = route
        if route == ["app", "ls"] { normalized = ["app", "actions"] }
        if route == ["config", "list"] { normalized = ["config", "ls"] }
        if route == ["permissions", "list"] { normalized = ["permissions", "ls"] }
        guard let value = find(coreCommand(), route: normalized), let object = value.object else {
            throw HostCLIError.usage("Unknown core command.")
        }
        let arguments = object["arguments"]?.array?.compactMap(\.object) ?? []
        let positionals = arguments.filter { $0["kind"] == .string("positional") }.map {
            "<\($0["valueName"]?.string ?? "value")>"
        }
        var lines = [
            object["abstract"]?.string ?? "Drive Edith from the terminal.",
            "", "usage: " + (["ed"] + route + positionals + ["[options]"]).joined(separator: " "),
        ]
        let children = object["subcommands"]?.array?.compactMap(\.object) ?? []
        if !children.isEmpty {
            lines +=
                ["", "subcommands:"]
                + children.map {
                    "  \($0["commandName"]?.string ?? "")  \($0["abstract"]?.string ?? "")"
                }
        }
        let options = arguments.filter { $0["kind"] != .string("positional") }
        if !options.isEmpty {
            lines +=
                ["", "options:"]
                + options.map { argument in
                    let names =
                        argument["names"]?.array?.compactMap { $0.object?["name"]?.string } ?? []
                    return "  " + names.map { "--" + $0 }.joined(separator: ", ")
                        + (argument["kind"] == .string("option") ? " <value>" : "")
                }
        }
        return lines.joined(separator: "\n")
    }

    public static func completionOptions(_ route: [String]) -> [String] {
        guard let arguments = find(coreCommand(), route: route)?.object?["arguments"]?.array else {
            return []
        }
        return arguments.flatMap { $0.object?["names"]?.array ?? [] }.compactMap {
            $0.object?["name"]?.string
        }.map { "--" + $0 }
    }

    public static var routes: [[String]] { definitions.map(\.route) }

    private static func coreCommand() -> HostCLIJSON {
        var root: HostCLIJSON = .object([
            "commandName": .string("ed"), "shouldDisplay": .bool(true),
            "abstract": .string("Drive Edith, its settings, and its machines from the terminal."),
            "arguments": .array([argument("help", kind: "flag"), argument("version", kind: "flag")]
            ),
        ])
        for definition in definitions {
            let arguments =
                definition.flags.map { argument($0, kind: "flag") }
                + definition.options.map { argument($0, kind: "option") }
                + definition.words.map { argument($0, kind: "positional") }
                + [argument("help", kind: "flag")]
            var leaf: [String: HostCLIJSON] = [
                "commandName": .string(definition.route.last!),
                "superCommands": .strings(["ed"] + definition.route.dropLast()),
                "shouldDisplay": .bool(true), "abstract": .string(definition.summary),
                "arguments": .array(arguments),
            ]
            if definition.route == ["app", "actions"] { leaf["aliases"] = .strings(["ls"]) }
            if definition.route == ["config", "ls"] || definition.route == ["permissions", "ls"] {
                leaf["aliases"] = .strings(["list"])
            }
            if ["config", "permissions"].contains(definition.route.first ?? ""),
                definition.route.count == 1
            {
                leaf["defaultSubcommand"] = .string("ls")
            }
            if definition.route == ["agent"] { leaf["defaultSubcommand"] = .string("status") }
            if [["agent", "tasks"], ["agent", "schedule"]].contains(definition.route) {
                leaf["defaultSubcommand"] = .string("ls")
            }
            if definition.route == ["app"] { leaf["defaultSubcommand"] = .string("actions") }
            root = insert(
                root, route: definition.route,
                leaf: .object(leaf))
        }
        return root
    }

    private static func argument(_ name: String, kind: String) -> HostCLIJSON {
        var value: [String: HostCLIJSON] = [
            "kind": .string(kind), "shouldDisplay": .bool(true),
            "isOptional": .bool(kind != "positional" || name.hasPrefix("[")),
            "isRepeating": .bool(name == "command..."),
            "parsingStrategy": .string(name == "command..." ? "postTerminator" : "default"),
            "valueName": .string(
                name == "command..."
                    ? "command" : name.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
        ]
        if kind != "positional" {
            let label: HostCLIJSON = .object(["kind": .string("long"), "name": .string(name)])
            value["names"] = .array([label]); value["preferredName"] = label
        }
        return .object(value)
    }

    private static func insert(_ root: HostCLIJSON, route: [String], leaf: HostCLIJSON)
        -> HostCLIJSON
    {
        guard let name = route.first else { return root }
        var object = root.object ?? [:]
        var children = object["subcommands"]?.array ?? []
        let index = children.firstIndex { $0.object?["commandName"] == .string(name) }
        let existing =
            index.map { children[$0] }
            ?? .object(["commandName": .string(name), "shouldDisplay": .bool(true)])
        let updated =
            route.count == 1
            ? mergeValues(existing, leaf)
            : insert(existing, route: Array(route.dropFirst()), leaf: leaf)
        if let index { children[index] = updated } else { children.append(updated) }
        object["subcommands"] = .array(children)
        return .object(object)
    }

    private static func merge(_ root: HostCLIJSON, _ command: HostCLIJSON) -> HostCLIJSON {
        guard let name = command.object?["commandName"]?.string else { return root }
        return insert(root, route: [name], leaf: command)
    }

    private static func mergeValues(_ existing: HostCLIJSON, _ incoming: HostCLIJSON)
        -> HostCLIJSON
    {
        var value = existing.object ?? [:]
        for (key, item) in incoming.object ?? [:] where key != "subcommands" { value[key] = item }
        var result = HostCLIJSON.object(value)
        for child in incoming.object?["subcommands"]?.array ?? [] { result = merge(result, child) }
        return result
    }

    private static func find(_ root: HostCLIJSON, route: [String]) -> HostCLIJSON? {
        guard let name = route.first else { return root }
        guard
            let child = root.object?["subcommands"]?.array?.first(where: {
                $0.object?["commandName"] == .string(name)
            })
        else { return nil }
        return find(child, route: Array(route.dropFirst()))
    }

    private static let definitions: [Definition] = [
        .init("guide", "Print the built-in manual or parser catalog.", words: ["[topic]"]),
        .init("schema", "Print JSON Schema for available configuration.", flags: []),
        .init("version", "Print the Edith version."),
        .init("status", "Inspect command links and shell completions."),
        .init("install", "Link ed and edith to this executable.", options: ["directory"]),
        .init(
            "uninstall", "Remove command links owned by this executable.", options: ["directory"]),
        .init("completions", "Generate or install shell completions.", options: ["shell"]),
        .init("completions install", "Install detected shell completions.", options: ["shell"]),
        .init("completions source", "Print a completion source command.", options: ["shell"]),
        .init("completions zsh", "Print the zsh completion script.", flags: []),
        .init("completions bash", "Print the bash completion script.", flags: []),
        .init("completions fish", "Print the fish completion script.", flags: []),
        .init("config", "Read and write scoped application and extension preferences."),
        .init(
            "config ls", "List settings.", flags: ["json", "changed"], options: ["group"],
            words: ["[prefix]"]),
        .init("config get", "Read a setting.", words: ["key"]),
        .init("config set", "Validate and write a setting.", words: ["key", "value"]),
        .init("config unset", "Restore a setting's default.", words: ["key"]),
        .init("config describe", "Describe setting type, scope and default.", words: ["key"]),
        .init("config export", "Export changed settings as JSON.", flags: ["defaults"]),
        .init(
            "config import", "Validate and import settings.", flags: ["json", "dry-run"],
            words: ["file"]),
        .init("permissions", "Inspect and explicitly request macOS permissions."),
        .init("permissions ls", "List permission usage.", flags: ["json", "attention"]),
        .init("permissions refresh", "Refresh permission state."),
        .init("permissions request", "Request one permission.", words: ["permission"]),
        .init(
            "permissions settings", "Open one permission's settings pane.", words: ["permission"]),
        .init("app", "Inspect and control this Edith app installation."),
        .init("app actions", "List original one-shot actions and availability."),
        .init("app info", "Inspect this app's version and identity."),
        .init("app diagnostics", "Inspect app process and enabled providers."),
        .init("app paths", "List scoped app data locations."),
        .init("app links", "List repository, creator and cached contributor links."),
        .init("app open-path", "Open an app data location.", words: ["id"]),
        .init("app open-link", "Open an app link.", words: ["id"]),
        .init("app clean-keys", "Request keyboard cleaning from its owning extension."),
        .init("app test-notification", "Send a test notification."),
        .init("app open", "Open the original app window."),
        .init("app quit", "Preview quitting this app.", flags: ["json", "yes"]),
        .init(
            "app relaunch", "Preview quitting and relaunching this app.", flags: ["json", "yes"]),
        .init("app clear-updates", "Preview clearing update history.", flags: ["json", "yes"]),
        .init("app check-updates", "Check for an app update.", flags: ["json", "no-wait"]),
        .init("app updates", "Read update history.", options: ["limit"]),
        .init(
            "app reveal", "Show an original app section.", flags: ["json", "list"],
            options: ["tab"], words: ["[section]"]),
        .init("app route", "Read the route without focusing a window."),
        .init("app navigate", "Navigate the original window without focusing.", words: ["route"]),
        .init("app back", "Navigate back without focusing."),
        .init("app forward", "Navigate forward without focusing."),
        .init("app snapshot", "Save app window images.", options: ["dir"]),
        .init("agent", "Inspect and control the owned background core and optional jobs."),
        Definition("agent tasks", "Inspect and control background tasks."),
        Definition("agent tasks ls", "List active and completed background tasks."),
        Definition(
            "agent tasks inspect", "Read a task's progress and retained result.", words: ["id"]),
        Definition(
            "agent tasks cancel", "Cancel a queued or running background task.", words: ["id"]),
        Definition(
            "agent tasks exec", "Execute a command in the bounded core task queue.",
            flags: ["json", "detach"], options: ["timeout"], words: ["command..."]),
        Definition("agent schedule", "Run commands on a schedule in the background agent."),
        Definition("agent schedule ls", "List scheduled commands with their next and last run."),
        Definition(
            "agent schedule add", "Schedule an absolute command on an interval or cron expression.",
            options: ["every", "cron", "cwd", "timeout"], words: ["name", "command..."]),
        Definition(
            "agent schedule rm", "Remove a schedule while its already running task continues.",
            words: ["name"]),
        Definition("agent schedule enable", "Resume a paused scheduled command.", words: ["name"]),
        Definition(
            "agent schedule disable", "Pause a schedule while its already running task continues.",
            words: ["name"]),
        Definition(
            "agent schedule run", "Run a schedule now without moving its next scheduled run.",
            words: ["name"]),
        .init("agent status", "Show the actual owned process, build, memory and store."),
        .init("agent jobs", "List registered jobs from their actual owners."),
        .init("agent restart", "Restart the owned same-executable core process."),
        .init("agent logs", "Read recent owned background log lines.", options: ["last"]),
        .init("agent events", "Read the retained background event timeline."),
        .init("agent run", "Queue a registered job through its owner.", words: ["job"]),
        .init("agent cancel", "Cancel a running job through its owner.", words: ["job"]),
        .init("extensions status", "Read actual owning extension readiness.", words: ["[id]"]),
        .init("extensions verify", "Run every owning extension readiness check.", words: ["id"]),
        .init(
            "extensions doctor", "Diagnose owning extension setup and runtime problems.",
            words: ["[id]"]),
        .init(
            "extensions setup", "Run noninteractive owned setup or preview it.",
            flags: ["json", "dry-run", "install-tools"], words: ["id"]),
        .init("extensions", "Manage individual optional downloads."),
        .init("extensions ls", "List all optional extensions.", flags: []),
        .init("extensions info", "Inspect an extension.", flags: [], words: ["id"]),
        .init("extensions install", "Download one compatible extension.", flags: [], words: ["id"]),
        .init("extensions update", "Update one installed extension.", flags: [], words: ["id"]),
        .init("extensions enable", "Enable an installed extension.", flags: [], words: ["id"]),
        .init("extensions disable", "Prepare and stop an extension.", flags: [], words: ["id"]),
        .init("extensions remove", "Remove an extension.", flags: [], words: ["id"]),
        .init(
            "invoke", "Invoke a checked extension engine operation.", flags: ["raw"],
            options: ["json", "timeout"], words: ["id", "operation"]),
        .init("mcp", "Serve live checked CLI and native tools over bounded stdio.", flags: []),
    ]
}
