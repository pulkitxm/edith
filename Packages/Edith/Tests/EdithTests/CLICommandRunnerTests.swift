import Darwin
import EdithKit
import Foundation
import Testing

@Suite struct CLICommandRunnerTests {
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
