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

    @Test func validatesDecodedArgumentsAndOutputLimitsBeforeExecution() throws {
        for arguments in [
            [], ["bad\0"], [String(repeating: "x", count: 4_097)],
            Array(repeating: "x", count: 129),
        ] {
            let bytes = try JSONSerialization.data(withJSONObject: ["arguments": arguments])
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
