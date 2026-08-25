import ArgumentParser
import EdithCore
import EdithKit
import Foundation

struct CLITransferTarget: Sendable {
    let machine: Machine
    let endpoint: RemoteTransferEndpoint
}

enum RemoteTransferCLI {
    static func resolution(replace: Bool) -> NameConflictResolution {
        replace ? .replace : .keepBoth
    }

    static func shouldPreview(
        _ plan: RemoteTransferPlan, dryRun: Bool, replace: Bool, yes: Bool
    ) -> Bool {
        dryRun || (replace && !yes && !plan.replacements.isEmpty)
    }

    static func reportPlan(
        operation: UserOperationID, verb: String, source: String,
        destinationMachine: String?,
        plan: RemoteTransferPlan, dryRun: Bool, confirmationMissing: Bool, json: Bool
    ) {
        guard !json else {
            CLIOut.json(
                .object([
                    "operation": .string(operation.rawValue),
                    "sourceMachine": .string(source),
                    "destinationMachine": .optional(destinationMachine),
                    "destination": .string(plan.destination),
                    "dryRun": .bool(dryRun),
                    "executed": .bool(false),
                    "requiresConfirmation": .bool(confirmationMissing),
                    "items": .array(plan.items.map(planItem)),
                    "skipped": .strings(plan.skipped),
                ]))
            return
        }
        CLIOut.out(
            dryRun
                ? "would \(verb) \(plan.items.count) item(s)"
                : "replacement confirmation is required")
        for item in plan.items {
            CLIOut.out(
                "  \(item.sourcePath) -> \(item.destinationPath)"
                    + (item.replacesExisting ? "  replace" : ""))
        }
        if confirmationMissing {
            CLIOut.note("nothing was transferred; pass --yes with --replace to go ahead")
        }
    }

    static func reportOutcome(
        operation: UserOperationID, completedVerb: String, source: String,
        destinationMachine: String?,
        plan: RemoteTransferPlan, outcome: RemoteTransferOutcome, json: Bool
    ) throws {
        guard !json else {
            CLIOut.json(
                .object([
                    "operation": .string(operation.rawValue),
                    "sourceMachine": .string(source),
                    "destinationMachine": .optional(destinationMachine),
                    "destination": .string(plan.destination),
                    "dryRun": .bool(false),
                    "executed": .bool(true),
                    "requiresConfirmation": .bool(false),
                    "items": .array(plan.items.map(planItem)),
                    "skipped": .strings(plan.skipped),
                    "completed": .array(outcome.completed.map(planItem)),
                    "failures": .array(
                        outcome.failures.map {
                            .object([
                                "source": .string($0.sourcePath),
                                "destination": .string($0.destination),
                                "message": .string($0.message),
                            ])
                        }),
                ]))
            if !outcome.failures.isEmpty { throw ExitCode.failure }
            return
        }
        CLIOut.out("\(completedVerb) \(outcome.completed.count) item(s)")
        for failure in outcome.failures {
            CLIOut.note(
                "\(failure.sourcePath) -> \(failure.destination): \(failure.message)")
        }
        if !outcome.failures.isEmpty { throw ExitCode.failure }
    }

    static func reportApplied(
        operation: UserOperationID, completedVerb: String, machine: String,
        plan: RemoteTransferPlan, json: Bool
    ) {
        guard !json else {
            CLIOut.json(
                .object([
                    "operation": .string(operation.rawValue),
                    "machine": .string(machine),
                    "destination": .string(plan.destination),
                    "dryRun": .bool(false),
                    "executed": .bool(true),
                    "requiresConfirmation": .bool(false),
                    "items": .array(plan.items.map(planItem)),
                    "skipped": .strings(plan.skipped),
                ]))
            return
        }
        CLIOut.out("\(completedVerb) \(plan.items.count) item(s)")
        for item in plan.items {
            CLIOut.out("  \(item.sourcePath) -> \(item.destinationPath)")
        }
    }

    private static func planItem(_ item: RemoteTransferPlanItem) -> JSONValue {
        .object([
            "source": .string(item.sourcePath),
            "destination": .string(item.destinationPath),
            "replacesExisting": .bool(item.replacesExisting),
        ])
    }
}

