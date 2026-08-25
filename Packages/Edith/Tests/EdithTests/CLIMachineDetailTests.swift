import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIMachineDetailTests {
    @Test func newDetailRoutesParseWithPlainAndJSONForms() throws {
        #expect(
            try EdRoot.parseAsRoot(["machines", "docker", "inspect", "box", "api"])
                is DockerInspectCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "machines", "docker", "top", "--json", "box", "api",
            ]) is DockerTopCommand)
        #expect(
            try EdRoot.parseAsRoot(["machines", "snippets", "run", "--json", "box", "1"])
                is MachinesSnippetsRunCommand)
    }

    @Test func completionTreeContainsEveryNewOperationLeaf() {
        for descriptor in DockerDetailOperation.allCases.map(\.descriptor)
            + SavedSnippetOperation.allCases.map(\.descriptor)
        {
            var node: CommandNode? = CommandTree.root
            for segment in descriptor.cli {
                node = node?.child(segment)
            }
            #expect(node?.name == descriptor.cli.last)
            #expect(node?.children.isEmpty == true)
        }
    }

    @Test func completionOffersEveryDetailLeafMachineAndFlag() {
        let docker = Self.completion(["ed", "machines", "docker", ""], index: 3)
        let snippets = Self.completion(["ed", "machines", "snippets", ""], index: 3)
        let machine = Self.completion(
            ["ed", "machines", "docker", "inspect", "B"], index: 4)
        let flag = Self.completion(
            ["ed", "machines", "docker", "top", "Box", "api", "--j"], index: 6)

        #expect(docker.candidates.contains("inspect"))
        #expect(docker.candidates.contains("top"))
        #expect(snippets.candidates.contains("run"))
        #expect(machine.candidates == ["Box"])
        #expect(flag.candidates == ["--json"])
    }

    @Test func reportsUseStableStructuredKeys() {
        let summary = DockerInspectSummary(
            image: "api:latest", command: "serve", created: "today", restartPolicy: "always",
            environment: ["PORT=80"], mounts: ["/src -> /dst"], networks: ["backend"],
            labels: ["service": "api"])
        let inspect = JSONSerializer.string(MachineReports.inspect(summary), pretty: false)
        #expect(inspect.contains("\"restartPolicy\":\"always\""))
        #expect(inspect.contains("\"environment\":[\"PORT=80\"]"))

        let process = DockerProcess(
            pid: "42", user: "app", cpu: "1.2", memory: "0.4", command: "serve")
        let top = JSONSerializer.string(MachineReports.process(process), pretty: false)
        #expect(
            top
                == "{\"command\":\"serve\",\"cpuPercent\":\"1.2\",\"memoryPercent\":\"0.4\",\"pid\":\"42\",\"user\":\"app\"}"
        )
    }

    @Test func missingSnippetFailsBeforeOpeningAConnection() async {
        await CLIProbe.inWorld { _ in
            let machine = Machine(name: "Box", host: "invalid.example")
            MachineRegistry.add(machine)
            let result = await CLIProbe.capture([
                "machines", "snippets", "run", "box", "1", "--json",
            ])
            #expect(result.code == ExitCodes.notFound)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("There is no snippet 1"))
        }
    }

    @Test func snippetSelectionPinsTheMachineAndSnippetIdentityTogether() async throws {
        try await CLIProbe.inWorld { _ in
            let original = Machine(name: "Box", host: "old.example")
            let snippet = CommandSnippet(
                machineID: original.id, title: "Status", command: "uptime")
            MachineRegistry.add(original)
            MachineRegistry.addSnippet(snippet)

            let selection = try SnippetBridge.selection("box", index: 1)
            MachineRegistry.remove(id: original.id)
            MachineRegistry.add(Machine(name: "Box", host: "new.example"))

            #expect(selection.machine.id == original.id)
            #expect(selection.machine.host == "old.example")
            #expect(selection.snippet.id == snippet.id)
            #expect(selection.snippet.machineID == selection.machine.id)
        }
    }

    @Test func failedSnippetOutputPreservesBothRemoteStreams() throws {
        do {
            _ = try SnippetBridge.output(
                stdout: "partial output\n", stderr: "failure detail\n", status: 7,
                machineName: "Box")
            Issue.record("Expected a failed saved command")
        } catch let failure as CLIFailure {
            #expect(failure.message == "saved command exited 7 on Box")
            #expect(failure.hint == "partial output\nfailure detail")
        }
    }

    private static func completion(_ words: [String], index: Int) -> CompletionResult {
        CompletionEngine.plan(
            CompletionRequest(words: words, index: index), machines: ["Box"], configKeys: [],
            extensionIDs: [])
    }
}
