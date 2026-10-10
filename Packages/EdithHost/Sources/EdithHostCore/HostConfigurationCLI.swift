import EdithExtensionSupport
import Foundation

@MainActor public final class HostConfigurationCLI {
    private let shared: UserDefaults
    private let standard: UserDefaults
    private let settings: [HostCLISetting]
    private let changed: () -> Void

    public init(
        shared: UserDefaults, standard: UserDefaults,
        settings: [HostCLISetting] = HostConfigurationCLI.applicationSettings,
        changed: @escaping () -> Void = {}
    ) throws {
        guard Set(settings.map(\.key)).count == settings.count else {
            throw HostCLIError.rejected("Duplicate setting ownership.")
        }
        for setting in settings { try setting.validate() }
        self.shared = shared; self.standard = standard; self.settings = settings;
        self.changed = changed
    }

    public func execute(_ arguments: [String], input: Data = Data()) throws -> ExtensionCLIReply {
        var args = try HostCLIArguments(
            arguments, flags: ["--json", "--changed", "--defaults", "--dry-run"],
            options: ["--group"])
        let action = args.words.isEmpty ? "ls" : args.words.removeFirst()
        let json = args.flags.contains("--json")
        switch action {
        case "ls", "list":
            try args.require(words: 0...1, flags: ["--json", "--changed"], options: ["--group"])
            let prefix = args.words.first ?? ""
            let group = args.options["--group"]
            if let group, !settings.contains(where: { $0.group == group }) {
                throw HostCLIError.usage("No group named \(group).")
            }
            let selected = settings.filter {
                $0.key.hasPrefix(prefix) && (group == nil || $0.group == group)
                    && (!args.flags.contains("--changed")
                        || store($0).object(forKey: $0.key) != nil)
            }
            if json { return try HostCLIOutput.json(.array(try selected.map(describe))) }
            return try HostCLIOutput.text(
                HostCLIOutput.table(
                    headers: ["KEY", "GROUP", "TYPE", "VALUE"],
                    rows: try selected.map {
                        [$0.key, $0.group, $0.type.rawValue, HostCLIOutput.text(try value($0))]
                    }))
        case "get", "describe", "set", "unset":
            try args.require(words: action == "set" ? 2...2 : 1...1, flags: ["--json"])
            let definition = try definition(args.words[0])
            if action == "get" {
                return json
                    ? try HostCLIOutput.json(describe(definition))
                    : try HostCLIOutput.text(HostCLIOutput.text(value(definition)))
            }
            if action == "describe" {
                if json { return try HostCLIOutput.json(describe(definition)) }
                return try HostCLIOutput.text(
                    "\(definition.key)\n  \(definition.summary)\n  type     \(definition.type.rawValue)\n  group    \(definition.group)\n  scope    \(definition.scope)\n  default  \(HostCLIOutput.text(definition.fallback))\n  value    \(HostCLIOutput.text(value(definition)))"
                )
            }
            guard !definition.readOnly else {
                throw HostCLIError.usage("\(definition.key) is read only.")
            }
            let previous = try value(definition)
            if action == "set" {
                try set(definition.parse(args.words[1]), definition: definition)
            } else {
                store(definition).removeObject(forKey: definition.key)
            }
            changed()
            if json {
                var result: [String: HostCLIJSON] = [
                    "key": .string(definition.key), "value": try value(definition),
                ]
                if action == "set" { result["previous"] = previous }
                return try HostCLIOutput.json(.object(result))
            }
            return try HostCLIOutput.text(
                "\(definition.key) = \(HostCLIOutput.text(value(definition)))")
        case "export":
            try args.require(words: 0...0, flags: ["--defaults"])
            var document: [String: HostCLIJSON] = [:]
            for definition in settings where !definition.readOnly && definition.type != .map {
                if args.flags.contains("--defaults")
                    || store(definition).object(forKey: definition.key) != nil
                {
                    document[definition.key] = try value(definition)
                }
            }
            return try HostCLIOutput.json(.object(document))
        case "import":
            try args.require(words: 1...1, flags: ["--dry-run", "--json"])
            guard args.words[0] == "-", input.count <= 256 * 1024,
                let document = try JSONDecoder().decode(HostCLIJSON.self, from: input).object
            else { throw HostCLIError.usage("Import requires a bounded JSON settings object.") }
            var applied: [String] = [], unchanged: [String] = [], skipped: [String] = []
            var pending: [(HostCLISetting, HostCLIJSON)] = []
            for key in document.keys.sorted() {
                guard let definition = settings.first(where: { $0.key == key }),
                    !definition.readOnly,
                    let raw = document[key], let coerced = try? definition.coerce(raw)
                else { skipped.append(key); continue }
                if coerced == (try value(definition)) {
                    unchanged.append(key)
                } else {
                    applied.append(key); pending.append((definition, coerced))
                }
            }
            let dryRun = args.flags.contains("--dry-run")
            if !dryRun {
                for (definition, value) in pending { try set(value, definition: definition) }
                if !pending.isEmpty { changed() }
            }
            if json {
                return try HostCLIOutput.json(
                    .object([
                        "applied": .strings(applied), "unchanged": .strings(unchanged),
                        "skipped": .strings(skipped), "dryRun": .bool(dryRun),
                    ]))
            }
            return try ExtensionCLIReply(
                stdout:
                    "\(dryRun ? "would apply" : "applied") \(applied.count) \(applied.count == 1 ? "setting" : "settings")\n",
                stderr: skipped.isEmpty ? "" : "skipped: " + skipped.joined(separator: ", ") + "\n",
                exitCode: 0)
        default: throw HostCLIError.usage("Unknown config command.")
        }
    }

