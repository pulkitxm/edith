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
            MachinesFilesOpenCommand.self, MachineFilesPreviewCommand.self,
            MachineFilesLaunchCommand.self, MachineFilesRevealCommand.self,
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
        commandName: "get", abstract: "Download a file from a machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Remote file path.")
    var remote: String

    @Argument(help: "Local destination. Defaults to the file name in the working directory.")
    var local: String?

    func run() async throws {
        try await execute {
            let runner = try await MachineResolver.runner(machine)
            let destination = URL(
                fileURLWithPath: (local ?? (remote as NSString).lastPathComponent as String)
                    .expandingTilde())
            let progress = CLIProgress.forCommand(json: json)
            let expected = await runner.ssh.remoteFileSize(remote)
            let meter = TransferMeter(
                total: expected, label: (remote as NSString).lastPathComponent)
            progress.begin(meter.text(sent: 0))
            do {
                try await RemoteFileOperationExecution.download(
                    remotePath: remote, to: destination
                ) { remotePath, localURL in
                    try await runner.ssh.download(remotePath: remotePath, to: localURL) { written in
                        progress.update(meter.text(sent: written))
                    }
                }
                progress.end()
            } catch {
                progress.end()
                throw CLIFailure("download failed: \(error.localizedDescription)")
            }
            let size =
                (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size])
                as? Int ?? 0
            guard !json else {
                CLIOut.json(
                    .object([
                        "remote": .string(remote),
                        "local": .string(destination.path),
                        "sizeBytes": .int(size),
                    ]))
                return
            }
            CLIOut.out("\(destination.path)  \(ByteFormatter.string(Int64(size)))")
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
        commandName: "put", abstract: "Upload a file to a machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Local file path.")
    var local: String

    @Argument(help: "Remote destination path.")
    var remote: String

    func run() async throws {
        try await execute {
            let source = URL(fileURLWithPath: local.expandingTilde())
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw CLIFailure.notFound("no file at \(source.path)")
            }
            let runner = try await MachineResolver.runner(machine)
            let destination = try await RemoteDestination.resolve(
                remote, named: source.lastPathComponent, on: runner)
            let progress = CLIProgress.forCommand(json: json)
            let expected =
                (try? FileManager.default.attributesOfItem(atPath: source.path)[.size]) as? Int64
            let meter = TransferMeter(total: expected, label: source.lastPathComponent)
            progress.begin(meter.text(sent: 0))
            do {
                try await runner.ssh.upload(localURL: source, toRemotePath: destination) { sent in
                    progress.update(meter.text(sent: sent))
                }
                progress.end()
            } catch {
                progress.end()
                throw CLIFailure("upload failed: \(error.localizedDescription)")
            }
            let size =
                (try? FileManager.default.attributesOfItem(atPath: source.path)[.size]) as? Int
                ?? 0
            guard !json else {
                CLIOut.json(
                    .object([
                        "local": .string(source.path),
                        "remote": .string(destination),
                        "sizeBytes": .int(size),
                    ]))
                return
            }
            CLIOut.out("\(destination)  \(ByteFormatter.string(Int64(size)))")
        }
    }
}

struct MachinesFilesOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open Edith's Files window on a machine directory.",
        discussion: """
            The window belongs to Edith Files, a separate app that holds nothing but
            these windows: no dashboard, no menu bar item, and it quits when you close
            the last one. `ed` starts it when it is not already up, and asks the running
            one for another window when it is.

            With no path it opens the directory this terminal is in, the one
            `ed <machine> cd` remembers, so browsing carries on where the shell left off.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Remote directory to show. Defaults to this terminal's directory.")
    var path: String?

    func run() async throws {
        try await execute {
            let target = try MachineResolver.machine(machine)
            let directory =
                path ?? MachineWorkingDirectory.load(machineID: target.id)
            let progress = CLIProgress.forCommand(json: json)
            guard AppBridge.filesAppIsRunning else {
                progress.begin("starting Edith Files")
                do {
                    try await AppBridge.startFilesApp(machineID: target.id, path: directory)
                } catch {
                    progress.end()
                    throw error
                }
                progress.end()
                report(machine: target, directory: directory)
                return
            }
            var answer: [AnyHashable: Any]?
            for _ in 0..<4 {
                answer = await AppBridge.awaitReply(IPC.Name.finderOpenResult, timeout: 3) {
                    var info: [String: Any] = ["machine": target.id.uuidString]
                    if let directory { info["path"] = directory }
                    AppBridge.post(IPC.Name.requestFinderOpen, userInfo: info)
                }
                if answer != nil { break }
            }
            progress.end()
            guard let reply = answer else {
                throw AppBridge.silence("opening the Files window")
            }
            guard reply["opened"] as? Bool == true else {
                throw CLIFailure.unavailable(
                    "Edith Files would not open a window for \(target.name)",
                    hint: reply["reason"] as? String)
            }
            report(machine: target, directory: directory)
        }
    }

    private func report(machine target: Machine, directory: String?) {
        guard !json else {
            CLIOut.json(
                .object([
                    "machine": .string(target.name),
                    "opened": .bool(true),
                    "path": .string(directory ?? ""),
                ]))
            return
        }
        CLIOut.out("opened \(directory ?? "the home directory") on \(target.name)")
    }
}

extension String {
    func expandingTilde() -> String {
        (self as NSString).expandingTildeInPath
    }
}

enum RemoteDestination {
    static func resolve(_ remote: String, named filename: String, on runner: RemoteRunner)
        async throws -> String
    {
        let trimmed = remote.hasSuffix("/") ? String(remote.dropLast()) : remote
        guard !trimmed.isEmpty else { return "/" + filename }
        if remote.hasSuffix("/") { return joined(trimmed, filename) }
        let probe = "test -d \(ShellQuote.quote(trimmed)) && echo dir || echo file"
        let answer = try? await runner.text(probe, timeout: 20)
        let isDirectory =
            (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "dir"
        return isDirectory ? joined(trimmed, filename) : remote
    }

    static func joined(_ directory: String, _ filename: String) -> String {
        directory + "/" + filename
    }
}
