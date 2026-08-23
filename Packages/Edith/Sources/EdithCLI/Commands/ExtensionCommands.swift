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
            ExtensionsStatusCommand.self, ExtensionsSetupCommand.self,
            ExtensionsVerifyCommand.self, ExtensionsDoctorCommand.self,
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
        entry.isEnabled(in: CLIEnvironment.sharedDefaults)
    }

    static func json(
        _ entry: ExtensionRegistryEntry, report: ExtensionLifecycleReport? = nil
    ) -> JSONValue {
        let granted = grantedPermissions()
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
            "optionalTools": .strings(entry.optionalTools.map(\.id)),
        ]
        if let report, let lifecycle = entry.lifecycle {
            fields["lifecycle"] = lifecycleJSON(lifecycle)
            fields["state"] = stateJSON(report.state)
            fields["checks"] = checksJSON(report.checks)
            fields["verified"] = .bool(report.verified)
        }
        return .object(fields)
    }

    static func probe() -> ExtensionLifecycleProbe {
        var environment = ExtensionLifecycleProbeEnvironment.live
        environment.isEnabled = { entry in isEnabled(entry) }
        environment.grantedPermissions = { grantedPermissions() }
        environment.toolReadiness = CLIEnvironment.extensionToolReadiness
        environment.helperRunning = CLIEnvironment.isHelperRunning
        let liveAdapters = ExtensionLiveAdapters.provider(
            defaults: CLIEnvironment.sharedDefaults,
            executableNamed: CLIEnvironment.executableNamed)
        let existingAdapters = environment.adapterReadiness
        environment.adapterReadiness = { id in
            if let readiness = await liveAdapters(id) { return readiness }
            return await existingAdapters(id)
        }
        return ExtensionLifecycleProbe(environment: environment)
    }

    static func grantedPermissions() -> [ExtensionPermission: Bool] {
        ExtensionPermission.allCases.reduce(into: [:]) { result, permission in
            guard let key = permission.grantedDefaultsKey else {
                result[permission] = false
                return
            }
            result[permission] = CLIEnvironment.sharedDefaults.bool(forKey: key)
        }
    }

    static func mutationCenter() -> ExtensionMutationCenter {
        let toolPresent: @Sendable (String) -> Bool = { id in
            guard let tool = ToolProvisioning.spec(id: id),
                case let .executable(name, _) = tool.presenceStrategy
            else { return false }
            return CLIEnvironment.executableNamed(name) != nil
        }
        return ExtensionMutationCenter(
            environment: ExtensionMutationEnvironment(
                defaults: CLIEnvironment.sharedDefaults,
                announceChange: { ConfigStore.announceChange() },
                grantedPermissions: { grantedPermissions() },
                toolPresent: toolPresent,
                installTool: { tool, log in try await CLIEnvironment.installTool(tool, log) },
                lifecycle: probe().environment))
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

    static func reportJSON(
        _ entry: ExtensionRegistryEntry, _ report: ExtensionLifecycleReport
    ) -> JSONValue {
        .object([
            "id": .string(entry.id), "title": .string(entry.title),
            "verified": .bool(report.verified), "state": stateJSON(report.state),
            "checks": checksJSON(report.checks),
            "remediation": .strings(report.state.issues.compactMap(\.recoveryCommand)),
        ])
    }

    private static func stateJSON(_ state: ExtensionLifecycleState) -> JSONValue {
        .object([
            "extensionID": .string(state.extensionID), "phase": .string(state.phase.rawValue),
            "runtimePhase": .string(state.runtimePhase.rawValue),
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

    private static func checksJSON(_ checks: [ExtensionLifecycleCheck]) -> JSONValue {
        .array(
            checks.map { check in
                .object([
                    "id": .string(check.id), "title": .string(check.title),
                    "status": .string(check.status.rawValue), "detail": .string(check.detail),
                    "runtimePhase": .optional(check.runtimePhase?.rawValue),
                    "recoveryCommand": .optional(check.recoveryCommand),
                ])
            })
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
            let result = ExtensionLookup.mutationCenter().setEnabled(true, for: entry)
            guard !json else {
                CLIOut.json(ExtensionLookup.json(entry))
                return
            }
            CLIOut.out("\(entry.id) enabled")
            for permission in result.missingRequiredPermissions {
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
            _ = ExtensionLookup.mutationCenter().setEnabled(false, for: entry)
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
            let report = await ExtensionLookup.probe().report(for: entry)
            guard !json else {
                CLIOut.json(ExtensionLookup.json(entry, report: report))
                return
            }
            let lifecycle = entry.lifecycle
            CLIOut.out(entry.title)
            CLIOut.out("  " + (lifecycle?.value ?? entry.subtitle))
            CLIOut.out("  id       \(entry.id)")
            CLIOut.out("  key      \(entry.defaultsKey)")
            CLIOut.out("  group    \(entry.group.rawValue)")
            CLIOut.out("  state    \(report.state.phase.title)")
            CLIOut.out("  runtime  \(report.state.runtimePhase.title)")
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

struct ExtensionsStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Check extension readiness.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "An optional extension id.")
    var id: String?

    func run() async throws {
        try await execute {
            let entries = try selectedEntries(id)
            let reports = await ExtensionLookup.probe().reports(for: entries)
            guard !json else {
                let values = zip(entries, reports).map(ExtensionLookup.reportJSON)
                CLIOut.json(id == nil ? .array(values) : values[0])
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "READINESS", "RUNTIME", "DETAIL"],
                    rows: zip(entries, reports).map { entry, report in
                        [
                            entry.id, report.state.phase.title, report.state.runtimePhase.title,
                            report.state.summary,
                        ]
                    }))
        }
    }
}

struct ExtensionsSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup", abstract: "Enable an extension and report remaining setup.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Show the projected result without changing settings.")
    var dryRun = false

    @Flag(name: .long, help: "Install missing required tools without prompting.")
    var installTools = false

    @Argument(help: "The extension id.")
    var id: String

    func run() async throws {
        try await execute {
            let entry = try ExtensionLookup.entry(id)
            let result = await ExtensionLookup.mutationCenter().setup(
                entry, dryRun: dryRun, installTools: installTools,
                log: { line in if !json { CLIOut.note(line) } })
            guard !json else {
                CLIOut.json(
                    .object([
                        "id": .string(entry.id), "dryRun": .bool(dryRun),
                        "changed": .bool(result.changed),
                        "plannedTools": .strings(result.tools.planned),
                        "installedTools": .strings(result.tools.installed),
                        "installFailures": .array(
                            result.tools.failures.map { failure in
                                .object([
                                    "id": .string(failure.id),
                                    "detail": .string(failure.detail),
                                ])
                            }),
                        "report": ExtensionLookup.reportJSON(entry, result.report),
                    ]))
                return
            }
            CLIOut.out(
                dryRun
                    ? "would enable \(entry.id)"
                    : result.changed ? "\(entry.id) enabled" : "\(entry.id) already enabled")
            printReport(entry, result.report)
            for failure in result.tools.failures {
                CLIOut.note("could not install \(failure.id): \(failure.detail)")
            }
        }
    }
}

struct ExtensionsVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify", abstract: "Run every readiness check for one extension.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The extension id.")
    var id: String

    func run() async throws {
        try await execute {
            let entry = try ExtensionLookup.entry(id)
            let report = await ExtensionLookup.probe().report(for: entry)
            guard !json else {
                CLIOut.json(ExtensionLookup.reportJSON(entry, report))
                return
            }
            printReport(entry, report)
        }
    }
}

struct ExtensionsDoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Diagnose extension setup and runtime problems.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "An optional extension id.")
    var id: String?

    func run() async throws {
        try await execute {
            let entries = try selectedEntries(id)
            let reports = await ExtensionLookup.probe().reports(for: entries)
            guard !json else {
                let values = zip(entries, reports).map(ExtensionLookup.reportJSON)
                CLIOut.json(id == nil ? .array(values) : values[0])
                return
            }
            for (entry, report) in zip(entries, reports) {
                printReport(entry, report)
            }
        }
    }
}

private func selectedEntries(_ id: String?) throws -> [ExtensionRegistryEntry] {
    if let id { return [try ExtensionLookup.entry(id)] }
    return ExtensionRegistry.entries
}

private func printReport(_ entry: ExtensionRegistryEntry, _ report: ExtensionLifecycleReport) {
    CLIOut.out(
        "\(entry.id)  \(report.state.phase.title)  \(report.state.runtimePhase.title)  "
            + report.state.summary)
    for check in report.checks {
        CLIOut.out("  \(check.status.rawValue)  \(check.title): \(check.detail)")
        if let recovery = check.recoveryCommand { CLIOut.out("    \(recovery)") }
    }
}
