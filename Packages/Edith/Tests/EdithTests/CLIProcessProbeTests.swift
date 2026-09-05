import Darwin
import Foundation
import Testing

@Suite(.serialized) struct CLIProcessProbeTests {
    @Test func nativeLaunchOwnsItsGroupAndPreservesEnvironmentAndDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-cli-probe-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try CLIProcessProbe.run(
            [
                "-c",
                "printf '%s\\n' \"$$\" \"$PPID\" \"$PROBE_VALUE\"; "
                    + "/bin/ps -p \"$$\" -o pgid=; /bin/pwd -P; printf native-error >&2; exit 17",
            ], executable: URL(fileURLWithPath: "/bin/sh"), currentDirectory: directory,
            environment: ["PATH": "/usr/bin:/bin", "PROBE_VALUE": "space value"], timeout: 3)
        let lines = result.stdoutLines
        try #require(lines.count == 5)
        #expect(Int32(lines[0]) == Int32(lines[3].trimmingCharacters(in: .whitespaces)))
        #expect(Int32(lines[1]) == getpid())
        #expect(lines[2] == "space value")
        let expectedDirectory = try FileManager.default.attributesOfItem(atPath: directory.path)
        let actualDirectory = try FileManager.default.attributesOfItem(atPath: lines[4])
        #expect(
            try #require(actualDirectory[.systemNumber] as? NSNumber)
                == #require(expectedDirectory[.systemNumber] as? NSNumber))
        #expect(
            try #require(actualDirectory[.systemFileNumber] as? NSNumber)
                == #require(expectedDirectory[.systemFileNumber] as? NSNumber))
        #expect(result.stderr == "native-error")
        #expect(result.code == 17)
    }

    @Test func largeStandardStreamsDrainWithoutBlockingEachOther() throws {
        let bytes = 1_048_576
        let result = try CLIProcessProbe.run(
            [
                "-c",
                "/usr/bin/yes E | /usr/bin/head -c \(bytes) >&2; "
                    + "/usr/bin/yes O | /usr/bin/head -c \(bytes)",
            ], executable: URL(fileURLWithPath: "/bin/sh"), timeout: 3)

        #expect(result.code == 0)
        #expect(result.stdout.utf8.count == bytes)
        #expect(result.stderr.utf8.count == bytes)
    }

    @Test func argumentsStreamsAndExitStatusPassThroughExactly() throws {
        let arguments = ["space value", "single'quote", "$HOME; exit 0", ""]
        let result = try CLIProcessProbe.run(
            [
                "-c",
                "printf '%s\\n' \"$1\" \"$2\" \"$3\" \"$4\"; "
                    + "printf 'failure text' >&2; exit 23",
                "probe",
            ] + arguments,
            executable: URL(fileURLWithPath: "/bin/sh"))

        #expect(result.code == 23)
        #expect(result.stdout == arguments.joined(separator: "\n") + "\n")
        #expect(result.stderr == "failure text")
    }

    @Test func timeoutTerminatesTheEntireProcessGroup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-cli-probe-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pids")
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try CLIProcessProbe.run(
                [
                    "-c",
                    "printf '%s\\n' \"$$\" > \"$1\"; "
                        + "(trap '' TERM; while :; do sleep 60; done) & "
                        + "printf '%s\\n' \"$!\" >> \"$1\"; trap '' TERM; wait",
                    "probe", pidFile.path,
                ], executable: URL(fileURLWithPath: "/bin/sh"), timeout: 1)
            Issue.record("expected the process probe to time out")
        } catch let error as CLIProcessProbeError {
            #expect(
                error
                    == .timedOut(
                        executable: "/bin/sh",
                        arguments: [
                            "-c",
                            "printf '%s\\n' \"$$\" > \"$1\"; "
                                + "(trap '' TERM; while :; do sleep 60; done) & "
                                + "printf '%s\\n' \"$!\" >> \"$1\"; trap '' TERM; wait",
                            "probe", pidFile.path,
                        ], seconds: 1))
        }

        #expect(clock.now - started < .seconds(4))
        let pids = try String(contentsOf: pidFile, encoding: .utf8)
            .split(separator: "\n").compactMap { Int32($0) }
        #expect(pids.count == 2)
        let deadline = clock.now + .seconds(2)
        while pids.contains(where: Self.isAlive), clock.now < deadline { usleep(20_000) }
        #expect(!pids.contains(where: Self.isAlive))
    }

    @Test func timeoutDuringExitCleanupKillsTheRemainingDescendant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-cli-probe-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFile = directory.appendingPathComponent("pid")
        let exitFile = directory.appendingPathComponent("exited")
        var descendantPID: Int32?
        defer {
            if let descendantPID, Self.isAlive(descendantPID) { kill(descendantPID, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
        let arguments = [
            "-c",
            "(trap '' TERM; while :; do sleep 60; done) & "
                + "printf '%s\\n' \"$!\" > \"$1\"; sleep 1.5; "
                + "printf exited > \"$2\"; exit 19",
            "probe", pidFile.path, exitFile.path,
        ]
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try CLIProcessProbe.run(
                arguments, executable: URL(fileURLWithPath: "/bin/sh"), timeout: 2)
            Issue.record("expected the process probe to time out during cleanup")
        } catch let error as CLIProcessProbeError {
            #expect(
                error
                    == .timedOut(
                        executable: "/bin/sh", arguments: arguments, seconds: 2))
        }

        #expect(clock.now - started < .seconds(5))
        #expect(try String(contentsOf: exitFile, encoding: .utf8) == "exited")
        let pid = try #require(
            Int32(
                String(contentsOf: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
        descendantPID = pid
        let deadline = clock.now + .seconds(2)
        while Self.isAlive(pid), clock.now < deadline { usleep(20_000) }
        #expect(!Self.isAlive(pid))
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        errno = 0
        return kill(pid, 0) == 0 || errno != ESRCH
    }
}
