import AppKit
import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

public struct CLIRemoteDirectoryTarget: Sendable {
    public let machine: Machine
    public let endpoint: RemoteDirectoryEndpoint
    public let platform: RemoteMachinePlatform
}

public enum MachinesCLIEnvironment {
    nonisolated(unsafe) static var runner: (Machine) -> RemoteRunner = { RemoteRunner(machine: $0) }
    nonisolated(unsafe) static var interactive: (Machine, [String], [String]) throws -> Int32 = {
        _, _, _ in
        throw CLIFailure.unavailable("the terminal input bridge is unavailable")
    }
    nonisolated(unsafe) static var changed: () -> Void = {}
    nonisolated(unsafe) static var broadcast:
        (UUID, MachineBroadcastPlan, String) async throws -> [String: Any] = { _, _, _ in
            throw CLIFailure.unavailable("the machine terminal session is unavailable")
        }
    nonisolated(unsafe) static var undo: (UUID) async throws -> [String: Any] = { _ in
        throw CLIFailure.unavailable("the machine file undo history is unavailable")
    }
    nonisolated(unsafe) static var presentURLs: ([URL], FilePresentationAction) -> Bool = {
        urls, action in
        switch action {
        case .open: return urls.allSatisfy { NSWorkspace.shared.open($0) }
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(urls); return true
        }
    }
    static func remoteDirectoryTarget(_ query: String) async throws -> CLIRemoteDirectoryTarget {
        let runner = try await MachineResolver.runner(query)
        return CLIRemoteDirectoryTarget(
            machine: runner.machine,
            endpoint: .remote(machine: runner.machine, connection: runner.ssh),
            platform: await runner.ssh.remotePlatform ?? .linux)
    }
    static func remoteTransferTarget(_ query: String) async throws -> CLITransferTarget {
        let runner = try await MachineResolver.runner(query)
        return CLITransferTarget(
            machine: runner.machine,
            endpoint: .remote(machine: runner.machine, connection: runner.ssh))
    }
}

@MainActor enum MachinesCLIExecution {
    static func run(_ request: ExtensionCLIRequest) async throws -> ExtensionCLIReply {
        try await ExtensionCLIExecution.run(MachinesCommand.self, request: rewrite(request))
    }

    static func rewrite(_ request: ExtensionCLIRequest) throws -> ExtensionCLIRequest {
        try request.validate()
        return try ExtensionCLIRequest(
            arguments: MachineCLIArguments.rewrite(request.arguments),
            standardInput: request.standardInput, workingDirectory: request.workingDirectory,
            interactive: request.interactive)
    }
}

struct MachineCLIArguments {
    let name: String
    let aliases: [String]
    let children: [MachineCLIArguments]

    init(_ command: ParsableCommand.Type) {
        name = command.configuration.commandName ?? command._commandName
        aliases = command.configuration.aliases
        children = command.configuration.subcommands.map(Self.init)
    }

    func child(_ word: String) -> Self? {
        children.first { $0.name == word || $0.aliases.contains(word) }
    }

    static var machineSubcommands: Set<String> {
        Set(Self(MachinesCommand.self).children.flatMap { [$0.name] + $0.aliases })
    }

    static func rewrite(_ arguments: [String]) -> [String] {
        let arguments = arguments.first == "machines" ? Array(arguments.dropFirst()) : arguments
        guard let machine = arguments.first, !machine.hasPrefix("-"),
            !machineSubcommands.contains(machine), machine != "help"
        else { return arguments }
        let tail = Array(arguments.dropFirst())
        guard !tail.isEmpty else { return ["show", machine] }
        var node = Self(MachinesCommand.self)
        var consumed: [String] = []
        for word in tail {
            guard !word.hasPrefix("-"), let next = node.child(word) else { break }
            node = next
            consumed.append(word)
        }
        let remainder = Array(tail.dropFirst(consumed.count))
        guard !consumed.isEmpty else {
            return tail.contains { !$0.hasPrefix("-") }
                ? ["exec", machine, "--"] + tail : ["show", machine] + tail
        }
        return consumed + [machine] + (node.name == "exec" ? ["--"] : []) + remainder
    }
}
