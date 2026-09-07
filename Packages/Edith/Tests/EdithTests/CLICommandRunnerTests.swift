import Darwin
@testable import EdithKit
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

    @Test func nativeCompletionWinsWhenTheObserverResumesAfterItsDeadline() async throws {
        let observed = DispatchSemaphore(value: 0)
        let completion = DispatchSemaphore(value: 0)
        let process = try CLIChildProcess(
            request: CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                environment: [:],
                terminatesProcessGroup: true),
            input: -1, output: -1, error: -1,
            onExit: {
                completion.signal(); observed.signal()
            })
        #expect(await waitForSignal(observed))
        #expect(!process.isRunning)
        let deadline = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(30))
        #expect(CLICommandRunner.pollForExit(completion, deadline: deadline) == .finished)
        #expect(
            CLICommandRunner.pollForExit(DispatchSemaphore(value: 0), deadline: deadline)
                == .timedOut)
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
        #expect(result.standardOutput == "event")
        #expect(result.standardError == "diagnostic")
        #expect(result.output == "eventdiagnostic")
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

    @Test func nativeExitReleasesItsProcessSourceOwnership() async throws {
        let finished = DispatchSemaphore(value: 0)
        weak var released: CLIChildProcess?
        do {
            let process = try CLIChildProcess(
                request: CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 7"],
                    environment: [:], terminatesProcessGroup: true),
                input: -1, output: -1, error: -1, onExit: { finished.signal() })
            released = process
            #expect(await waitForSignal(finished))
            #expect(process.terminationStatus == 7)
        }
        let deadline = Date().addingTimeInterval(2)
        while released != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(released == nil)
    }

    @Test func nativeLaunchPreservesArgumentsEnvironmentDirectoryAndBinaryInput() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = Data([0, 1, 127, 128, 255, 10])
        let result = try await CLICommandRunner.runLocalSeparated(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf '%s|%s|%s|%s\\n' \"$PPID\" \"$TEST_VALUE\" \"$PWD\" \"$1\" >&2; exec /bin/cat",
                    "native-test", "literal \"quoted\" value",
                ],
                environment: ["PATH": "/usr/bin:/bin", "TEST_VALUE": "native value"],
                currentDirectoryURL: fixture.directory, timeout: 3,
                standardInputData: input, terminatesProcessGroup: true),
            onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutputData == input)
        let fields = result.standardError.trimmingCharacters(in: .newlines).split(separator: "|")
            .map(String.init)
        #expect(fields.count == 4)
        #expect(fields.first == String(getpid()))
        #expect(fields.dropFirst().first == "native value")
        let returnedDirectory = try #require(fields.dropFirst(2).first)
        #expect(
            URL(fileURLWithPath: String(returnedDirectory)).resolvingSymlinksInPath()
                == fixture.directory.resolvingSymlinksInPath())
        #expect(fields.last == "literal \"quoted\" value")
    }

    @Test func concurrentCommandsHaveDistinctOwnedGroupsAndCancelIndependently() async throws {
        let first = try makeFixture()
        let second = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }
        let left = Task {
            try await CLICommandRunner.runLocal(request(first, mode: "wait", timeout: 10)) { _ in }
        }
        let right = Task {
            try await CLICommandRunner.runLocal(request(second, mode: "wait", timeout: 10)) { _ in }
        }
        defer {
            left.cancel()
            right.cancel()
        }
        let leftIDs = try await processIdentifiers(first)
        let rightIDs = try await processIdentifiers(second)
        #expect(getpgid(leftIDs[0]) == leftIDs[0])
        #expect(getpgid(leftIDs[1]) == leftIDs[0])
        #expect(getpgid(rightIDs[0]) == rightIDs[0])
        #expect(getpgid(rightIDs[1]) == rightIDs[0])
        #expect(leftIDs[0] != rightIDs[0])
        left.cancel()
        await #expect(throws: CancellationError.self) { try await left.value }
        try await expectGone(leftIDs)
        #expect(rightIDs.allSatisfy(isPresent))
        right.cancel()
        await #expect(throws: CancellationError.self) { try await right.value }
        try await expectGone(rightIDs)
    }

    @Test func successfulParentExitStillTerminatesItsBackgroundDescendant() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try await CLICommandRunner.runLocalSeparated(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", "sleep 30 & printf '%s\\n' \"$!\" > \"$1\"", "native-test",
                    fixture.child.path,
                ],
                environment: ["PATH": "/usr/bin:/bin"], timeout: 3, terminatesProcessGroup: true),
            onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
        #expect(result.terminationStatus == 0)
        #expect(result.standardError.isEmpty)
        let child = try #require(identifier(at: fixture.child))
        try await expectGone([child])
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
