import ArgumentParser
import EdithKit
import Foundation

struct MachinesFilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files",
        abstract: "Browse and transfer files on a machine.",
        subcommands: [
            MachineFilesListCommand.self, MachineFilesGetCommand.self,
            MachineFilesPutCommand.self, MachinesFilesCopyCommand.self,
            MachinesFilesMoveCommand.self, MachinesFilesRenameCommand.self,
            MachinesFilesMakeDirectoryCommand.self, MachinesFilesRemoveCommand.self,
            MachinesFilesSearchCommand.self, MachinesFilesInfoCommand.self,
            MachinesFilesDuplicateCommand.self, MachinesFilesUndoCommand.self,
            MachineFilesPreviewCommand.self,
            MachineFilesLaunchCommand.self, MachineFilesRevealCommand.self,
            MachineFilesGetManyCommand.self, MachineFilesTransferCommand.self,
        ],
        defaultSubcommand: MachineFilesListCommand.self)
}

struct MachineFilesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List a remote directory.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: [.long, .short], help: "Include dotfiles.")
    var all = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Remote directory.")
    var path: String = "."

    func run() async throws {
        try await execute {
            let target = try await CLIEnvironment.remoteDirectoryTarget(machine)
            let listing: RemoteDirectoryListing
            do {
                listing = try await RemoteDirectoryOperationExecution.list(
                    path: path, showHidden: all, using: target.endpoint)
            } catch {
                throw CLIFailure(
                    "could not read \(path) on \(target.machine.name)",
                    hint: error.localizedDescription)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "path": .string(listing.path),
                        "entries": .array(listing.entries.map(MachineReports.file)),
                    ]))
                return
            }
            let rows = listing.entries.map { entry in
                [
                    entry.kind == .directory ? "d" : (entry.kind == .symlink ? "l" : "-"),
                    entry.mode,
                    entry.kind == .directory ? "" : ByteFormatter.string(entry.sizeBytes),
                    entry.name,
                ]
            }
            CLIOut.out(TextTable.render(headers: ["T", "MODE", "SIZE", "NAME"], rows: rows))
        }
    }
}

