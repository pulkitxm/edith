import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostCoreCommandRuntimeTests {
    @Test func actualQueueExecutesSeparatedBytesAndRetainsResultAndEventsAcrossRestart()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = try HostCoreRuntime(identity: fixture.identity, environment: { [:] })
        try await runtime.startCommands()
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'out\\000tail'; printf 'err\\377' >&2; exit 7"],
            environment: [:], currentDirectoryURL: fixture.directory, timeout: 5,
            maximumOutputBytes: 2 << 20, terminatesProcessGroup: true)
        let submission = HostAgentTaskSubmission(
            operation: HostAgentTaskOperation.command, title: "Synthetic owned command",
            payload: try HostAgentPayload.encode(request))
        let snapshot: HostAgentTaskSnapshot = try await call(runtime, .submit, submission)
        let result = try await terminal(runtime, snapshot.id)
        #expect(result.snapshot.state == .failed && result.snapshot.failureCode == "commandExit")
        let command = try HostAgentPayload.decode(
            CLICommandResult.self, from: #require(result.result))
        #expect(command.terminationStatus == 7)
        #expect(command.standardOutputData == Data([111, 117, 116, 0, 116, 97, 105, 108]))
        #expect(command.standardErrorData == Data([101, 114, 114, 255]))
        #expect(
            runtime.snapshot().commandTasks?.contains {
                $0.id == snapshot.id && $0.state == .failed
            } == true)
        await runtime.shutdown()
        let reopened = try HostCoreRuntime(identity: fixture.identity, environment: { [:] })
        try await reopened.startCommands()
        let retained: HostAgentTaskStatus = try await call(
            reopened, .status, HostAgentTaskIDRequest(id: snapshot.id))
        #expect(retained == result)
        #expect(
            reopened.snapshot().agent?.events.contains {
                $0.taskID == snapshot.id && $0.name == "task.failed"
            } == true)
        await reopened.shutdown()
    }

    @Test func queueCancellationAndCoreShutdownDrainActualOwnedCommandGroups() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = try HostCoreRuntime(identity: fixture.identity, environment: { [:] })
        try await runtime.startCommands()
        let pidFile = fixture.directory.appendingPathComponent("pid")
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$ > pid; exec /bin/sleep 120"], environment: [:],
            currentDirectoryURL: fixture.directory, timeout: 120, maximumOutputBytes: 2 << 20,
            terminatesProcessGroup: true)
        let submission = HostAgentTaskSubmission(
            operation: HostAgentTaskOperation.command, title: "Synthetic owned sleep",
            payload: try HostAgentPayload.encode(request))
        let snapshot: HostAgentTaskSnapshot = try await call(runtime, .submit, submission)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline
        { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(
            Int32(
                String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(
                    in: .whitespacesAndNewlines)))
        #expect(getpgid(pid) == pid && pid != getpid())
        let cancelled: HostAgentTaskSnapshot = try await call(
            runtime, .cancel, HostAgentTaskIDRequest(id: snapshot.id))
        #expect([.cancelling, .cancelled].contains(cancelled.state))
        let finished = try await terminal(runtime, snapshot.id)
        #expect(finished.snapshot.state == .cancelled)
        await runtime.shutdown()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(runtime.snapshot().commandTasks?.allSatisfy { $0.state.isTerminal } == true)
        await #expect(throws: HostAgentCommandError.self) {
            try await runtime.command(.init(operation: .list))
        }
    }

    private func call<T: Decodable>(
        _ runtime: HostCoreRuntime, _ operation: HostAgentCommandOperation,
        _ payload: some Encodable
    ) async throws -> T {
        try HostAgentPayload.decode(
            T.self,
            from: await runtime.command(
                .init(operation: operation, payload: HostAgentPayload.encode(payload))
            ).encoded())
    }
    private func terminal(_ runtime: HostCoreRuntime, _ id: UUID) async throws
        -> HostAgentTaskStatus
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let status: HostAgentTaskStatus = try await call(
                runtime, .status, HostAgentTaskIDRequest(id: id))
            if status.snapshot.state.isTerminal { return status }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostWorkerError.timedOut
    }
    private struct Fixture {
        let directory: URL
        let identity: HostIdentity
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "core-wire-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.wire-" + UUID().uuidString,
                supportDirectory: directory)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
