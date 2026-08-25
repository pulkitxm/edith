import ArgumentParser
import EdithKit
import Foundation

enum FileOps {
    private struct RemoteCommandFailure: LocalizedError {
        let detail: String

        var errorDescription: String? { detail }
    }

    static func sharedRun(_ runner: RemoteRunner) -> MachineFileOperationExecution.Run {
        { command, timeout in
            do {
                let result = try await runner.run(command, timeout: timeout)
                guard result.succeeded else {
                    let detail = result.combinedText.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    return .failure(RemoteCommandFailure(detail: detail))
                }
                return .success(result.stdoutText)
            } catch {
                return .failure(error)
            }
        }
    }

    static func resolved<Value>(
        _ result: Result<Value, Error>, failure: String
    ) throws -> Value {
        switch result {
        case let .success(value): return value
        case let .failure(error):
            if let failure = error as? CLIFailure { throw failure }
            throw CLIFailure(failure, hint: error.localizedDescription)
        }
    }

    static func run(_ command: String, machine name: String, describing what: String) async throws
        -> Machine
    {
        let runner = try await MachineResolver.runner(name)
        let result = try await runner.run(command, timeout: 300)
        let detail = result.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded else {
            throw CLIFailure(
                "\(what) failed on \(runner.machine.name)" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return runner.machine
    }
}

enum WithinMachineTransferCLI {
    static func run(
        moving: Bool, machine: String, sources: [String], destination: String,
        dryRun: Bool, replace: Bool, yes: Bool, json: Bool
    ) async throws {
        guard DropResolver.isDropAllowed(paths: sources, destination: destination) else {
            throw CLIFailure("the destination cannot be a source, its parent or its descendant")
        }
        let target = try await CLIEnvironment.remoteDirectoryTarget(machine)
        let existing = try await target.endpoint.list(destination)
        let plan = RemoteTransferOperationExecution.plan(
            paths: sources, destination: destination, existing: existing,
            resolution: RemoteTransferCLI.resolution(replace: replace))
        let confirmationMissing = replace && !yes && !plan.replacements.isEmpty
        let operation =
            moving
            ? RemoteTransferOperation.moveWithinMachine.descriptor.id
            : RemoteTransferOperation.copyWithinMachine.descriptor.id
        let verb = moving ? "move" : "copy"
        if RemoteTransferCLI.shouldPreview(
            plan, dryRun: dryRun, replace: replace, yes: yes)
        {
            RemoteTransferCLI.reportPlan(
                operation: operation, verb: verb, source: target.machine.name,
                destinationMachine: target.machine.name, plan: plan, dryRun: dryRun,
                confirmationMissing: confirmationMissing, json: json)
            return
        }
        guard
            let command = RemoteTransferOperationExecution.withinMachineCommand(
                plan, moving: moving)
        else { return }
        let applied = try await FileOps.run(
            command, machine: machine, describing: "\(verb) \(sources.count) item(s)")
        RemoteTransferCLI.reportApplied(
            operation: operation, completedVerb: moving ? "moved" : "copied",
            machine: applied.name, plan: plan, json: json)
    }
}

struct MachinesFilesCopyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp", abstract: "Copy files into a directory on the machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Show the resolved destinations without copying.")
    var dryRun = false

    @Flag(help: "Replace destination items with matching names.")
    var replace = false

    @Flag(help: "Confirm replacement requested with --replace.")
    var yes = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Paths to copy, then the destination directory last.")
    var paths: [String]

    func run() async throws {
        try await execute {
            guard paths.count >= 2 else {
                throw CLIFailure("give at least one source and a destination directory")
            }
            let destination = paths[paths.count - 1]
            let sources = Array(paths.dropLast())
            try await WithinMachineTransferCLI.run(
                moving: false, machine: machine, sources: sources, destination: destination,
                dryRun: dryRun, replace: replace, yes: yes, json: json)
        }
    }
}

struct MachinesFilesMoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mv", abstract: "Move files into a directory on the machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Show the resolved destinations without moving.")
    var dryRun = false

    @Flag(help: "Replace destination items with matching names.")
    var replace = false

