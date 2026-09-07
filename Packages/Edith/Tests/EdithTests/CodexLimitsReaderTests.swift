import Darwin
import Foundation
import Testing

@testable import EdithKit

@Suite struct CodexLimitsReaderTests {
    private let handshake = """
        import json, sys, time
        first = json.loads(input())
        assert first['method'] == 'initialize'
        time.sleep(0.03)
        print(json.dumps({'id': 0, 'result': {}}), flush=True)
        assert json.loads(input())['method'] == 'initialized'
        assert json.loads(input())['method'] == 'account/rateLimits/read'
        """

    @Test func waitsForHandshakeAndResponseAndUsesTheMainAccountBucket() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("provider with spaces")
        try FileManager.default.createSymbolicLink(
            atPath: executable.path, withDestinationPath: "/bin/sh")
        let script =
            handshake + "\n" + """
                time.sleep(0.05)
                response = {'id': 1, 'result': {
                    'rateLimits': {'primary': {'usedPercent': 99, 'windowDurationMins': 300}},
                    'rateLimitsByLimitId': {'codex': {
                        'primary': {'usedPercent': 17, 'windowDurationMins': 10080, 'resetsAt': 2000000000}
                    }}
                }}
                encoded = json.dumps(response)
                sys.stdout.write(encoded[:20]); sys.stdout.flush()
                time.sleep(0.03)
                print(encoded[20:], flush=True)
                time.sleep(30)
                """
        let limits = try await CodexLimitsReader.read(
            executable: executable,
            arguments: ["-c", "exec /usr/bin/python3 \"$@\"", "provider", "-u", "-c", script],
            environment: ProcessInfo.processInfo.environment, timeout: 3)
        #expect(limits.session == nil)
        #expect(limits.week?.percent == 17)
        #expect(limits.week?.resetsAt == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test func legacySessionWindowDoesNotBecomeAWeeklyLimit() throws {
        let data = Data(
            """
            {"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":300}}}
            """.utf8)
        let limits = try CodexLimitsReader.limits(
            JSONDecoder().decode(CodexLimitsReader.Result.self, from: data))
        #expect(limits.session?.percent == 23)
        #expect(limits.week == nil)
    }

    @Test func providerErrorsRemainVisible() async throws {
        let script =
            handshake
            + "\nprint('{\"id\":1,\"error\":{\"message\":\"fixture unavailable\"}}', flush=True)\n"
        do {
            _ = try await CodexLimitsReader.read(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-u", "-c", script], environment: ProcessInfo.processInfo.environment,
                timeout: 3)
            Issue.record("Expected a provider error")
        } catch {
            #expect(error.localizedDescription.contains("fixture unavailable"))
        }
    }

    @Test func boundsUnresponsiveAndOversizedProviders() async {
        for (script, timeout, maximumBytes) in [
            ("import time; time.sleep(30)", 0.1, 1024),
            ("print('x' * 4096, flush=True)", 3.0, 1024),
        ] {
            await #expect(throws: CodexLimitsReader.Failure.self) {
                try await CodexLimitsReader.read(
                    executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-u", "-c", script],
                    environment: ProcessInfo.processInfo.environment,
                    timeout: timeout, maximumOutputBytes: maximumBytes)
            }
        }
    }

    @Test func cancellationStopsTheProviderProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let script =
            "import os, pathlib, sys, time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
        let task = Task {
            try await CodexLimitsReader.read(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-u", "-c", script, marker.path],
                environment: ProcessInfo.processInfo.environment)
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}