struct MachineFilesGetManyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get-many",
        abstract: "Download multiple files from a machine.",
        discussion: """
            Existing names are kept by adding a number. Pass --replace to preview
            replacement, then add --yes to confirm it.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Show the resolved destinations without downloading.")
    var dryRun = false

    @Flag(help: "Replace destination items with matching names.")
    var replace = false

    @Flag(help: "Confirm replacement requested with --replace.")
    var yes = false

    @Option(help: "Local destination directory.")
    var to: String = "."

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Remote file paths.")
    var paths: [String]

    func run() async throws {
        try await execute {
            guard !paths.isEmpty else { throw CLIFailure("name at least one remote file") }
            let destination = URL(fileURLWithPath: to.expandingTilde()).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue
            else {
                throw CLIFailure.notFound(
                    "no destination directory at \(destination.path)")
            }
            let source = try await CLIEnvironment.remoteTransferTarget(machine)
            let local = RemoteTransferEndpoint.local(
                machineID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                name: "This Mac")
            let existing = try await local.list(destination.path)
            let plan = RemoteTransferOperationExecution.plan(
                paths: paths, destination: destination.path, existing: existing,
                resolution: RemoteTransferCLI.resolution(replace: replace))
            let confirmationMissing = replace && !yes && !plan.replacements.isEmpty
            if RemoteTransferCLI.shouldPreview(
                plan, dryRun: dryRun, replace: replace, yes: yes)
            {
                RemoteTransferCLI.reportPlan(
                    operation: RemoteTransferOperation.downloadSelection.descriptor.id,
                    verb: "download", source: source.machine.name,
                    destinationMachine: nil, plan: plan, dryRun: dryRun,
                    confirmationMissing: confirmationMissing, json: json)
                return
            }
            let progress = CLIProgress.forCommand(json: json)
            progress.begin("downloading \(plan.items.count) item(s)")
            let outcome: RemoteTransferOutcome
            do {
                outcome = try await RemoteTransferOperationExecution.execute(
                    plan, from: source.endpoint, to: local,
                    confirmsReplacement: replace && yes
                ) { processed, total in
                    progress.update("processed \(processed) of \(total)")
                }
            } catch {
                progress.end()
                throw error
            }
            progress.end()
            try RemoteTransferCLI.reportOutcome(
                operation: RemoteTransferOperation.downloadSelection.descriptor.id,
                completedVerb: "downloaded",
                source: source.machine.name,
                destinationMachine: nil, plan: plan, outcome: outcome, json: json)
        }
    }
}

struct MachineFilesTransferCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transfer",
        abstract: "Transfer files between two machines.",
        discussion: """
            Existing names are kept by adding a number. Pass --replace to preview
            replacement, then add --yes to confirm it.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Show the resolved destinations without transferring.")
    var dryRun = false

    @Flag(help: "Replace destination items with matching names.")
    var replace = false

    @Flag(help: "Confirm replacement requested with --replace.")
    var yes = false

    @Option(help: "Directory on the destination machine.")
    var into: String

    @Argument(help: "Source machine name, ssh alias or id.")
    var source: String

    @Argument(help: "Destination machine name, ssh alias or id.")
    var destination: String

    @Argument(help: "Paths on the source machine.")
    var paths: [String]

    func run() async throws {
        try await execute {
            guard !paths.isEmpty else { throw CLIFailure("name at least one source file") }
            async let sourcePending = CLIEnvironment.remoteTransferTarget(source)
            async let destinationPending = CLIEnvironment.remoteTransferTarget(destination)
            let (sourceTarget, destinationTarget) =
                try await (sourcePending, destinationPending)
            guard sourceTarget.machine.id != destinationTarget.machine.id else {
                throw CLIFailure(
                    "source and destination are the same machine",
                    hint: "use ed machines files cp for a copy on one machine")
            }
            let existing = try await destinationTarget.endpoint.list(into)
            let plan = RemoteTransferOperationExecution.plan(
                paths: paths, destination: into, existing: existing,
                resolution: RemoteTransferCLI.resolution(replace: replace))
            let confirmationMissing = replace && !yes && !plan.replacements.isEmpty
            if RemoteTransferCLI.shouldPreview(
                plan, dryRun: dryRun, replace: replace, yes: yes)
            {
                RemoteTransferCLI.reportPlan(
                    operation: RemoteTransferOperation.transferBetweenMachines.descriptor.id,
                    verb: "transfer",
                    source: sourceTarget.machine.name,
                    destinationMachine: destinationTarget.machine.name, plan: plan,
                    dryRun: dryRun, confirmationMissing: confirmationMissing, json: json)
                return
            }
            let progress = CLIProgress.forCommand(json: json)
            progress.begin("transferring \(plan.items.count) item(s)")
            let outcome: RemoteTransferOutcome
            do {
                outcome = try await RemoteTransferOperationExecution.execute(
                    plan, from: sourceTarget.endpoint, to: destinationTarget.endpoint,
                    confirmsReplacement: replace && yes
                ) { processed, total in
                    progress.update("processed \(processed) of \(total)")
                }
            } catch {
                progress.end()
                throw error
            }
            progress.end()
            try RemoteTransferCLI.reportOutcome(
                operation: RemoteTransferOperation.transferBetweenMachines.descriptor.id,
                completedVerb: "transferred",
                source: sourceTarget.machine.name,
                destinationMachine: destinationTarget.machine.name, plan: plan,
                outcome: outcome, json: json)
        }
    }
}
