import ArgumentParser
import EdithExtensionCommands
import Foundation
import Testing

@testable import MusicExtension

@MainActor @Suite struct MusicCommandExecutionTests {
    @Test func bodyRemainsOnMainActorAcrossSuspension() async throws {
        var visits = 0
        try await MusicCommandExecution.execute {
            MainActor.preconditionIsolated()
            visits += 1
            await Task.yield()
            MainActor.preconditionIsolated()
            visits += 1
        }
        #expect(visits == 2)
    }

    @Test func usageFailureKeepsItsExitCodeAndErrorOutput() async {
        let output = MusicCallbackRecorder<String>()
        await ExtensionCLIContext.$outputSink.withValue({ text, error in
            #expect(error)
            output.append(text)
        }) {
            await #expect(throws: ExitCode(2)) {
                try await MusicCommandExecution.execute {
                    throw CLIFailure.usage("synthetic failure", hint: "synthetic hint")
                }
            }
        }
        #expect(output.values == ["error: synthetic failure\n", "hint: synthetic hint\n"])
    }

    @Test func cancellationIsRethrownWithoutErrorOutput() async {
        let output = MusicCallbackRecorder<String>()
        await ExtensionCLIContext.$outputSink.withValue({ text, _ in output.append(text) }) {
            await #expect(throws: CancellationError.self) {
                try await MusicCommandExecution.execute { throw CancellationError() }
            }
        }
        #expect(output.values.isEmpty)
    }
}
