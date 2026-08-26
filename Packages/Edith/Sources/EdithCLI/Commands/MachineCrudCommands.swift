import ArgumentParser
import EdithKit
import Foundation

enum SecretInput {
    static func readFromStdin(_ what: String) throws -> String {
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw CLIFailure(
                "no \(what) arrived on stdin",
                hint: "pipe it, for example: printf '%s' \"$PASS\" | ed machines add ...")
        }
        return line
    }
}

enum MachineEditing {
    static func port(_ value: Int) throws -> Int {
        guard (1...65535).contains(value) else {
            throw CLIFailure("--port must be between 1 and 65535")
        }
        return value
    }

    static func auth(keyFile: String?, agent: Bool, hasPassphrase: Bool = false) throws
        -> MachineAuth?
    {
        if agent, keyFile != nil {
            throw CLIFailure("--agent and --key are different answers to the same question")
        }
        if agent { return .agent }
        guard let keyFile else { return nil }
        let path = keyFile.expandingTilde()
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIFailure.notFound(
                "there is no key file at \(path)",
                hint: "point --key at a private key, or pass --agent to use the SSH agent")
        }
        return .keyFile(path: path, hasPassphrase: hasPassphrase)
    }

    static func rejectDuplicate(name: String, excluding id: UUID?, in machines: [Machine]) throws {
        let taken = machines.contains {
            $0.id != id && $0.name.lowercased() == name.lowercased()
        }
        guard taken else { return }
        throw CLIFailure(
            "a machine called \(name) already exists",
            hint: "pick another name, or edit the existing one with `ed machines edit \(name)`")
    }

    static func describe(_ machine: Machine) {
        CLIOut.out(machine.name)
        CLIOut.out("  target   \(machine.subtitle)")
        CLIOut.out("  auth     \(machine.auth.displayName)")
        if let mac = machine.wakeMACAddress { CLIOut.out("  wake     \(mac)") }
    }
}

