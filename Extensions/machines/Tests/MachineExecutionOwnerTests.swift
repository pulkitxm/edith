import Foundation
import Testing

@testable import MachinesExtension

@Suite struct MachineExecutionOwnerTests {
    private func process(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        return process
    }

    @Test func rawStreamingKeepsSeparateOutputAndMissingFinalNewlines() async throws {
        let output = ByteStreamRecorder()
        let stream = SSHLineStream(
            process: process(
                "printf 'stdout without newline'; printf 'stderr without newline' >&2; exit 23"),
            onLine: { _, _ in Issue.record("Raw mode must not emit line records") },
            onExit: { _ in }, onData: { output.append($0, error: $1) })
        let owner = MachineExecutionOwner()
        try owner.start(stream)
        #expect(await stream.waitForExit() == 23)
        #expect(output.stdout == Data("stdout without newline".utf8))
        #expect(output.stderr == Data("stderr without newline".utf8))
        owner.release(stream)
        await owner.shutdown()
    }

    @Test func disableCancelsOnlyOwnedProcessesAndRejectsNewExecutions() async throws {
        let owner = MachineExecutionOwner()
        let retained = process("exec sleep 30")
        let unrelated = process("exec sleep 30")
        let unrelatedOwner = MachineExecutionOwner()
        let unrelatedStream = SSHLineStream(
            process: unrelated, onLine: { _, _ in }, onExit: { _ in })
        try unrelatedOwner.start(unrelatedStream)
        do {
            let stream = SSHLineStream(process: retained, onLine: { _, _ in }, onExit: { _ in })
            try owner.start(stream)
            await owner.shutdown()
            #expect(await stream.waitForExit() == 130)
            #expect(!retained.isRunning)
            #expect(unrelated.isRunning)
            let rejected = SSHLineStream(
                process: process("exit 0"), onLine: { _, _ in }, onExit: { _ in })
            #expect(throws: CancellationError.self) { try owner.start(rejected) }
        } catch {
            await unrelatedOwner.shutdown()
            throw error
        }
        await unrelatedOwner.shutdown()
        #expect(!unrelated.isRunning)
    }
}

private final class ByteStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()
    var stdout: Data { lock.withLock { output } }
    var stderr: Data { lock.withLock { error } }
    func append(_ data: Data, error: Bool) {
        lock.withLock {
            if error { self.error.append(data) } else { output.append(data) }
        }
    }
}
