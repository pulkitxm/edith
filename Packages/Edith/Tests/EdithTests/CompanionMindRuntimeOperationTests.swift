import Foundation
import Testing

@testable import EdithCLI
@testable import EdithCore
@testable import EdithKit

@Suite struct CompanionMindRuntimeOperationTests {
    @Test func everyOperationDeclaresItsStableContract() {
        let descriptors = CompanionMindRuntimeOperation.allCases.map(\.descriptor)

        #expect(descriptors.count == 7)
        #expect(Set(descriptors.map(\.id)).count == 7)
        #expect(Set(descriptors.map(\.cli)).count == 7)
        #expect(descriptors.allSatisfy { !$0.requiresPreview })
        #expect(
            Set(descriptors.map(\.cli))
                == [
                    ["companion", "nightly"],
                    ["companion", "core", "set"],
                    ["companion", "inquire", "next"],
                    ["companion", "stack", "up"],
                    ["companion", "stack", "down"],
                    ["companion", "stack", "restart"],
                    ["companion", "deploy"],
                ])
        #expect(CompanionMindRuntimeOperation.inquireNext.descriptor.effect == .read)
        #expect(
            CompanionMindRuntimeOperation.allCases.filter { $0 != .inquireNext }
                .allSatisfy { $0.descriptor.effect == .write })
    }

    @Test func everyOperationRegistersItsExactUIPlacement() {
        let descriptorIDs = Set(
            CompanionMindRuntimeOperation.allCases.map { $0.descriptor.id.rawValue })
        let actions = UserInterfaceActionCatalog.actions.filter {
            descriptorIDs.contains($0.operation.id.rawValue)
        }

        #expect(actions.count == 8)
        #expect(Set(actions.map { $0.operation.id.rawValue }) == descriptorIDs)
        #expect(
            actions.contains {
                $0.surface == "Companion mind"
                    && $0.cli == ["companion", "core", "set", "values", "honest"]
            })
        #expect(
            actions.contains {
                $0.surface == "Companion setup" && $0.cli == ["companion", "deploy"]
            })
    }

    @Test func APIExecutionPreservesArgumentsAndResults() async {
        let nightly = await CompanionMindRuntimeOperationExecution.nightly {
            CompanionNightlyStart(runId: "run-7")
        }
        let core = await CompanionMindRuntimeOperationExecution.setCore(
            section: "values", content: "honest"
        ) { section, content in
            #expect(section == "values")
            #expect(content == "honest")
            return CompanionWriteAck(ok: true, section: section)
        }
        let question = await CompanionMindRuntimeOperationExecution.nextQuestion {
            CompanionNextQuestion(question: nil, askedToday: 1, dailyBudget: 3)
        }

        #expect(nightly.runId == "run-7")
        #expect(core.ok)
        #expect(core.section == "values")
        #expect(question.askedToday == 1)
        #expect(question.dailyBudget == 3)
    }

    @Test func deploymentUsesTheSelectedHostAndOverrides() {
        let id = UUID()
        let host = CompanionHost(
            id: id, name: "box", target: "box.local", isLocal: false,
            reachable: true, facts: nil)
        let deployment = CompanionMindRuntimeOperationExecution.deployment(
            host: host, directory: "/srv/companion", localPort: 9000)

        #expect(deployment.machineID == id)
        #expect(deployment.machineName == "box")
        #expect(deployment.directory == "/srv/companion")
        #expect(deployment.localPort == 9000)
    }

    @Test func stackExecutionBuildsTheCanonicalCommands() async throws {
        let deployment = CompanionDeployment(
            machineID: nil, machineName: "this Mac", directory: "/srv/companion",
            tier: CompanionTier.cpu.rawValue, localPort: 4820)
        var calls: [(String, TimeInterval)] = []
        let runner: (String, CompanionDeployment, TimeInterval) async throws -> String = {
            command, received, timeout in
            #expect(received == deployment)
            calls.append((command, timeout))
            return command
        }

        _ = try await CompanionMindRuntimeOperationExecution.start(
            deployment, build: true, using: runner)
        _ = try await CompanionMindRuntimeOperationExecution.stop(
            deployment, wipe: false, using: runner)
        _ = try await CompanionMindRuntimeOperationExecution.stop(
            deployment, wipe: true, using: runner)
        _ = try await CompanionMindRuntimeOperationExecution.restart(
            deployment, using: runner)

        #expect(calls.count == 4)
        #expect(calls[0].0.contains("up"))
        #expect(calls[0].0.contains("--build"))
        #expect(calls[0].1 == 1800)
        #expect(!calls[1].0.hasSuffix(" -v"))
        #expect(calls[1].1 == 300)
        #expect(calls[2].0.hasSuffix(" -v"))
        #expect(calls[3].0.contains("restart"))
        #expect(calls[3].1 == 600)
    }

    @Test func plainTextMatchesTheCLIContract() {
        #expect(
            CompanionMindRuntimeOperationText.nightly(CompanionNightlyStart(runId: "run-7"))
                == "pipeline finished, run run-7; see `ed companion runs`")
        #expect(CompanionMindRuntimeOperationText.coreSet("values") == "rewrote values")
    }

    @Test func completionTreeHasEverySharedOperationAsAnExactLeaf() throws {
        for operation in CompanionMindRuntimeOperation.allCases {
            let node = try #require(CommandTree.node(at: operation.descriptor.cli))
            #expect(node.children.isEmpty)
        }
        let down = try #require(CommandTree.node(at: ["companion", "stack", "down"]))
        #expect(down.destructivePolicy == .previewThenYes)
        #expect(down.options.contains("--wipe"))
        #expect(down.options.contains("--yes"))
    }

    @Test func missingBackendsKeepStableErrorsAndExitCodes() async {
        for arguments in [
            ["companion", "nightly"],
            ["companion", "nightly", "--json"],
            ["companion", "core", "set", "values", "honest", "--json"],
            ["companion", "inquire", "next", "--json"],
        ] {
            let result = await CLIProbe.run(arguments)
            #expect(result.code == ExitCodes.unavailable, "\(arguments) exited \(result.code)")
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("companion backend"))
        }

        for verb in ["up", "restart"] {
            let result = await CLIProbe.run(["companion", "stack", verb, "--json"])
            #expect(result.code == ExitCodes.notFound, "\(verb) exited \(result.code)")
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("not deployed anywhere"))
        }
    }
}
