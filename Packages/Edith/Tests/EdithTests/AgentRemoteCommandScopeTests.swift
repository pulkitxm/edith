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
        let firstWorker = Task { try await run(first.command, receive: { firstPID.receive($0) }) }
        let secondWorker = Task {
            try await run(second.command, receive: { secondPID.receive($0) })
        }
        defer { firstWorker.cancel(); secondWorker.cancel() }
        var phase = "waiting for child processes"
        let cleanupOutput = RemoteScopeCleanupTrace()
        var knownProcesses: [Int32] = []
        do {
            let firstChild = try await waitForPID(firstPID)
            let secondChild = try await waitForPID(secondPID)
            let firstGroup = getpgid(firstChild)
            let secondGroup = getpgid(secondChild)
            knownProcesses = [firstChild, secondChild, firstGroup, secondGroup]
            #expect(firstGroup > 0 && secondGroup > 0 && firstGroup != secondGroup)
            #expect(kill(firstChild, 0) == 0)
            #expect(kill(secondChild, 0) == 0)
            phase = "cleaning the first session"
            let firstCleanup = try await run(
                traced(first.cleanupCommand),
                receive: { cleanupOutput.receive($0, stream: "stdout") },
                receiveError: { cleanupOutput.receive($0, stream: "stderr") })
            #expect(firstCleanup.terminationStatus == 0)
            try #require(firstCleanup.standardOutput == "matched:\(firstGroup)\n")
            phase = "waiting for the first session to exit"
            _ = try await firstWorker.value
            #expect(kill(firstChild, 0) != 0)
            #expect(kill(secondChild, 0) == 0)
            phase = "cleaning the second session"
            let secondCleanup = try await run(
                traced(second.cleanupCommand),
                receive: { cleanupOutput.receive($0, stream: "stdout") },
                receiveError: { cleanupOutput.receive($0, stream: "stderr") })
            #expect(secondCleanup.terminationStatus == 0)
            try #require(secondCleanup.standardOutput == "matched:\(secondGroup)\n")
            phase = "waiting for the second session to exit"
            _ = try await secondWorker.value
            #expect(kill(secondChild, 0) != 0)
        } catch {
            let rows = await diagnostics(processes: knownProcesses)
            Issue.record(
                "Remote cleanup failed while \(phase): \(error). Cleanup: \(cleanupOutput.text). Processes: \(rows)"
            )
            firstWorker.cancel()
            secondWorker.cancel()
            _ = try? await firstWorker.value
            _ = try? await secondWorker.value
            throw error
        }
    }

    @Test func cleanupOfAnAbsentSessionReturnsNoMatchedGroups() async throws {
        let scope = AgentRemoteCommandScope(command: "true")
        let result = try await run(scope.cleanupCommand)
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput.isEmpty)
    }

    private func traced(_ command: String) -> String {
        command.replacingOccurrences(of: "exec sh -c ", with: "exec sh -x -c ")
    }

    private func diagnostics(processes: [Int32]) async -> String {
        let pids = Set(processes.filter { $0 > 0 }).sorted().map(String.init)
        guard !pids.isEmpty else { return "No child process was reported." }
        do {
            let result = try await CLICommandRunner.runLocalSeparated(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/ps"),
                    arguments: [
                        "-ww", "-p", pids.joined(separator: ","), "-o",
                        "pid=,ppid=,pgid=,stat=,args=",
                    ],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 2, maximumOutputBytes: 4096, terminatesProcessGroup: true),
                streamsWhileRunning: false, onStandardOutputLine: { _ in },
                onStandardErrorLine: { _ in })
            return result.standardOutput + result.standardError
        } catch { return error.localizedDescription }
    }

    private func run(
        _ command: String, input: Data? = nil,
        receive: @escaping @Sendable (String) -> Void = { _ in },
        receiveError: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CLICommandResult {
        try await CLICommandRunner.runLocalSeparated(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
                environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"], timeout: 5,
                maximumOutputBytes: 128 << 10, standardInputData: input,
                terminatesProcessGroup: true),
            streamsWhileRunning: true, onStandardOutputLine: receive,
            onStandardErrorLine: receiveError)
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

private final class RemoteScopeCleanupTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    func receive(_ line: String, stream: String) {
        lock.withLock {
            bytes.append(contentsOf: (stream + ": " + line + "\n").utf8)
            if bytes.count > 4096 { bytes.removeFirst(bytes.count - 4096) }
        }
    }
}