    private func definition(_ key: String) throws -> HostCLISetting {
        guard let result = settings.first(where: { $0.key == key }) else {
            throw HostCLIError.usage("No setting named \(key).")
        }
        return result
    }
    private func store(_ definition: HostCLISetting) -> UserDefaults {
        definition.scope == "standard" ? standard : shared
    }
    private func value(_ definition: HostCLISetting) throws -> HostCLIJSON {
        guard let raw = store(definition).object(forKey: definition.key) else {
            return definition.fallback
        }
        let data = try JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed)
        return try definition.coerce(JSONDecoder().decode(HostCLIJSON.self, from: data))
    }
    private func set(_ value: HostCLIJSON, definition: HostCLISetting) throws {
        let data = try definition.coerce(value).encoded()
        let raw = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        store(definition).set(raw, forKey: definition.key)
    }
    private func describe(_ definition: HostCLISetting) throws -> HostCLIJSON {
        var result: [String: HostCLIJSON] = [
            "key": .string(definition.key), "type": .string(definition.type.rawValue),
            "group": .string(definition.group),
            "summary": .string(definition.summary), "scope": .string(definition.scope),
            "allowed": .strings(definition.allowed),
            "default": definition.fallback, "value": try value(definition),
            "readOnly": .bool(definition.readOnly),
            "isSet": .bool(store(definition).object(forKey: definition.key) != nil),
        ]
        if let minimum = definition.minimum, let maximum = definition.maximum {
            result["range"] = .array([.integer(minimum), .integer(maximum)])
        }
        return .object(result)
    }

    public nonisolated static let applicationSettings: [HostCLISetting] = [
        .init(
            AppStorageKeys.General.appearance, .string, group: "appearance",
            summary: "Window and panel appearance.", allowed: ["system", "light", "dark"],
            fallback: .string("system")),
        .init(
            AppStorageKeys.General.theme, .string, group: "appearance",
            summary: "Accent palette name.", fallback: .string("default")),
        .init(
            AppStorageKeys.General.lastPaletteTheme, .string, group: "appearance",
            summary: "Palette restored when a custom accent is cleared."),
        .init(
            AppStorageKeys.General.showDockIcon, .bool, group: "appearance",
            summary: "Show Edith in the Dock.", fallback: .bool(false)),
        .init(
            AppStorageKeys.General.creditHidden, .bool, group: "appearance",
            summary: "Hide the panel credit line.", fallback: .bool(false)),
        .init(
            AppStorageKeys.General.homeClockZones, .csv, group: "appearance",
            summary: "Comma separated Home clock time zones."),
        .init(
            "surfaceLayoutProfiles", .string, group: "appearance",
            summary: "Named Home and Notch layout profiles."),
        .init(
            SurfaceTarget.home.key, .string, group: "appearance",
            summary: "Home widget layout and configuration."),
        .init(
            SurfaceTarget.notch.key, .string, group: "appearance",
            summary: "Notch widget layout and configuration."),
        .init(
            AppStorageKeys.General.settingsSection, .string, group: "panel",
            summary: "Settings section a deep link opens."),
        .init(
            "extensionsExpand", .string, group: "panel",
            summary: "Extension card selected by a deep link."),
        .init(
            AppStorageKeys.General.editMainWindowFullScreen, .bool, group: "panel",
            summary: "Whether the main window opens in full screen.", scope: "standard",
            fallback: .bool(false)),
        .init(
            AppStorageKeys.General.mainWindowZoom, .number, group: "panel",
            summary: "Main window zoom factor.", fallback: .number(1)),
        .init(
            "onboardingCompleted", .bool, group: "panel",
            summary: "Whether the welcome tour is finished.", fallback: .bool(false)),
        .init(
            AppStorageKeys.General.hotKeyCode, .int, group: "panel",
            summary: "Global panel shortcut key code.", fallback: .integer(14)),
        .init(
            AppStorageKeys.General.hotKeyMods, .int, group: "panel",
            summary: "Global panel shortcut modifiers.", fallback: .integer(2304)),
        .init(
            AppStorageKeys.General.hotKeyLabel, .string, group: "panel",
            summary: "Global panel shortcut label."),
        .init(
            AppStorageKeys.General.mainWindowSection, .string, group: "panel",
            summary: "Section the main window opens on."),
        .init(
            AppStorageKeys.General.settingsTab, .string, group: "panel",
            summary: "Settings tab shown on open."),
        .init(
            AppStorageKeys.General.mainSidebarOpen, .bool, group: "panel",
            summary: "Whether the main sidebar starts open.", fallback: .bool(true)),
        .init(
            AppStorageKeys.General.mainSidebarWidth, .number, group: "panel",
            summary: "Main sidebar width in points."),
        .init(
            AppStorageKeys.General.settingsCategoriesExpanded, .bool, group: "panel",
            summary: "Whether Settings categories are expanded.", fallback: .bool(false)),
        .init(
            AppStorageKeys.Extensions.automaticUpdates, .bool, group: "panel",
            summary: "Automatically update downloaded extensions.", fallback: .bool(true)),
        .init(
            AppStorageKeys.Backup.icloud, .bool, group: "backup",
            summary: "Use iCloud for owned backups.", fallback: .bool(true)),
        .init(
            AppStorageKeys.Backup.settings, .bool, group: "backup",
            summary: "Back up application settings.", fallback: .bool(true)),
    ]
}