    @Flag(help: "Confirm replacement requested with --replace.")
    var yes = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Paths to move, then the destination directory last.")
    var paths: [String]

    func run() async throws {
        try await execute {
            guard paths.count >= 2 else {
                throw CLIFailure("give at least one source and a destination directory")
            }
            let destination = paths[paths.count - 1]
            let sources = Array(paths.dropLast())
            try await WithinMachineTransferCLI.run(
                moving: true, machine: machine, sources: sources, destination: destination,
                dryRun: dryRun, replace: replace, yes: yes, json: json)
        }
    }
}

struct MachinesFilesRenameCommand: AsyncParsableCommand {
    static let operation = MachineFileOperation.rename

    static let configuration = CommandConfiguration(
        commandName: "rename", abstract: "Rename one file on the machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The path to rename.")
    var path: String

    @Argument(help: "The new name, without a directory.")
    var name: String

    func run() async throws {
        try await execute {
            let runner = try await MachineResolver.runner(machine)
            let result = await MachineFileOperationExecution.rename(path: path, name: name) {
                await FileOps.sharedRun(runner)($0, $1)
            }
            let target = try FileOps.resolved(
                result, failure: "could not rename \(path) on \(runner.machine.name)")
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name), "done": .bool(true),
                        "path": .string(path), "to": .string(target),
                    ]))
                return
            }
            CLIOut.out("renamed to \(target)")
        }
    }
}

struct MachinesFilesMakeDirectoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mkdir", abstract: "Make a directory on the machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The directory to make.")
    var path: String

    func run() async throws {
        try await execute {
            let target = try await CLIEnvironment.remoteDirectoryTarget(machine)
            let creation: RemoteDirectoryCreation
            do {
                creation = try await RemoteDirectoryOperationExecution.create(
                    path: path, using: target.endpoint)
            } catch {
                throw CLIFailure(
                    "made \(path) failed on \(target.machine.name): \(error.localizedDescription)")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "done": .bool(true),
                        "machine": .string(creation.machineName),
                        "path": .string(creation.path),
                    ]))
                return
            }
            CLIOut.out("made \(creation.path)")
        }
    }
}