struct MachineFilesGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Download a file from a machine.",
        discussion: """
            Existing files are kept by adding a number. Pass --replace to preview
            replacement, then add --yes to confirm it.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Show the resolved destination without downloading.")
    var dryRun = false

    @Flag(help: "Replace a destination file with the same name.")
    var replace = false

    @Flag(help: "Confirm replacement requested with --replace.")
    var yes = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Remote file path.")
    var remote: String

    @Argument(help: "Local destination. Defaults to the file name in the working directory.")
    var local: String?

    func run() async throws {
        try await execute {
            let source = try await CLIEnvironment.remoteTransferTarget(machine)
            let remoteName = (remote as NSString).lastPathComponent
            let requested = URL(
                fileURLWithPath: (local ?? remoteName).expandingTilde()
            ).standardizedFileURL
            var isDirectory: ObjCBool = false
            let destination =
                (FileManager.default.fileExists(
                    atPath: requested.path, isDirectory: &isDirectory) && isDirectory.boolValue)
                    || local?.hasSuffix("/") == true
                ? requested.appendingPathComponent(remoteName) : requested
            let directory = destination.deletingLastPathComponent()
            var parentIsDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: directory.path, isDirectory: &parentIsDirectory),
                parentIsDirectory.boolValue
            else {
                throw CLIFailure.notFound("no destination directory at \(directory.path)")
            }
            let local = RemoteTransferEndpoint.local(
                machineID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                name: "This Mac")
            let existing = try await local.list(directory.path)
            let plan = RemoteTransferOperationExecution.plan(
                sourcePath: remote, destinationPath: destination.path, existing: existing,
                resolution: RemoteTransferCLI.resolution(replace: replace))
            let confirmationMissing = replace && !yes && !plan.replacements.isEmpty
            if RemoteTransferCLI.shouldPreview(
                plan, dryRun: dryRun, replace: replace, yes: yes)
            {
                RemoteTransferCLI.reportPlan(
                    operation: RemoteFileOperation.download.descriptor.id, verb: "download",
                    source: source.machine.name, destinationMachine: nil, plan: plan,
                    dryRun: dryRun, confirmationMissing: confirmationMissing, json: json)
                return
            }
            let outcome = try await RemoteTransferOperationExecution.execute(
                plan, from: source.endpoint, to: local,
                confirmsReplacement: replace && yes)
            try RemoteTransferCLI.reportOutcome(
                operation: RemoteFileOperation.download.descriptor.id,
                completedVerb: "downloaded", source: source.machine.name,
                destinationMachine: nil, plan: plan, outcome: outcome, json: json)
        }
    }
}

struct MachineFilesPreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview", abstract: "Print a text preview of a remote file.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Remote file path.")
    var path: String

    func run() async throws {
        try await execute {
            let runner = try await MachineResolver.runner(machine)
            let result = try await runner.run(
                RemoteFileOperationExecution.previewCommand(path: path), timeout: 45)
            guard result.succeeded else {
                throw CLIFailure(
                    "could not preview \(path) on \(runner.machine.name)",
                    hint: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let preview = RemoteFileOperationExecution.textPreview(result.stdout)
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "path": .string(path),
                        "text": .string(preview.text),
                        "truncated": .bool(preview.truncated),
                    ]))
                return
            }
            CLIOut.raw(preview.text)
            if !preview.text.hasSuffix("\n") { CLIOut.raw("\n") }
            if preview.truncated { CLIOut.note("preview stopped after 400 KiB") }
        }
    }
}

enum MachineFilePresentationCLI {
    static func present(
        action: FilePresentationAction, machine query: String, path: String, json: Bool
    ) async throws {
        let runner = try await MachineResolver.runner(query)
        let entry = RemoteFileEntry(
            name: (path as NSString).lastPathComponent, path: path, kind: .file,
            sizeBytes: await runner.ssh.remoteFileSize(path) ?? 0)
        let localURL: URL
        do {
            localURL = try await RemoteFileOperationExecution.materialize(
                entry, machineID: runner.machine.id, isLocal: false
            ) { remotePath, destination in
                try await runner.ssh.download(remotePath: remotePath, to: destination)
            }
        } catch {
            throw CLIFailure("could not download \(path): \(error.localizedDescription)")
        }
        guard
            RemoteFileOperationExecution.present(
                [localURL], action: action, using: CLIEnvironment.presentURLs)
        else {
            throw CLIFailure.unavailable(
                action == .open ? "macOS could not open \(localURL.path)" : "Finder is unavailable")
        }
        let actionName = action == .open ? "opened" : "revealed"
        guard !json else {
            CLIOut.json(
                .object([
                    "action": .string(actionName),
                    "local": .string(localURL.path),
                    "machine": .string(runner.machine.name),
                    "remote": .string(path),
                ]))
            return
        }
        CLIOut.out("\(actionName) \(path) from \(runner.machine.name)")
    }
}

struct MachineFilesLaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch", abstract: "Open a remote file in its default Mac app.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Remote file path.")
    var path: String

    func run() async throws {
        try await execute {
            try await MachineFilePresentationCLI.present(
                action: .open, machine: machine, path: path, json: json)
        }
    }
}

struct MachineFilesRevealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal", abstract: "Reveal a downloaded remote file in Finder.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Remote file path.")
    var path: String

    func run() async throws {
        try await execute {
            try await MachineFilePresentationCLI.present(
                action: .reveal, machine: machine, path: path, json: json)
        }
    }
}

struct MachineFilesPutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "put", abstract: "Upload a file to a machine.",
        discussion: """
            Existing files are kept by adding a number. Pass --replace to preview
            replacement, then add --yes to confirm it.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Show the resolved destination without uploading.")
    var dryRun = false

    @Flag(help: "Replace a destination file with the same name.")
    var replace = false

    @Flag(help: "Confirm replacement requested with --replace.")
    var yes = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Local file path.")
    var local: String

    @Argument(help: "Remote destination path.")
    var remote: String

    func run() async throws {
        try await execute {
            let source = URL(fileURLWithPath: local.expandingTilde())
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else {
                throw CLIFailure.notFound("no file at \(source.path)")
            }
            let target = try await CLIEnvironment.remoteTransferTarget(machine)
            let remoteIsDirectory =
                remote.hasSuffix("/") ? true : try await target.endpoint.isDirectory(remote)
            let trimmed = remote.hasSuffix("/") ? String(remote.dropLast()) : remote
            let destination =
                remoteIsDirectory
                ? FileListing.join(parent: trimmed, name: source.lastPathComponent) : remote
            let rawDirectory = (destination as NSString).deletingLastPathComponent
            let directory = rawDirectory.isEmpty ? "." : rawDirectory
            let existing = try await target.endpoint.list(directory)
            let plan = RemoteTransferOperationExecution.plan(
                sourcePath: source.path, destinationPath: destination, existing: existing,
                resolution: RemoteTransferCLI.resolution(replace: replace))
            let confirmationMissing = replace && !yes && !plan.replacements.isEmpty
            let operation = RemoteTransferOperation.uploadFile.descriptor.id
            if RemoteTransferCLI.shouldPreview(
                plan, dryRun: dryRun, replace: replace, yes: yes)
            {
                RemoteTransferCLI.reportPlan(
                    operation: operation, verb: "upload", source: "This Mac",
                    destinationMachine: target.machine.name, plan: plan, dryRun: dryRun,
                    confirmationMissing: confirmationMissing, json: json)
                return
            }
            let local = RemoteTransferEndpoint.local(
                machineID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                name: "This Mac")
            let outcome = try await RemoteTransferOperationExecution.execute(
                plan, from: local, to: target.endpoint,
                confirmsReplacement: replace && yes)
            try RemoteTransferCLI.reportOutcome(
                operation: operation, completedVerb: "uploaded", source: "This Mac",
                destinationMachine: target.machine.name, plan: plan, outcome: outcome, json: json)
        }
    }
}

extension String {
    func expandingTilde() -> String {
        (self as NSString).expandingTildeInPath
    }
}
