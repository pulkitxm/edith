import Darwin
import EdithKit
import Foundation
import Testing

private final class CommandLineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

@Suite struct CLICommandRunnerTests {
    private func waitForSignal(
        _ semaphore: DispatchSemaphore, timeout: TimeInterval = 2
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    @Test func separatedStreamsKeepPartialFinalLinesOnTheirOwnChannels() async throws {
        let standardOutput = CommandLineRecorder()
        let standardError = CommandLineRecorder()
        let result = try await CLICommandRunner.runSeparated(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'event'; printf 'diagnostic' >&2"],
                environment: ["PATH": "/usr/bin:/bin"], timeout: 2,
                maximumOutputBytes: 1_024, terminatesProcessGroup: true),
            onStandardOutputLine: { standardOutput.append($0) },
            onStandardErrorLine: { standardError.append($0) })
        #expect(result.terminationStatus == 0)
        #expect(standardOutput.snapshot == ["event"])
        #expect(standardError.snapshot == ["diagnostic"])
    }

    @Test func separatedRunnerDoesNotReturnWhileACompletedCommandCallbackIsBlocked() async throws {
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let runnerFinished = DispatchSemaphore(value: 0)
        let task = Task {
            defer { runnerFinished.signal() }
            return try await CLICommandRunner.runSeparated(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf 'ready\\n'"],
                    environment: ["PATH": "/usr/bin:/bin"], timeout: 2,
                    maximumOutputBytes: 1_024, terminatesProcessGroup: true),
                onStandardOutputLine: { _ in
                    callbackStarted.signal()
                    releaseCallback.wait()
                },
                onStandardErrorLine: { _ in })
        }

        #expect(await waitForSignal(callbackStarted))
        #expect(!(await waitForSignal(runnerFinished, timeout: 0.1)))
        releaseCallback.signal()

        let result = try await task.value
        #expect(result.terminationStatus == 0)
    }

    @Test func separatedTimeoutDoesNotStartCallbacksThatCouldOutliveTheRunner() async throws {
        let callbackStarted = DispatchSemaphore(value: 0)
        let startedAt = ProcessInfo.processInfo.systemUptime

        do {
            _ = try await CLICommandRunner.runSeparated(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf 'ready\\n'; exec /bin/sleep 30"],
                    environment: ["PATH": "/usr/bin:/bin"], timeout: 0.1,
                    maximumOutputBytes: 1_024, terminatesProcessGroup: true),
                onStandardOutputLine: { _ in callbackStarted.signal() },
                onStandardErrorLine: { _ in callbackStarted.signal() })
            Issue.record("expected timeout")
        } catch let error as CLICommandRunnerError {
            #expect(error == .timedOut)
        }

        #expect(ProcessInfo.processInfo.systemUptime - startedAt < 2)
        #expect(!(await waitForSignal(callbackStarted, timeout: 0.01)))
    }

    @Test func cancellationTerminatesTheCommandAndItsDescendant() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let task = Task {
            try await CLICommandRunner.run(request(fixture, mode: "wait", timeout: 10)) { _ in }
        }
        let identifiers = try await processIdentifiers(fixture)

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {}
        try await expectGone(identifiers)
    }

    @Test func timeoutTerminatesTheCommandAndItsDescendant() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await CLICommandRunner.run(request(fixture, mode: "wait", timeout: 0.2)) {
                _ in
            }
            Issue.record("expected timeout")
        } catch let error as CLICommandRunnerError {
            #expect(error == .timedOut)
        }

        try await expectGone(try processIdentifiers(fixture))
    }

    @Test func outputOverflowTerminatesTheCommandAndItsDescendant() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await CLICommandRunner.run(
                request(fixture, mode: "overflow", timeout: 10, maximumOutputBytes: 1_024)
            ) { _ in }
            Issue.record("expected output overflow")
        } catch let error as CLICommandRunnerError {
            #expect(error == .outputLimitExceeded)
        }

        try await expectGone(try processIdentifiers(fixture))
    }

    private struct Fixture {
        let directory: URL
        let parent: URL
        let child: URL
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-command-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Fixture(
            directory: directory, parent: directory.appendingPathComponent("parent.pid"),
            child: directory.appendingPathComponent("child.pid"))
    }

    private func request(
        _ fixture: Fixture, mode: String, timeout: TimeInterval,
        maximumOutputBytes: Int? = nil
    ) -> CLICommandRequest {
        let script = """
            parent=$1
            child=$2
            mode=$3
            printf '%s\n' "$$" > "$parent"
            trap '' TERM
            /bin/sleep 30 &
            printf '%s\n' "$!" > "$child"
            if [ "$mode" = overflow ]; then
                while :; do printf '01234567890123456789012345678901'; done
            fi
            wait
            """
        return CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", script, "runner-test", fixture.parent.path, fixture.child.path, mode,
            ],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryURL: fixture.directory,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            discardsStandardError: true,
            terminatesProcessGroup: true)
    }

    private func processIdentifiers(_ fixture: Fixture) async throws -> [Int32] {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            if let parent = identifier(at: fixture.parent),
                let child = identifier(at: fixture.child)
            {
                return [parent, child]
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw CocoaError(.fileReadUnknown)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while true
    }

    private func processIdentifiers(_ fixture: Fixture) throws -> [Int32] {
        guard let parent = identifier(at: fixture.parent), let child = identifier(at: fixture.child)
        else { throw CocoaError(.fileReadUnknown) }
        return [parent, child]
    }

    private func identifier(at url: URL) -> Int32? {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines)
        else { return nil }
        return Int32(text)
    }

    private func expectGone(_ identifiers: [Int32]) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while identifiers.contains(where: isPresent) {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                Issue.record("process remained after runner termination")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func isPresent(_ identifier: Int32) -> Bool {
        errno = 0
        return kill(identifier, 0) == 0 || errno != ESRCH
    }
}