struct MachinesFilesRemoveCommand: AsyncParsableCommand {
    static let operation = MachineFileOperation.remove

    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Move files to the machine's trash, or delete them outright.",
        discussion: """
            Without `--delete` this moves the files to the machine's own trash, the same as
            the Finder window does, so they can be put back. `--delete` removes them for
            good and needs `--yes`.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Delete outright rather than moving to the trash.")
    var delete = false

    @Flag(help: "Actually do it. Required with --delete.")
    var yes = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Paths to remove.")
    var paths: [String]

    func run() async throws {
        try await execute {
            let plan = MachineFileRemovalPlan(paths: paths, permanently: delete)
            guard !plan.paths.isEmpty else { throw CLIFailure("name at least one path") }
            guard !plan.requiresConfirmation || yes else {
                guard !json else {
                    CLIOut.json(
                        .object(["paths": .strings(plan.paths), "deleted": .bool(false)]))
                    return
                }
                CLIOut.out("would delete \(plan.paths.count) path(s) for good")
                CLIOut.note("nothing was deleted; pass --yes to go ahead")
                return
            }
            let runner = try await MachineResolver.runner(machine)
            let result = await MachineFileOperationExecution.remove(plan, confirmed: yes) {
                await FileOps.sharedRun(runner)($0, $1)
            }
            _ = try FileOps.resolved(
                result,
                failure:
                    "could not \(delete ? "delete" : "trash") paths on \(runner.machine.name)")
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name), "done": .bool(true),
                        "paths": .strings(plan.paths), "deleted": .bool(delete),
                    ]))
                return
            }
            CLIOut.out(
                delete
                    ? "deleted \(plan.paths.count) path(s)"
                    : "trashed \(plan.paths.count) path(s)")
        }
    }
}

struct MachinesFilesSearchCommand: AsyncParsableCommand {
    static let operation = MachineFileOperation.search

    static let configuration = CommandConfiguration(
        commandName: "search", abstract: "Find files under a directory by name.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Stop after this many matches.")
    var limit: Int = 300

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Directory to search under.")
    var path: String

    @Argument(help: "Text to look for in the file name.")
    var query: String

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let runner = try await MachineResolver.runner(machine)
            let result = await MachineFileOperationExecution.search(
                path: path, query: query, limit: limit
            ) { await FileOps.sharedRun(runner)($0, $1) }
            let hits = try FileOps.resolved(
                result, failure: "could not search \(path) on \(runner.machine.name)"
            ).map(\.path)
            guard !json else {
                CLIOut.json(.strings(hits))
                return
            }
            guard !hits.isEmpty else {
                CLIOut.note("nothing under \(path) matches \(query)")
                return
            }
            for hit in hits { CLIOut.out(hit) }
        }
    }
}

struct MachinesFilesInfoCommand: AsyncParsableCommand {
    static let operation = MachineFileOperation.info

    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "How big something is on the machine, directories included.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The path to measure.")
    var path: String

    func run() async throws {
        try await execute {
            let runner = try await MachineResolver.runner(machine)
            let result = await MachineFileOperationExecution.info(path: path) {
                await FileOps.sharedRun(runner)($0, $1)
            }
            let bytes = try FileOps.resolved(
                result, failure: "could not measure \(path) on \(runner.machine.name)")
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "path": .string(path),
                        "sizeBytes": .int(Int(clamping: bytes)),
                    ]))
                return
            }
            CLIOut.out(
                "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
                    + "  \(path)")
        }
    }
}

struct MachinesFilesDuplicateCommand: AsyncParsableCommand {
    static let operation = MachineFileOperation.duplicate

    static let configuration = CommandConfiguration(
        commandName: "duplicate",
        abstract: "Copy a file beside itself, the way the Finder window does.",
        discussion: """
            The copy is named the way the window names it: `report copy`, then
            `report copy 2`, keeping any extension, so duplicating twice never overwrites
            the first one.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The path to duplicate.")
    var path: String

    func run() async throws {
        try await execute {
            let runner = try await MachineResolver.runner(machine)
            let result = await MachineFileOperationExecution.duplicate(path: path) {
                await FileOps.sharedRun(runner)($0, $1)
            }
            let created = try FileOps.resolved(
                result, failure: "could not duplicate \(path) on \(runner.machine.name)")
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "path": .string(path), "to": .string(created),
                    ]))
                return
            }
            CLIOut.out("duplicated to \(created)")
        }
    }
}

struct MachinesFilesUndoCommand: AsyncParsableCommand {
    static let operation = MachineFileOperation.undo

    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Undo the last move or rename a Finder window made.",
        discussion: """
            The undo history belongs to an open Finder window and lives in memory, so it
            cannot be reached from a file on disk. `ed` asks the window to undo, and says
            to open one when there is none: without a window there is nothing to undo.

            A move or rename made by `ed` itself is not on that history. Reverse it with
            `ed machines files mv` or `rename`, which is the same thing the window would
            have run.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let target = try MachineResolver.machine(machine)
            guard AppBridge.mainAppIsRunning else {
                throw CLIFailure.unavailable(
                    "the undo history lives in an open Finder window, and Edith is not running",
                    hint: "open Edith and its Files window for \(target.name), then retry")
            }
            let reply = await AppBridge.awaitReply(IPC.Name.finderUndoResult, timeout: 20) {
                AppBridge.post(
                    IPC.Name.requestFinderUndo,
                    userInfo: ["machine": target.id.uuidString])
            }
            guard let reply else {
                throw AppBridge.silence("undoing a file change")
            }
            let undone = reply["undone"] as? Bool ?? false
            guard undone else {
                throw CLIFailure.unavailable(
                    "no Finder window for \(target.name) has anything to undo",
                    hint: "open one with the Files tab, or reverse it with "
                        + "`ed machines files mv`")
            }
            let label = reply["label"] as? String ?? "the last change"
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(target.name), "undone": .bool(true),
                        "what": .string(label),
                    ]))
                return
            }
            CLIOut.out("undid \(label) on \(target.name)")
        }
    }
}