struct MachinesAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a machine to Edith's list.",
        discussion: """
            The machine appears in the app straight away. A login password or a key
            passphrase is read from stdin with --password-stdin or --key-passphrase-stdin,
            never taken as an argument, and goes into the same login keychain item the app
            uses.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "What to call it.")
    var name: String

    @Option(help: "Hostname or address to reach it at.")
    var host: String

    @Option(help: "SSH port.")
    var port: Int = 22

    @Option(help: "Username to log in as.")
    var user: String = ""

    @Option(help: "Private key to authenticate with, instead of the SSH agent.")
    var key: String?

    @Option(help: "Treat this as an entry from your ssh config with this alias.")
    var alias: String?

    @Option(help: "MAC address to send a wake-on-LAN packet to.")
    var mac: String?

    @Flag(
        help:
            "Read a login password from stdin and store it in the keychain, the way the app does."
    )
    var passwordStdin = false

    @Flag(help: "Read the key file's passphrase from stdin instead of a password.")
    var keyPassphraseStdin = false

    func run() async throws {
        try await execute {
            guard !(passwordStdin && keyPassphraseStdin) else {
                throw CLIFailure("a machine has either a password or a key passphrase, not both")
            }
            if keyPassphraseStdin, key == nil {
                throw CLIFailure("--key-passphrase-stdin only means something with --key")
            }
            let secret =
                passwordStdin
                ? try SecretInput.readFromStdin("password")
                : (keyPassphraseStdin ? try SecretInput.readFromStdin("passphrase") : nil)
            let existing = MachineRegistry.machines()
            try MachineEditing.rejectDuplicate(name: name, excluding: nil, in: existing)
            let resolved: MachineAuth
            if passwordStdin {
                resolved = .password
            } else if let keyFile = key {
                resolved =
                    try MachineEditing.auth(
                        keyFile: keyFile, agent: false, hasPassphrase: keyPassphraseStdin) ?? .agent
            } else {
                resolved = .agent
            }
            let machine = Machine(
                name: name, host: host, port: try MachineEditing.port(port), username: user,
                auth: resolved,
                source: alias.map { MachineSource.sshConfigAlias($0) } ?? .manual,
                wakeMACAddress: mac)
            MachineMutationOperationExecution.perform(
                .add, machine: machine,
                secrets: MachineSecretChanges(login: secret),
                notify: { AppBridge.post(IPC.Name.machinesChanged) })
            guard !json else {
                CLIOut.json(MachineDirectory.summary(machine))
                return
            }
            CLIOut.out("added \(machine.name)")
            MachineEditing.describe(machine)
        }
    }
}

struct MachinesEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit", abstract: "Change a machine already on the list.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Option(help: "Rename it.")
    var name: String?

    @Option(help: "Hostname or address to reach it at.")
    var host: String?

    @Option(help: "SSH port.")
    var port: Int?

    @Option(help: "Username to log in as.")
    var user: String?

    @Option(help: "Private key to authenticate with.")
    var key: String?

    @Flag(help: "Authenticate with the SSH agent instead of a key file.")
    var agent = false

    @Option(help: "MAC address to send a wake-on-LAN packet to. Pass an empty value to clear.")
    var mac: String?

    @Flag(help: "Read a new login password from stdin and store it in the keychain.")
    var passwordStdin = false

    @Flag(help: "Read the key file's passphrase from stdin.")
    var keyPassphraseStdin = false

    @Flag(help: "Read this account's sudo password from stdin and store it in the keychain.")
    var sudoPasswordStdin = false

    @Flag(help: "Forget the stored sudo password.")
    var forgetSudoPassword = false

    func run() async throws {
        try await execute {
            guard !(passwordStdin && keyPassphraseStdin) else {
                throw CLIFailure("a machine has either a password or a key passphrase, not both")
            }
            guard !(sudoPasswordStdin && forgetSudoPassword) else {
                throw CLIFailure("a sudo password is either stored or forgotten, not both")
            }
            guard !(sudoPasswordStdin && (passwordStdin || keyPassphraseStdin)) else {
                throw CLIFailure(
                    "only one secret can be read from stdin at a time",
                    hint: "store the sudo password in its own `ed machines edit` call")
            }
            let secret =
                passwordStdin
                ? try SecretInput.readFromStdin("password")
                : (keyPassphraseStdin ? try SecretInput.readFromStdin("passphrase") : nil)
            let sudoSecret =
                sudoPasswordStdin ? try SecretInput.readFromStdin("sudo password") : nil
            var target = try MachineResolver.machine(machine)
            let all = MachineRegistry.machines()
            if let name {
                try MachineEditing.rejectDuplicate(name: name, excluding: target.id, in: all)
                target.name = name
            }
            if let host { target.host = host }
            if let port { target.port = try MachineEditing.port(port) }
            if let user { target.username = user }
            if let auth = try MachineEditing.auth(
                keyFile: key, agent: agent, hasPassphrase: keyPassphraseStdin)
            {
                target.auth = auth
            }
            if passwordStdin { target.auth = .password }
            if let mac { target.wakeMACAddress = mac.isEmpty ? nil : mac }
            MachineMutationOperationExecution.perform(
                .edit, machine: target,
                secrets: MachineSecretChanges(
                    login: secret, sudoPassword: sudoSecret,
                    forgetSudoPassword: forgetSudoPassword),
                notify: { AppBridge.post(IPC.Name.machinesChanged) })
            guard !json else {
                CLIOut.json(MachineDirectory.summary(target))
                return
            }
            CLIOut.out("updated \(target.name)")
            MachineEditing.describe(target)
        }
    }
}

struct MachinesRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Forget a machine, its forwards, its snippets and its stored secrets.",
        aliases: ["remove"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually remove it. Without this nothing is touched.")
    var yes = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let target = try MachineResolver.machine(machine)
            let preview = MachineMutationOperationExecution.removalPreview(target)
            guard yes else {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "machine": MachineDirectory.summary(target),
                            "removed": .bool(false),
                            "forwards": .int(preview.forwardCount),
                            "snippets": .int(preview.snippetCount),
                        ]))
                    return
                }
                CLIOut.out(
                    "would remove \(target.name), \(preview.forwardCount) forward(s) and "
                        + "\(preview.snippetCount) snippet(s)")
                CLIOut.note("nothing was removed; pass --yes to go ahead")
                return
            }
            let result = MachineMutationOperationExecution.perform(
                .remove, machine: target,
                notify: { AppBridge.post(IPC.Name.machinesChanged) })
            let removal = result.removal ?? preview
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": MachineDirectory.summary(target),
                        "removed": .bool(true),
                        "forwards": .int(removal.forwardCount),
                        "snippets": .int(removal.snippetCount),
                    ]))
                return
            }
            CLIOut.out("removed \(target.name)")
        }
    }
}

struct MachinesForwardsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forwards",
        abstract: "The port forwards saved for a machine.",
        subcommands: [
            MachinesForwardsListCommand.self, MachinesForwardsAddCommand.self,
            MachinesForwardsRemoveCommand.self, MachinesForwardsToggleCommand.self,
            MachinesForwardsOffCommand.self, MachinesForwardsOpenCommand.self,
        ],
        defaultSubcommand: MachinesForwardsListCommand.self,
        aliases: ["forward"])
}

enum ForwardBridge {
    static func forwards(_ query: String) throws -> (machine: Machine, all: [PortForward]) {
        let machine = try MachineResolver.machine(query)
        let all = MachineRegistry.forwards(
            machineID: machine.id, in: MachineRegistry.forwards()
        ).sorted { $0.localPort < $1.localPort }
        return (machine, all)
    }

    static func json(_ forward: PortForward, index: Int) -> JSONValue {
        .object([
            "index": .int(index),
            "id": .string(forward.id.uuidString),
            "title": .string(forward.displayName),
            "localPort": .int(forward.localPort),
            "remoteHost": .string(forward.remoteHost),
            "remotePort": .int(forward.remotePort),
            "spec": .string(forward.forwardSpec),
        ])
    }

    static func selected(_ query: String, index: Int) throws -> (
        machine: Machine, forward: PortForward
    ) {
        let found = try forwards(query)
        guard index >= 1, index <= found.all.count else {
            throw CLIFailure.notFound(
                "there is no forward \(index) on \(found.machine.name)",
                hint: "it has \(found.all.count), numbered from 1")
        }
        return (found.machine, found.all[index - 1])
    }
}

struct MachinesForwardsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List a machine's port forwards.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let found = try ForwardBridge.forwards(machine)
            guard !json else {
                CLIOut.json(
                    .array(
                        found.all.enumerated().map { ForwardBridge.json($1, index: $0 + 1) }))
                return
            }
            guard !found.all.isEmpty else {
                CLIOut.note("\(found.machine.name) has no saved forwards")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["#", "TITLE", "LOCAL", "REMOTE"],
                    rows: found.all.enumerated().map { offset, forward in
                        [
                            String(offset + 1), forward.title,
                            String(forward.localPort),
                            "\(forward.remoteHost):\(forward.remotePort)",
                        ]
                    }))
        }
    }
}

struct MachinesForwardsAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Save a port forward for a machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Option(help: "Port to open on this Mac.")
    var local: Int

    @Option(help: "Port to reach on the far side.")
    var remote: Int

    @Option(help: "Host the far side should connect to.")
    var remoteHost: String = "localhost"

    @Option(help: "What to call it.")
    var title: String = ""

    func run() async throws {
        try await execute {
            let target = try MachineResolver.machine(machine)
            let forward = PortForward(
                machineID: target.id, localPort: try MachineEditing.port(local),
                remoteHost: remoteHost, remotePort: try MachineEditing.port(remote),
                title: title)
            let result = await MachineForwardOperationExecution.perform(
                .add, forward: forward, existing: MachineRegistry.forwards(),
                notify: { AppBridge.post(IPC.Name.machinesChanged) })
            if case let .failure(error as MachineForwardOperationError) = result,
                case .duplicateLocalPort = error
            {
                throw CLIFailure(
                    "\(target.name) already forwards local port \(forward.localPort)",
                    hint: "run `ed machines forwards ls \(target.name)` to see them")
            }
            if case let .failure(error) = result {
                throw CLIFailure(error.localizedDescription)
            }
            guard !json else {
                CLIOut.json(ForwardBridge.json(forward, index: 0))
                return
            }
            CLIOut.out("added \(forward.forwardSpec) on \(target.name)")
        }
    }
}

struct MachinesForwardsRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Forget one saved port forward.", aliases: ["remove"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The forward number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try ForwardBridge.forwards(machine)
            guard index >= 1, index <= found.all.count else {
                throw CLIFailure.notFound(
                    "there is no forward \(index) on \(found.machine.name)",
                    hint: "it has \(found.all.count), numbered from 1")
            }
            let forward = found.all[index - 1]
            let result = await MachineForwardOperationExecution.perform(
                .remove, forward: forward,
                notify: { AppBridge.post(IPC.Name.machinesChanged) })
            if case let .failure(error) = result {
                throw CLIFailure(error.localizedDescription)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "removed": ForwardBridge.json(forward, index: index),
                        "remaining": .int(found.all.count - 1),
                    ]))
                return
            }
            CLIOut.out("removed \(forward.forwardSpec) from \(found.machine.name)")
        }
    }
}

struct MachinesSnippetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snippets",
        abstract: "The saved commands a machine offers.",
        subcommands: [
            MachinesSnippetsListCommand.self, MachinesSnippetsAddCommand.self,
            MachinesSnippetsRemoveCommand.self, MachinesSnippetsRunCommand.self,
        ],
        defaultSubcommand: MachinesSnippetsListCommand.self,
        aliases: ["snippet"])
}

enum SnippetBridge {
    struct Output: Equatable, Sendable {
        let stdout: String
        let stderr: String
    }

    struct Selection {
        let machine: Machine
        let snippet: CommandSnippet
        let index: Int
    }

    static func snippets(_ query: String) throws -> (machine: Machine, all: [CommandSnippet]) {
        let machine = try MachineResolver.machine(query)
        let all = MachineRegistry.snippets(
            machineID: machine.id, in: MachineRegistry.snippets())
        return (machine, all)
    }

    static func json(_ snippet: CommandSnippet, index: Int) -> JSONValue {
        .object([
            "index": .int(index),
            "id": .string(snippet.id.uuidString),
            "title": .string(snippet.title),
            "command": .string(snippet.command),
            "sharedAcrossMachines": .bool(snippet.machineID == nil),
        ])
    }

    static func selection(_ query: String, index: Int) throws -> Selection {
        let found = try snippets(query)
        return Selection(
            machine: found.machine,
            snippet: try SavedSnippetOperationExecution.snippet(at: index, in: found.all),
            index: index)
    }

    static func output(
        stdout: String, stderr: String, status: Int32, machineName: String
    ) throws -> Output {
        guard status == 0 else {
            let diagnostics = [
                stdout.isEmpty ? nil : "stdout:\n\(stdout)",
                stderr.isEmpty ? nil : "stderr:\n\(stderr)",
            ].compactMap { $0 }.joined(separator: "\n")
            throw CLIFailure(
                "saved command exited \(status) on \(machineName)",
                hint: diagnostics.isEmpty
                    ? nil : diagnostics.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Output(stdout: stdout, stderr: stderr)
    }
}

struct MachinesSnippetsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the snippets a machine offers.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let found = try SnippetBridge.snippets(machine)
            guard !json else {
                CLIOut.json(
                    .array(
                        found.all.enumerated().map { SnippetBridge.json($1, index: $0 + 1) }))
                return
            }
            guard !found.all.isEmpty else {
                CLIOut.note("\(found.machine.name) has no snippets")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["#", "TITLE", "SCOPE", "COMMAND"],
                    rows: found.all.enumerated().map { offset, snippet in
                        [
                            String(offset + 1), snippet.title,
                            snippet.machineID == nil ? "shared" : "machine", snippet.command,
                        ]
                    }))
        }
    }
}

struct MachinesSnippetsAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Save a command against a machine.",
        discussion: """
            Everything after the title is the command, verbatim, so `--shared` and `--json`
            have to come before the machine name: `ed machines snippets add --shared box
            logs journalctl -xe`.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Offer it on every machine rather than just this one.")
    var shared = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "What to call it.")
    var title: String

    @Argument(parsing: .captureForPassthrough, help: "The command to save.")
    var command: [String]

    func run() async throws {
        try await execute {
            let target = try MachineResolver.machine(machine)
            let text = command.joined(separator: " ")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CLIFailure("a snippet needs a command to run")
            }
            let snippet = CommandSnippet(
                machineID: shared ? nil : target.id, title: title, command: text)
            let result = MachineSnippetOperationExecution.perform(
                .add, snippet: snippet,
                notify: { AppBridge.post(IPC.Name.machinesChanged) })
            if case let .failure(error) = result {
                throw CLIFailure(error.localizedDescription)
            }
            guard !json else {
                CLIOut.json(SnippetBridge.json(snippet, index: 0))
                return
            }
            CLIOut.out("saved \(title) on \(shared ? "every machine" : target.name)")
        }
    }
}

