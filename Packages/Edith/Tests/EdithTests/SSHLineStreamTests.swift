import Foundation
import Testing

@testable import EdithKit

private final class StreamLines: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, Bool)] = []

    func append(_ line: String, _ stderr: Bool) {
        lock.lock()
        values.append((line, stderr))
        lock.unlock()
    }

    func read() -> [(String, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite struct SSHLineStreamLifecycleTests {
    private func process(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        return process
    }

    @Test func reportsTheProcessExitStatus() async throws {
        let stream = SSHLineStream(
            process: process("exit 27"), onLine: { _, _ in }, onExit: { _ in })
        try stream.start()
        #expect(await stream.waitForExit() == 27)
    }

    @Test func waitingAfterExitReturnsTheStoredStatus() async throws {
        let stream = SSHLineStream(
            process: process("exit 19"), onLine: { _, _ in }, onExit: { _ in })
        try stream.start()
        #expect(await stream.waitForExit() == 19)
        #expect(await stream.waitForExit() == 19)
    }

    @Test func everyConcurrentWaiterReceivesTheSameStatus() async throws {
        let stream = SSHLineStream(
            process: process("sleep 0.05; exit 11"), onLine: { _, _ in }, onExit: { _ in })
        try stream.start()
        let statuses = await withTaskGroup(of: Int32.self, returning: [Int32].self) { group in
            for _ in 0..<100 {
                group.addTask { await stream.waitForExit() }
            }
            var values: [Int32] = []
            for await status in group { values.append(status) }
            return values
        }
        #expect(statuses.count == 100)
        #expect(statuses.allSatisfy { $0 == 11 })
    }

    @Test func cancellationResumesTheWait() async throws {
        let stream = SSHLineStream(
            process: process("sleep 30"), onLine: { _, _ in }, onExit: { _ in })
        try stream.start()
        let task = Task { await stream.waitForExit() }
        await Task.yield()
        task.cancel()
        #expect(await task.value == 130)
    }

    @Test func cancellationBeforeWaitingIsStored() async throws {
        let stream = SSHLineStream(
            process: process("sleep 30"), onLine: { _, _ in }, onExit: { _ in })
        try stream.start()
        stream.cancel()
        #expect(await stream.waitForExit() == 130)
    }

    @Test func trailingOutputIsDeliveredBeforeCompletion() async throws {
        let lines = StreamLines()
        let stream = SSHLineStream(
            process: process("printf trailing"),
            onLine: { lines.append($0, $1) }, onExit: { _ in })
        try stream.start()
        #expect(await stream.waitForExit() == 0)
        #expect(lines.read().map(\.0) == ["trailing"])
    }

    @Test func stdoutAndStderrStaySeparated() async throws {
        let lines = StreamLines()
        let stream = SSHLineStream(
            process: process("printf 'out\\n'; printf 'err\\n' >&2"),
            onLine: { lines.append($0, $1) }, onExit: { _ in })
        try stream.start()
        #expect(await stream.waitForExit() == 0)
        let values = lines.read()
        #expect(values.contains { value in value.0 == "out" && !value.1 })
        #expect(values.contains { value in value.0 == "err" && value.1 })
    }
}
