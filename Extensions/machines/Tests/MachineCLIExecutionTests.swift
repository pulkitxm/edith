import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineCLIExecutionTests {
    private func isolated<Result>(_ action: () async throws -> Result) async throws -> Result {
        let previous = MachinePaths.root
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        MachinePaths.root = directory
        defer {
            MachinePaths.root = previous
            try? FileManager.default.removeItem(at: directory)
        }
        return try await action()
    }

    private func run(_ arguments: [String]) async throws -> ExtensionCLIReply {
        try await MachinesCLIExecution.run(ExtensionCLIRequest(arguments: arguments))
    }

    @Test func originalCommandsAndAliasesRemainReachable() async throws {
        let expected: Set<String> = [
            "ls", "show", "add", "edit", "rm", "forwards", "snippets", "metrics", "exec",
            "files", "docker", "services", "power", "thermal", "control", "kill", "broadcast",
            "terminal", "workspace", "connect", "disconnect", "mount", "unmount", "mounts",
        ]
        #expect(expected.isSubset(of: MachineCLIArguments.machineSubcommands))
        for command in MachinesCommand.configuration.subcommands {
            let name = command.configuration.commandName ?? command._commandName
            let reply = try await run([name, "--help"])
            #expect(reply.exitCode == 0)
            #expect(reply.stdout.contains("USAGE:"))
            #expect(reply.stderr.isEmpty)
        }
    }

    @Test func machineFirstSyntaxPreservesNestedCommandsAndPassthroughFlags() {
        #expect(
            MachineCLIArguments.rewrite(["box", "docker", "logs", "web", "--follow"]) == [
                "docker", "logs", "box", "web", "--follow",
            ])
        #expect(
            MachineCLIArguments.rewrite(["box", "uname", "-a"]) == [
                "exec", "box", "--", "uname", "-a",
            ])
        #expect(MachineCLIArguments.rewrite(["box", "--json"]) == ["show", "box", "--json"])
    }

    @Test func savedSnippetCRUDUsesOwnedRegistryAndOriginalDiagnostics() async throws {
        try await isolated {
            let machine = Machine(name: "fixture-box", host: "fixture.invalid")
            MachineRegistry.add(machine)
            let added = try await run(["snippets", "add", machine.name, "status", "uptime"])
            #expect(added.stdout == "saved status on fixture-box\n")
            #expect(added.stderr.isEmpty)
            #expect(added.exitCode == 0)
            #expect(MachineRegistry.snippets().first?.command == "uptime")
            let listed = try await run([machine.name, "snippets", "ls", "--json"])
            #expect(listed.exitCode == 0)
            let objects = try #require(
                JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]])
            #expect(objects.first?["title"] as? String == "status")
            let missing = try await run(["snippets", "rm", machine.name, "4"])
            #expect(missing.exitCode == 3)
            #expect(missing.stdout.isEmpty)
            #expect(missing.stderr.contains("error: there is no snippet 4 on fixture-box"))
            let removed = try await run(["snippets", "rm", machine.name, "1"])
            #expect(removed.stdout == "removed status\n")
            #expect(MachineRegistry.snippets().isEmpty)
        }
    }

    @Test func workspaceOperationsPersistOriginalPaneLayouts() async throws {
        try await isolated {
            let machine = Machine(name: "fixture-box", host: "fixture.invalid")
            MachineRegistry.add(machine)
            let created = try await run(["workspace", "new", machine.name, "--screen", "files"])
            #expect(created.exitCode == 0)
            #expect(WorkspaceStore.load().current?.paneCount == 1)
            #expect(WorkspaceStore.load().current?.subscribedMachines() == [machine.id])
            let listed = try await run(["workspace", "ls", "--json"])
            #expect(listed.exitCode == 0)
            #expect(listed.stdout.contains("fixture-box"))
        }
    }

    @Test func unknownMachineKeepsNotFoundExitAndEmptyStdout() async throws {
        try await isolated {
            let reply = try await run(["show", "missing"])
            #expect(reply.exitCode == 3)
            #expect(reply.stdout.isEmpty)
            #expect(reply.stderr.hasPrefix("error: no machines are configured\n"))
        }
    }
}