struct MachinesSnippetsRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Forget one snippet.", aliases: ["remove"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The snippet number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try SnippetBridge.snippets(machine)
            guard index >= 1, index <= found.all.count else {
                throw CLIFailure.notFound(
                    "there is no snippet \(index) on \(found.machine.name)",
                    hint: "it offers \(found.all.count), numbered from 1")
            }
            let snippet = found.all[index - 1]
            let result = MachineSnippetOperationExecution.perform(
                .remove, snippet: snippet,
                notify: { AppBridge.post(IPC.Name.machinesChanged) })
            if case let .failure(error) = result {
                throw CLIFailure(error.localizedDescription)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "removed": SnippetBridge.json(snippet, index: index),
                        "remaining": .int(found.all.count - 1),
                    ]))
                return
            }
            CLIOut.out("removed \(snippet.title)")
        }
    }
}

struct MachinesSnippetsRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run one saved command on a machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The snippet number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let selection: SnippetBridge.Selection
            do {
                selection = try SnippetBridge.selection(machine, index: index)
            } catch let failure as CLIFailure {
                throw failure
            } catch let error as MachineDetailOperationError {
                throw CLIFailure.notFound(error.localizedDescription)
            } catch {
                throw error
            }
            let runner = try await MachineResolver.runner(selection.machine)
            let result = await SavedSnippetOperationExecution.run(selection.snippet) {
                command, timeout in
                do {
                    let result = try await runner.run(command, timeout: timeout)
                    return .success(
                        try SnippetBridge.output(
                            stdout: result.stdoutText, stderr: result.stderrText,
                            status: result.status, machineName: runner.machine.name))
                } catch {
                    return .failure(error)
                }
            }
            let output = try result.get()
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "operation": .string(SavedSnippetOperation.run.descriptor.id.rawValue),
                        "stderr": .string(output.stderr),
                        "stdout": .string(output.stdout),
                        "snippet": SnippetBridge.json(
                            selection.snippet, index: selection.index),
                    ]))
                return
            }
            CLIOut.raw(output.stdout)
            CLIOut.rawError(output.stderr)
        }
    }
}