struct HostCLIArguments {
    var words: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]
    init(
        _ arguments: [String], flags allowedFlags: Set<String>,
        options allowedOptions: Set<String> = []
    ) throws {
        var index = 0
        var positional = false
        while index < arguments.count {
            let word = arguments[index]
            if word == "--", !positional { positional = true; index += 1; continue }
            if !positional, allowedFlags.contains(word) {
                guard flags.insert(word).inserted else {
                    throw HostCLIError.usage("Duplicate flag \(word).")
                }
            } else if !positional, allowedOptions.contains(word) {
                guard options[word] == nil, index + 1 < arguments.count else {
                    throw HostCLIError.usage("Missing or duplicate option \(word).")
                }
                index += 1; options[word] = arguments[index]
            } else if !positional, word.hasPrefix("--") {
                throw HostCLIError.usage("Unknown flag \(word).")
            } else {
                words.append(word)
            }
            index += 1
        }
    }
    func require(
        words range: ClosedRange<Int>, flags allowedFlags: Set<String> = [],
        options allowedOptions: Set<String> = []
    ) throws {
        guard range.contains(words.count), flags.isSubset(of: allowedFlags),
            Set(options.keys).isSubset(of: allowedOptions)
        else { throw HostCLIError.usage("Invalid command arguments.") }
    }
}

enum HostCLIOutput {
    static func json(_ value: HostCLIJSON) throws -> ExtensionCLIReply {
        try text(String(decoding: value.encoded(), as: UTF8.self))
    }
    static func text(_ value: String) throws -> ExtensionCLIReply {
        try ExtensionCLIReply(stdout: value + "\n", stderr: "", exitCode: 0)
    }
    static func text(_ value: HostCLIJSON) -> String {
        if value == .null { return "" }
        return value.string ?? String(decoding: (try? value.encoded()) ?? Data(), as: UTF8.self)
    }
    static func table(headers: [String], rows: [[String]]) -> String {
        let widths = headers.indices.map { index in
            (rows.map { $0[index].count } + [headers[index].count]).max() ?? 0
        }
        return ([headers] + rows).map { row in
            row.enumerated().map { index, value in
                value + String(repeating: " ", count: widths[index] - value.count)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}
