import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@Suite(.serialized) @MainActor struct ExtensionCLIExecutionTests {
    @Test func preservesOriginalParserHelpValidationAndExitCodes() async throws {
        let help = try await ExtensionCLIExecution.run(FixtureCommand.self, arguments: ["--help"])
        #expect(help.exitCode == 0)
        #expect(help.stdout.contains("USAGE: fixture"))
        #expect(help.stderr.isEmpty)
        let invalid = try await ExtensionCLIExecution.run(
            FixtureCommand.self, arguments: ["--missing"])
        #expect(invalid.exitCode == 2)
        #expect(invalid.stdout.isEmpty)
        #expect(invalid.stderr.contains("--missing"))
    }

    @Test func separatesStdoutAndStderrWithoutOpeningAnotherProcess() async throws {
        let output = try await ExtensionCLIExecution.run(
            FixtureCommand.self, arguments: ["synthetic"])
        #expect(output.stdout == "synthetic\n")
        #expect(output.stderr == "synthetic diagnostic\n")
        #expect(output.exitCode == 0)
        let unavailable = try await ExtensionCLIExecution.run(
            FixtureCommand.self, arguments: ["unavailable"])
        #expect(unavailable.exitCode == 4)
        #expect(
            unavailable.stderr
                == "error: synthetic unavailable\nhint: enable the owning extension\n")
    }

    @Test func boundsOutputAndRestoresItsSinkAfterFailure() async throws {
        await #expect(throws: ExtensionPeerError.self) {
            try await ExtensionCLIExecution.run(FixtureCommand.self, arguments: ["oversized"])
        }
        let next = try await ExtensionCLIExecution.run(FixtureCommand.self, arguments: ["next"])
        #expect(next.stdout == "next\n")
    }

    @Test func cancellationDrainsBeforeAnotherCommandCanStart() async throws {
        let task = Task {
            try await ExtensionCLIExecution.run(FixtureCommand.self, arguments: ["wait"])
        }
        while !FixtureCommand.waiting { await Task.yield() }
        await #expect(throws: ExtensionPeerError.self) {
            try await ExtensionCLIExecution.run(FixtureCommand.self, arguments: ["second"])
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let next = try await ExtensionCLIExecution.run(FixtureCommand.self, arguments: ["after"])
        #expect(next.stdout == "after\n")
    }

    @Test func requestContextIsScopedAndRestoredAfterCancellation() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let input = Data("synthetic plan".utf8)
        let request = try ExtensionCLIRequest(
            arguments: ["context"], standardInput: input, workingDirectory: "/tmp/synthetic",
            interactive: true)
        let reply = try await ExtensionCLIExecution.run(FixtureCommand.self, request: request)
        #expect(reply.stdout == "/tmp/synthetic/plan.json\nsynthetic plan\ntrue\n")
        #expect(FileManager.default.currentDirectoryPath == cwd)
        #expect(ExtensionCLIContext.request == nil)
        let task = Task {
            try await ExtensionCLIExecution.run(
                FixtureCommand.self,
                request: ExtensionCLIRequest(
                    arguments: ["wait"], standardInput: input, workingDirectory: "/tmp/synthetic"))
        }
        while !FixtureCommand.waiting { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ExtensionCLIContext.request == nil)
        #expect(ExtensionCLIContext.outputSink == nil)
        #expect(
            try await ExtensionCLIExecution.run(FixtureCommand.self, arguments: ["after"]).stdout
                == "after\n")
    }

    @Test func validatesInputAndDirectoryBoundsIncludingDecodedValues() throws {
        for path in ["relative", "", "/bad\0", "/" + String(repeating: "x", count: 4_096)] {
            #expect(throws: ExtensionPeerError.self) {
                try ExtensionCLIRequest(arguments: [], workingDirectory: path)
            }
        }
        #expect(throws: ExtensionPeerError.self) {
            try ExtensionCLIRequest(
                arguments: [], standardInput: Data(count: ExtensionCLIRequest.maximumInputBytes + 1)
            )
        }
        let request = try ExtensionCLIRequest(
            arguments: [], standardInput: Data(count: ExtensionCLIRequest.maximumInputBytes),
            workingDirectory: "/tmp")
        try request.validate()
    }

    @Test func destructivePreviewRequiresConfirmationAndPreservesJSON() async throws {
        let preview = try await ExtensionCLIExecution.run(DestructiveCommand.self, arguments: [])
        #expect(preview.stdout == "would remove: synthetic\n")
        #expect(preview.stderr == "nothing changed; pass --yes to apply this plan\n")
        #expect(DestructiveCommand.applied == 0)
        let json = try await ExtensionCLIExecution.run(
            DestructiveCommand.self, arguments: ["--json"])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect(object["applied"] as? Bool == false)
        #expect(object["changed"] as? Bool == false)
        let confirmed = try await ExtensionCLIExecution.run(
            DestructiveCommand.self, arguments: ["--yes"])
        #expect(confirmed.stdout == "removed synthetic\n")
        #expect(DestructiveCommand.applied == 1)
    }

    @Test func validatesDecodedArgumentsAndOutputLimitsBeforeExecution() throws {
        for arguments in [
            ["bad\0"], [String(repeating: "x", count: 4_097)],
            Array(repeating: "x", count: 129),
        ] {
            let bytes = try JSONSerialization.data(withJSONObject: [
                "arguments": arguments, "standardInput": "", "workingDirectory": "/",
                "interactive": false,
            ])
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: bytes)
            #expect(throws: ExtensionPeerError.self) { try request.validate() }
        }
        let bytes = Data("{\"stdout\":\"\",\"stderr\":\"\",\"exitCode\":256}".utf8)
        let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: bytes)
        #expect(throws: ExtensionPeerError.self) { try reply.validate() }
    }
}

private struct FixtureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fixture")
    @MainActor static var waiting = false
    @Argument var value = "synthetic"
    @MainActor mutating func run() async throws {
        switch value {
        case "context":
            let request = try #require(ExtensionCLIContext.request)
            CLIOut.out(try ExtensionCLIContext.resolvePath("plan.json").path)
            CLIOut.out(String(decoding: request.standardInput, as: UTF8.self))
            CLIOut.out(String(request.interactive))
        case "wait":
            Self.waiting = true
            defer { Self.waiting = false }
            try await Task.sleep(for: .seconds(30))
        case "oversized":
            CLIOut.raw(String(repeating: "x", count: ExtensionCLIReply.maximumOutputBytes + 1))
        case "unavailable":
            throw CLIFailure.unavailable(
                "synthetic unavailable", hint: "enable the owning extension")
        default: CLIOut.out(value); CLIOut.note("synthetic diagnostic")
        }
    }
}

private struct DestructiveCommand: AsyncParsableCommand {
    @MainActor static var applied = 0
    @Flag var yes = false
    @Flag var json = false
    @MainActor mutating func run() async throws {
        let plan = CLIDestructivePlan(
            action: "remove", targets: ["synthetic"], confirmed: yes, json: json)
        guard plan.shouldApply() else { return }
        Self.applied += 1
        plan.finish(changed: true, plain: "removed synthetic")
    }
}