struct MachinesForwardsToggleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on",
        abstract: "Open a saved port forward on the shared connection.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The forward number, counting from 1.")
    var index: Int

    func run() async throws {
        try await ForwardBridge.set(true, machine: machine, index: index, json: json)
    }
}

struct MachinesForwardsOffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off", abstract: "Close a saved port forward.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The forward number, counting from 1.")
    var index: Int

    func run() async throws {
        try await ForwardBridge.set(false, machine: machine, index: index, json: json)
    }
}

struct MachinesForwardsOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open a forwarded service in the browser.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The forward number, counting from 1.")
    var index: Int

    func run() async throws {
        try await execute {
            let found = try ForwardBridge.selected(machine, index: index)
            guard let url = PortForwardBrowserOperationExecution.url(forward: found.forward) else {
                throw CLIFailure("could not make a browser URL for forward \(index)")
            }
            guard
                RemoteFileOperationExecution.present(
                    [url], action: .open, using: CLIEnvironment.presentURLs)
            else {
                throw CLIFailure.unavailable("macOS could not open \(url.absoluteString)")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "index": .int(index),
                        "machine": .string(found.machine.name),
                        "opened": .bool(true),
                        "url": .string(url.absoluteString),
                    ]))
                return
            }
            CLIOut.out("opened \(url.absoluteString)")
        }
    }
}

