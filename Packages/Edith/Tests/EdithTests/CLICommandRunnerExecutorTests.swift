import Darwin
import Foundation
import Testing

@testable import EdithKit

@Suite struct CLICommandRunnerExecutorTests {
    @Test func waitingCommandsLeaveOneCooperativeWorkerAvailableForTheirReleaser() async throws {
        if ProcessInfo.processInfo.environment["EDITH_RUNNER_EXECUTOR_FIXTURE"] == "1" {
            try await exerciseConcurrentCommands()
            return
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes {
            proc_pidpath(getpid(), $0.baseAddress, UInt32($0.count))
        }
        #expect(length > 0)
        let launcher = String(cString: path)
        let bundle = try #require(Bundle(for: RunnerExecutorAnchor.self).executableURL)
        var environment = ProcessInfo.processInfo.environment
        environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1"
        environment["EDITH_RUNNER_EXECUTOR_FIXTURE"] = "1"
        let result: CLICommandResult = try await CLICommandRunner.runLocalSeparated(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: launcher),
                arguments: [
                    "--test-bundle-path", bundle.path, "--no-parallel", "--filter",
                    "CLICommandRunnerExecutorTests", "--testing-library", "swift-testing",
                ],
                environment: environment, timeout: 15, maximumOutputBytes: 64 << 10,
                terminatesProcessGroup: true),
            onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
        let diagnostic: String = result.standardOutput + "\n" + result.standardError
        #expect(result.terminationStatus == 0, "\(diagnostic)")
    }

    private func exerciseConcurrentCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appendingPathComponent("release")
        let ready = RunnerExecutorReadiness()
        let command =
            "printf 'ready\\n'; while [ ! -f \(ShellQuote.quote(release.path)) ]; do sleep 0.02; done; printf 'released\\n'"
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
            environment: ["PATH": "/usr/bin:/bin"], timeout: 5,
            maximumOutputBytes: 1024, terminatesProcessGroup: true)
        let first = Task { try await run(request, ready: ready) }
        let second = Task { try await run(request, ready: ready) }
        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while ready.count < 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(ready.count == 2)
            let released = try await CLICommandRunner.runLocalSeparated(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                    arguments: [release.path], environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 2, terminatesProcessGroup: true),
                onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
            #expect(released.terminationStatus == 0)
            #expect(try await first.value.standardOutput == "ready\nreleased\n")
            #expect(try await second.value.standardOutput == "ready\nreleased\n")
        } catch {
            first.cancel(); second.cancel()
            _ = try? await first.value
            _ = try? await second.value
            throw error
        }
    }

    private func run(_ request: CLICommandRequest, ready: RunnerExecutorReadiness) async throws
        -> CLICommandResult
    {
        try await CLICommandRunner.runLocalSeparated(
            request, streamsWhileRunning: true,
            onStandardOutputLine: { if $0 == "ready" { ready.received() } },
            onStandardErrorLine: { _ in })
    }
}

private final class RunnerExecutorAnchor: NSObject {}

private final class RunnerExecutorReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var lines = 0
    var count: Int { lock.withLock { lines } }
    func received() { lock.withLock { lines += 1 } }
}
