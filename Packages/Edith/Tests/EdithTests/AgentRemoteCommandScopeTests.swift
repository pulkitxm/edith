import Darwin
import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentRemoteCommandScopeTests {
    @Test func scopedCommandsPreserveBinaryStreamsAndExitStatus() async throws {
        let scope = AgentRemoteCommandScope(command: "cat; printf diagnostic >&2; exit 17")
        let bytes = Data((0..<65_536).map { UInt8($0 % 256) })
        let result = try await run(scope.command, input: bytes)
        #expect(result.standardOutputData == bytes)
        #expect(result.standardError == "diagnostic")
        #expect(result.terminationStatus == 17)
    }

    @Test func cleanupTerminatesOnlyItsMatchingSessionGroup() async throws {
        let command = "sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait"
        let first = AgentRemoteCommandScope(command: command)
        let second = AgentRemoteCommandScope(command: command)
        let firstPID = RemoteScopePID()
        let secondPID = RemoteScopePID()
        let firstWorker = Task { try await run(first.command, receive: firstPID.receive) }
        let secondWorker = Task { try await run(second.command, receive: secondPID.receive) }
        defer { firstWorker.cancel(); secondWorker.cancel() }
        let firstChild = try await waitForPID(firstPID)
        let secondChild = try await waitForPID(secondPID)
        #expect(kill(firstChild, 0) == 0)
        #expect(kill(secondChild, 0) == 0)
        #expect(try await run(first.cleanupCommand).terminationStatus == 0)
        _ = try await firstWorker.value
        #expect(kill(firstChild, 0) != 0)
        #expect(kill(secondChild, 0) == 0)
        #expect(try await run(second.cleanupCommand).terminationStatus == 0)
        _ = try await secondWorker.value
        #expect(kill(secondChild, 0) != 0)
    }

    private func run(
        _ command: String, input: Data? = nil,
        receive: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CLICommandResult {
        try await CLICommandRunner.runLocalSeparated(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
                environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"], timeout: 5,
                maximumOutputBytes: 128 << 10, standardInputData: input,
                terminatesProcessGroup: true),
            streamsWhileRunning: true, onStandardOutputLine: receive,
            onStandardErrorLine: { _ in })
    }

    private func waitForPID(_ value: RemoteScopePID) async throws -> Int32 {
        for _ in 0..<100 {
            if let pid = value.value { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AgentError(.failed, "The command did not report its child process.")
    }
}

private final class RemoteScopePID: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    var value: Int32? { lock.withLock { pid } }
    func receive(_ line: String) { lock.withLock { pid = Int32(line) } }
}