extension ForwardBridge {
    static func set(_ active: Bool, machine: String, index: Int, json: Bool) async throws {
        try await execute {
            let found = try ForwardBridge.forwards(machine)
            guard index >= 1, index <= found.all.count else {
                throw CLIFailure.notFound(
                    "there is no forward \(index) on \(found.machine.name)",
                    hint: "it has \(found.all.count), numbered from 1")
            }
            let forward = found.all[index - 1]
            let runner = try await MachineResolver.runner(machine)
            let operation: MachineForwardOperation = active ? .enable : .disable
            let result = await MachineForwardOperationExecution.perform(
                operation, forward: forward,
                setActive: { candidate, shouldOpen in
                    guard shouldOpen else {
                        await runner.ssh.cancelForward(candidate)
                        return nil
                    }
                    do {
                        try await runner.ssh.addForward(candidate)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                })
            if case let .failure(error as MachineForwardOperationError) = result {
                switch error {
                case let .liveActionFailed(detail) where active:
                    throw CLIFailure(
                        "could not open \(forward.forwardSpec) on \(found.machine.name)",
                        hint: detail)
                default:
                    throw CLIFailure(error.localizedDescription)
                }
            }
            if case let .failure(error) = result {
                throw CLIFailure(error.localizedDescription)
            }
            guard !json else {
                guard case var .object(fields) = ForwardBridge.json(forward, index: index)
                else { return }
                fields["open"] = .bool(active)
                CLIOut.json(.object(fields))
                return
            }
            CLIOut.out(
                active
                    ? "localhost:\(forward.localPort) now reaches "
                        + "\(forward.remoteHost):\(forward.remotePort)"
                    : "closed \(forward.forwardSpec)")
        }
    }
}
