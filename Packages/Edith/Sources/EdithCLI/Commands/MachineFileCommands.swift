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
            MachinesFilesOpenCommand.self,
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
            let runner = try await MachineResolver.runner(machine)
            let resolved = path == "." ? try await homeDirectory(runner) : path
            let result = try await runner.run(
                FileListing.command(path: resolved, showHidden: true), timeout: 45)
            var entries = FileListing.parse(output: result.stdoutText, parent: resolved)
            if entries.isEmpty, !result.succeeded {
                throw CLIFailure(
                    "could not read \(resolved) on \(runner.machine.name)",
                    hint: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !all { entries = entries.filter { !$0.isHidden } }
            guard !json else {
                CLIOut.json(
                    .object([
                        "path": .string(resolved),
                        "entries": .array(entries.map(MachineReports.file)),
                    ]))
                return
            }
            let rows = entries.map { entry in
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

    private func homeDirectory(_ runner: RemoteRunner) async throws -> String {
        let output = try await runner.text("printf %s \"$HOME\"", timeout: 15)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/" : trimmed
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
                try await runner.ssh.download(remotePath: remote, to: destination) { written in
                    progress.update(meter.text(sent: written))
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
