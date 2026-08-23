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

    static func json(_ entry: ExtensionRegistryEntry, includeLifecycle: Bool = false) -> JSONValue {
        let granted = PermissionsStatus.granted
        var fields: [String: JSONValue] = [
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
        ]
        if includeLifecycle, let lifecycle = entry.lifecycle {
            fields["lifecycle"] = lifecycleJSON(lifecycle)
            fields["state"] = stateJSON(lifecycleState(entry))
        }
        return .object(fields)
    }

    static func lifecycleState(_ entry: ExtensionRegistryEntry) -> ExtensionLifecycleState {
        guard isEnabled(entry) else {
            return .preference(extensionID: entry.id, enabled: false)
        }
        let granted = PermissionsStatus.granted
        var issues = entry.requiredPermissions.filter { granted[$0] != true }.map { permission in
            ExtensionLifecycleIssue(
                id: "missing-permission.\(permission.rawValue)",
                title: "Grant \(permission.displayName)", detail: permission.reason,
                recoveryCommand: "ed permissions request \(permission.rawValue)")
        }
        if entry.requiredTools.count == 1, let tool = entry.requiredTools.first,
            ToolsBridge.found(tool) == nil
        {
            issues.append(
                ExtensionLifecycleIssue(
                    id: "missing-tool.\(tool.id)", title: "Install \(tool.displayName)",
                    detail: tool.why, recoveryCommand: "ed tools install \(tool.id)"))
        }
        guard !issues.isEmpty else {
            return .preference(extensionID: entry.id, enabled: true)
        }
        return ExtensionLifecycleState(
            extensionID: entry.id, phase: .needsSetup,
            summary: "Enabled, but setup is incomplete.", issues: issues)
    }

    private static func lifecycleJSON(_ lifecycle: ExtensionLifecycleDescriptor) -> JSONValue {
        .object([
            "id": .string(lifecycle.id),
            "value": .string(lifecycle.value),
            "workflows": .array(lifecycle.workflows.map(instructionJSON)),
            "prerequisites": .array(lifecycle.prerequisites.map(instructionJSON)),
            "cliExamples": .strings(lifecycle.cliExamples),
            "documentation": .array(
                lifecycle.documentation.map { document in
                    .object([
                        "id": .string(document.id), "title": .string(document.title),
                        "path": .string(document.path),
                    ])
                }),
            "recovery": .array(lifecycle.recovery.map(instructionJSON)),
            "verification": .array(lifecycle.verification.map(instructionJSON)),
        ])
    }

    private static func instructionJSON(_ instruction: ExtensionLifecycleInstruction) -> JSONValue {
        .object([
            "id": .string(instruction.id), "title": .string(instruction.title),
            "detail": .string(instruction.detail), "command": .optional(instruction.command),
        ])
    }

    private static func stateJSON(_ state: ExtensionLifecycleState) -> JSONValue {
        .object([
            "extensionID": .string(state.extensionID), "phase": .string(state.phase.rawValue),
            "summary": .string(state.summary),
            "issues": .array(
                state.issues.map { issue in
                    .object([
                        "id": .string(issue.id), "title": .string(issue.title),
                        "detail": .string(issue.detail),
                        "recoveryCommand": .optional(issue.recoveryCommand),
                    ])
                }),
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
            CLIOut.json(.array(ExtensionRegistry.entries.map { ExtensionLookup.json($0) }))
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
                CLIOut.json(ExtensionLookup.json(entry, includeLifecycle: true))
                return
            }
            let lifecycle = entry.lifecycle
            let state = ExtensionLookup.lifecycleState(entry)
            CLIOut.out(entry.title)
            CLIOut.out("  " + (lifecycle?.value ?? entry.subtitle))
            CLIOut.out("  id       \(entry.id)")
            CLIOut.out("  key      \(entry.defaultsKey)")
            CLIOut.out("  group    \(entry.group.rawValue)")
            CLIOut.out("  state    \(state.phase.title)")
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
            if let lifecycle {
                CLIOut.out("  workflows")
                for workflow in lifecycle.workflows {
                    CLIOut.out("    \(workflow.title): \(workflow.detail)")
                }
                CLIOut.out("  setup")
                for prerequisite in lifecycle.prerequisites {
                    CLIOut.out("    \(prerequisite.title): \(prerequisite.detail)")
                }
                CLIOut.out("  verify")
                for verification in lifecycle.verification {
                    CLIOut.out("    \(verification.command ?? verification.detail)")
                }
                CLIOut.out(
                    "  docs     " + lifecycle.documentation.map(\.path).joined(separator: ", "))
            }
        }
    }
}
