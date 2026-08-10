import ArgumentParser
import EdithKit
import Foundation

enum FileOps {
    static func apply(
        _ command: String, machine name: String, describing what: String, json: Bool,
        fields: [String: JSONValue]
    ) async throws {
        let runner = try await MachineResolver.runner(name)
        let result = try await runner.run(command, timeout: 300)
        let detail = result.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded else {
            throw CLIFailure(
                "\(what) failed on \(runner.machine.name)" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        guard !json else {
            var payload = fields
            payload["machine"] = .string(runner.machine.name)
            payload["done"] = .bool(true)
            CLIOut.json(.object(payload))
            return
        }
        CLIOut.out(what)
    }
}

struct MachinesFilesCopyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp", abstract: "Copy files into a directory on the machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

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
            try await FileOps.apply(
                FileOperations.copyCommand(paths: sources, toDirectory: destination),
                machine: machine,
                describing: "copied \(sources.count) into \(destination)", json: json,
                fields: ["copied": .strings(sources), "into": .string(destination)])
        }
    }
}

struct MachinesFilesMoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mv", abstract: "Move files into a directory on the machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

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
            try await FileOps.apply(
                FileOperations.moveCommand(paths: sources, toDirectory: destination),
                machine: machine,
                describing: "moved \(sources.count) into \(destination)", json: json,
                fields: ["moved": .strings(sources), "into": .string(destination)])
        }
    }
}

struct MachinesFilesRenameCommand: AsyncParsableCommand {
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
            guard !name.contains("/") else {
                throw CLIFailure(
                    "a new name cannot contain a slash",
                    hint: "use `ed machines files mv` to move it somewhere else")
            }
            let destination = (path as NSString).deletingLastPathComponent
            let target =
                destination.isEmpty ? name : (destination as NSString).appendingPathComponent(name)
            try await FileOps.apply(
                FileOperations.renameCommand(path: path, to: target), machine: machine,
                describing: "renamed to \(target)", json: json,
                fields: ["path": .string(path), "to": .string(target)])
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
            try await FileOps.apply(
                FileOperations.makeDirectoryCommand(path: path), machine: machine,
                describing: "made \(path)", json: json, fields: ["path": .string(path)])
        }
    }
}

struct MachinesFilesRemoveCommand: AsyncParsableCommand {
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
            guard !paths.isEmpty else { throw CLIFailure("name at least one path") }
            guard !delete || yes else {
                guard !json else {
                    CLIOut.json(
                        .object(["paths": .strings(paths), "deleted": .bool(false)]))
                    return
                }
                CLIOut.out("would delete \(paths.count) path(s) for good")
                CLIOut.note("nothing was deleted; pass --yes to go ahead")
                return
            }
            let command =
                delete
                ? FileOperations.deleteCommand(paths: paths)
                : FileOperations.trashCommand(paths: paths)
            try await FileOps.apply(
                command, machine: machine,
                describing: delete
                    ? "deleted \(paths.count) path(s)" : "trashed \(paths.count) path(s)",
                json: json,
                fields: ["paths": .strings(paths), "deleted": .bool(delete)])
        }
    }
}

struct MachinesFilesSearchCommand: AsyncParsableCommand {
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
            let output = try await runner.text(
                FileOperations.searchCommand(path: path, query: query, limit: limit),
                timeout: 120)
            let hits = output.split(separator: "\n").map(String.init)
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
            let output = try await runner.text(
                FileOperations.directorySizeCommand(path: path), timeout: 120)
            let kilobytes = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let bytes = kilobytes * 1024
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "path": .string(path),
                        "sizeBytes": .int(bytes),
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
            let quoted = ShellQuote.quote(path)
            let script = """
                src=\(quoted); dir=$(dirname "$src"); base=$(basename "$src")
                stem="${base%.*}"; ext=""
                case "$base" in *.*) ext=".${base##*.}";; esac
                target="$dir/$stem copy$ext"; n=2
                while [ -e "$target" ]; do target="$dir/$stem copy $n$ext"; n=$((n+1)); done
                cp -R "$src" "$target" && printf '%s' "$target"
                """
            let result = try await runner.run(script, timeout: 300)
            let created = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.succeeded, !created.isEmpty else {
                throw CLIFailure(
                    "could not duplicate \(path) on \(runner.machine.name)",
                    hint: result.combinedText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
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
