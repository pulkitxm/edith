import ArgumentParser
import EdithKit
import Foundation

struct ExtensionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extensions",
        abstract: "Turn Edith's extensions on and off.",
        subcommands: [
            ExtensionsListCommand.self, ExtensionsEnableCommand.self,
            ExtensionsDisableCommand.self, ExtensionsInfoCommand.self,
        ],
        defaultSubcommand: ExtensionsListCommand.self)
}

enum ExtensionLookup {
    static func entry(_ id: String) throws -> ExtensionRegistryEntry {
        let needle = id.lowercased()
        if let exact = ExtensionRegistry.entries.first(where: { $0.id.lowercased() == needle }) {
            return exact
        }
        if let byKey = ExtensionRegistry.entries.first(where: {
            $0.defaultsKey.lowercased() == needle
        }) {
            return byKey
        }
        throw CLIFailure.notFound(
            "no extension named \(id)",
            hint: "known ids: " + ExtensionRegistry.entries.map(\.id).joined(separator: ", "))
    }

    static func isEnabled(_ entry: ExtensionRegistryEntry) -> Bool {
        CLIEnvironment.sharedDefaults.object(forKey: entry.defaultsKey) as? Bool ?? false
    }

    static func json(_ entry: ExtensionRegistryEntry) -> JSONValue {
        let granted = PermissionsStatus.granted
        return .object([
            "id": .string(entry.id),
            "title": .string(entry.title),
            "summary": .string(entry.subtitle),
            "group": .string(entry.group.rawValue),
            "featured": .bool(entry.featured),
            "key": .string(entry.defaultsKey),
            "enabled": .bool(isEnabled(entry)),
            "requiredCapabilities": .strings(entry.requiredCapabilities.map(\.rawValue)),
            "optionalCapabilities": .strings(entry.optionalCapabilities.map(\.rawValue)),
            "requiredPermissions": .strings(entry.requiredPermissions.map(\.rawValue)),
            "optionalPermissions": .strings(entry.optionalPermissions.map(\.rawValue)),
            "missingRequiredPermissions": .strings(
                entry.requiredPermissions.filter { granted[$0] != true }.map(\.rawValue)),
            "requiredTools": .strings(entry.requiredTools.map(\.id)),
        ])
    }

    static func setEnabled(_ entry: ExtensionRegistryEntry, _ enabled: Bool) {
        CLIEnvironment.sharedDefaults.set(enabled, forKey: entry.defaultsKey)
        CLIEnvironment.sharedDefaults.synchronize()
        ConfigStore.announceChange()
    }
}

struct ExtensionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List extensions and whether they are on.",
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        guard !json else {
            CLIOut.json(.array(ExtensionRegistry.entries.map(ExtensionLookup.json)))
            return
        }
        let rows = ExtensionRegistry.entries.map { entry in
            [
                entry.id, ExtensionLookup.isEnabled(entry) ? "on" : "off",
                entry.group.rawValue, entry.title,
            ]
        }
        CLIOut.out(TextTable.render(headers: ["ID", "STATE", "GROUP", "NAME"], rows: rows))
    }
}

struct ExtensionsEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable", abstract: "Turn an extension on.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The extension id.")
    var id: String

    func run() async throws {
        try await execute {
            let entry = try ExtensionLookup.entry(id)
            ExtensionLookup.setEnabled(entry, true)
            let granted = PermissionsStatus.granted
            let missing = entry.requiredPermissions.filter { granted[$0] != true }
            guard !json else {
                CLIOut.json(ExtensionLookup.json(entry))
                return
            }
            CLIOut.out("\(entry.id) enabled")
            for permission in missing {
                CLIOut.note(
                    "note: \(entry.title) needs \(permission.displayName); "
                        + "run `ed permissions request \(permission.rawValue)`")
            }
        }
    }
}

struct ExtensionsDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable", abstract: "Turn an extension off.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The extension id.")
    var id: String

    func run() async throws {
        try await execute {
            let entry = try ExtensionLookup.entry(id)
            ExtensionLookup.setEnabled(entry, false)
            guard !json else {
                CLIOut.json(ExtensionLookup.json(entry))
                return
            }
            CLIOut.out("\(entry.id) disabled")
        }
    }
}

struct ExtensionsInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info", abstract: "Describe one extension.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The extension id.")
    var id: String

    func run() async throws {
        try await execute {
            let entry = try ExtensionLookup.entry(id)
            guard !json else {
                CLIOut.json(ExtensionLookup.json(entry))
                return
            }
            CLIOut.out(entry.title)
            CLIOut.out("  " + entry.subtitle)
            CLIOut.out("  id       \(entry.id)")
            CLIOut.out("  key      \(entry.defaultsKey)")
            CLIOut.out("  group    \(entry.group.rawValue)")
            CLIOut.out("  state    \(ExtensionLookup.isEnabled(entry) ? "on" : "off")")
            if !entry.requiredPermissions.isEmpty {
                CLIOut.out(
                    "  needs    "
                        + entry.requiredPermissions.map(\.displayName).joined(separator: ", "))
            }
            if !entry.optionalPermissions.isEmpty {
                CLIOut.out(
                    "  asks for "
                        + entry.optionalPermissions.map(\.displayName).joined(separator: ", "))
            }
        }
    }
}
