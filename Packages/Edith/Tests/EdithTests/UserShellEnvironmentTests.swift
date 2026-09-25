import Foundation
import Testing

@testable import EdithKit

@Suite struct UserShellEnvironmentTests {
    @Test func parsesOnlyTheEnvironmentBetweenMarkers() {
        let output =
            Data("Last login: today\nBEGIN".utf8)
            + Data("PATH=/opt/mise/shims:/usr/bin\0SSH_AUTH_SOCK=/tmp/agent\0PAIR=a=b\0".utf8)
            + Data("END\nlogout".utf8)

        let parsed = UserShellEnvironment.parse(output, begin: "BEGIN", end: "END")

        #expect(
            parsed == [
                "PATH": "/opt/mise/shims:/usr/bin", "SSH_AUTH_SOCK": "/tmp/agent", "PAIR": "a=b",
            ])
    }

    @Test func rejectsOutputWithoutMarkersOrPath() {
        #expect(
            UserShellEnvironment.parse(Data("PATH=/usr/bin\0".utf8), begin: "B", end: "E") == nil)
        #expect(UserShellEnvironment.parse(Data("BHOME=/tmp\0E".utf8), begin: "B", end: "E") == nil)
    }

    @Test func toolEnvironmentPrefersTheShellPathAndImportsUserVariables() throws {
        let environment = CLIToolEnvironment.sanitized(
            processEnvironment: [
                "PATH": "/usr/bin:/bin", "EDITH_DATA_ROOT": "/private/tmp/edith-data",
                "TMPDIR": "/private/tmp/process",
            ],
            shellEnvironment: [
                "PATH": "/opt/mise/shims:/usr/bin", "SSH_AUTH_SOCK": "/tmp/agent",
                "OPENAI_API_KEY": "synthetic", "VOLTA_HOME": "/Users/example/.volta",
                "PWD": "/somewhere", "SHLVL": "2",
                "TERM": "dumb", "EDITH_DATA_ROOT": "/elsewhere", "TMPDIR": "/private/tmp/shell",
            ])
        let path = try #require(environment["PATH"]).split(separator: ":").map(String.init)

        #expect(try #require(path.firstIndex(of: "/opt/mise/shims")) < 2)
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["VOLTA_HOME"] == "/Users/example/.volta")
        #expect(environment["PWD"] == nil)
        #expect(environment["SHLVL"] == nil)
        #expect(environment["TERM"] == nil)
        #expect(environment["EDITH_DATA_ROOT"] == "/private/tmp/edith-data")
        #expect(environment["TMPDIR"] == "/private/tmp/process")
    }

    @Test func explicitProcessValuesWinOverShellExports() {
        let environment = CLIToolEnvironment.sanitized(
            processEnvironment: ["PATH": "/usr/bin", "CODEX_HOME": "/private/tmp/isolated"],
            shellEnvironment: ["PATH": "/usr/bin", "CODEX_HOME": "/Users/example/.codex"])

        #expect(environment["CODEX_HOME"] == "/private/tmp/isolated")
    }

    @Test func localeAndDynamicLoaderVariablesStayOut() {
        for key in ["LANG", "LC_ALL", "LC_CTYPE", "DYLD_INSERT_LIBRARIES", "BASH_ENV", "TZ"] {
            #expect(!UserShellEnvironment.imports(key))
        }
        #expect(UserShellEnvironment.imports("HOMEBREW_PREFIX"))
    }

    @Test func failedCapturesBackOffExponentially() {
        #expect(UserShellEnvironment.retryInterval(afterFailures: 1) == 300)
        #expect(UserShellEnvironment.retryInterval(afterFailures: 3) == 1_200)
        #expect(UserShellEnvironment.retryInterval(afterFailures: 20) == 21_600)
    }

    @Test func userEnvironmentUsesTheShellPathVerbatim() {
        let environment = UserShellEnvironment.userEnvironment(
            process: ["PATH": "/usr/bin:/bin", "EDITH_DATA_ROOT": "/private/tmp/edith-data"],
            shell: [
                "PATH": "/Users/example/.local/bin:/usr/bin",
                "CODEX_HOME": "/Users/example/.codex2",
                "PWD": "/somewhere", "EDITH_DATA_ROOT": "/elsewhere",
            ])

        #expect(environment["PATH"] == "/Users/example/.local/bin:/usr/bin")
        #expect(environment["CODEX_HOME"] == "/Users/example/.codex2")
        #expect(environment["PWD"] == nil)
        #expect(environment["EDITH_DATA_ROOT"] == "/private/tmp/edith-data")
        #expect(
            UserShellEnvironment.userEnvironment(process: ["PATH": "/usr/bin"], shell: nil)
                == ["PATH": "/usr/bin"])
    }

    @Test func capturesOnceAndRecapturesWhenAnRcFileChangesOrAges() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = home.appendingPathComponent(".zshrc")
        try Data("export PATH=/one:$PATH\n".utf8).write(to: rc)
        let clock = TestClock()
        let captures = CaptureCounter()
        let environment = UserShellEnvironment(
            shell: URL(fileURLWithPath: "/bin/zsh"), home: home, baseEnvironment: [:],
            now: { clock.now },
            capture: { _, _, _ in ["PATH": "/v\(captures.next())"] })

        #expect(environment.current() == nil)
        environment.enable()
        await environment.settled()
        #expect(environment.current()?["PATH"] == "/v1")

        clock.advance(by: 6)
        #expect(environment.current()?["PATH"] == "/v1")
        #expect(captures.count == 1)

        try Data("export PATH=/two:$PATH\n# edited\n".utf8).write(to: rc)
        clock.advance(by: 6)
        _ = environment.current()
        await environment.settled()
        #expect(environment.current()?["PATH"] == "/v2")

        clock.advance(by: 6)
        _ = environment.current()
        await environment.settled()
        #expect(captures.count == 2)

        clock.advance(by: UserShellEnvironment.maximumAge)
        _ = environment.current()
        await environment.settled()
        #expect(environment.current()?["PATH"] == "/v3")

        await environment.refresh()
        #expect(environment.current()?["PATH"] == "/v4")
    }

    @Test func fingerprintNoticesEditsInsideWatchedDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = directory.appendingPathComponent("homebrew")
        try Data("/opt/homebrew/bin\n".utf8).write(to: entry)
        let before = UserShellEnvironment.fingerprint([directory.path])

        let handle = try FileHandle(forWritingTo: entry)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("/opt/homebrew/sbin\n".utf8))
        try handle.close()

        #expect(UserShellEnvironment.fingerprint([directory.path]) != before)
    }

    @Test func fallbackNodeVersionsPreferTheNewestRelease() {
        let versions = ["v9.11.2", "v18.9.1", "v22.3.0", "v18.10.0"]
        #expect(
            versions.sorted(by: CLIToolEnvironment.nodeVersionOrder)
                == ["v22.3.0", "v18.10.0", "v18.9.1", "v9.11.2"])
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current += interval }
    }
}

private final class CaptureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
