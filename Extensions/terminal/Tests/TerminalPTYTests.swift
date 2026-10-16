import Darwin
import Foundation
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalPTYTests {
    private func launch(_ command: String) -> TerminalLaunch {
        TerminalLaunch(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
            currentDirectory: "/private/tmp", startupCommand: nil)
    }

    private func collect(_ terminal: TerminalPTY) async throws -> (Data, Int32?) {
        var bytes = Data()
        var offset: UInt64 = 0
        for _ in 0..<1000 {
            try Task.checkCancellation()
            let next = try terminal.read(after: offset)
            bytes.append(next.bytes)
            offset = next.nextOffset
            if let code = next.exitCode { return (bytes, code) }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Owned fixture PTY did not finish")
        return (bytes, nil)
    }

    @Test func actualPTYHasTerminalDescriptorsWorkingDirectoryAndExactExitStatus() async throws {
        let terminal = try TerminalPTY(
            launch: launch("test -t 0 && test -t 1 && printf 'tty:%s' \"$PWD\"; exit 7"))
        defer { terminal.close() }
        let (bytes, code) = try await collect(terminal)
        #expect(String(decoding: bytes, as: UTF8.self) == "tty:/private/tmp")
        #expect(code == 7)
    }

    @Test func inputResizeAndCursorReplayUseTheOwnedPTY() async throws {
        let terminal = try TerminalPTY(
            launch: launch("read value; printf '%s:' \"$value\"; stty size"))
        defer { terminal.close() }
        try terminal.resize(columns: 101, rows: 37)
        try terminal.send(Data("synthetic-input\n".utf8))
        let (bytes, code) = try await collect(terminal)
        #expect(String(decoding: bytes, as: UTF8.self) == "synthetic-input:37 101\n")
        #expect(code == 0)
        let replay = try terminal.read(after: 0)
        #expect(replay.bytes == bytes)
        #expect(throws: POSIXError.self) { try terminal.read(after: UInt64(bytes.count + 1)) }
        #expect(throws: POSIXError.self) { try terminal.resize(columns: 0, rows: 1) }
    }

    @Test func outputOverflowRejectsStaleCursorsInsteadOfSilentlyLosingBytes() async throws {
        let terminal = try TerminalPTY(launch: launch("head -c 400000 /dev/zero"))
        defer { terminal.close() }
        var cursor: UInt64 = 0
        for _ in 0..<1000 {
            let next = try terminal.read(after: cursor)
            cursor = next.nextOffset
            if next.exitCode != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cursor == 400000)
        #expect(throws: POSIXError.self) { try terminal.read(after: 0) }
        let replay = try terminal.read(after: cursor - 100)
        #expect(replay.bytes == Data(repeating: 0, count: 100))
    }

    @Test func shutdownTerminatesAndReapsTheExactOwnedChild() async throws {
        let terminal = try TerminalPTY(launch: launch("printf '%s' $$; exec cat"))
        defer { terminal.close() }
        var bytes = Data()
        for _ in 0..<100 where bytes.isEmpty {
            bytes = try terminal.read(after: 0).bytes
            if bytes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }
        let pid = try #require(Int32(String(decoding: bytes, as: UTF8.self)))
        #expect(kill(pid, 0) == 0)
        terminal.close()
        for _ in 0..<100 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func inputAndOutputAreBoundedAndClosedSessionsRejectOperations() async throws {
        let terminal = try TerminalPTY(launch: launch("exec cat"))
        #expect(throws: POSIXError.self) {
            try terminal.send(Data(repeating: 65, count: TerminalPTY.maximumInputBytes + 1))
        }
        terminal.close()
        terminal.close()
        #expect(throws: POSIXError.self) { try terminal.read(after: 0) }
        #expect(throws: POSIXError.self) { try terminal.send(Data([65])) }
    }
}
