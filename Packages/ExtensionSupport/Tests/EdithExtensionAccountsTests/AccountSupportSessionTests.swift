import Darwin
import Foundation
import Testing
@testable import EdithExtensionAccounts

@Suite struct AccountSupportSessionTests {
    private func fixture() throws -> URL {
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Synthetic Accounts's", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func hookCommand(_ arguments: [String]) throws -> String {
        #expect(arguments.count == 2)
        #expect(arguments.first == "--settings")
        let encoded = try #require(arguments.last)
        let parsed = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        let settings = try #require(parsed as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: [[String: Any]]])
        let group = try #require(hooks["SessionStart"]?.first?["hooks"] as? [[String: Any]])
        #expect(group.first?["type"] as? String == "command")
        return try #require(group.first?["command"] as? String)
    }

    private func run(_ command: String, input: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(Data(input.utf8))
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func event(_ session: String, source: String = "startup") -> String {
        "{\"session_id\":\"\(session)\",\"cwd\":\"/synthetic/project\",\"hook_event_name\":\"SessionStart\",\"source\":\"\(source)\"}"
    }

    @Test func launchHookRecordsEverySessionPrivatelyAndLatestAccountWins() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let first = UUID()
        let second = UUID()
        #expect(try ClaudeAccountSessions.accounts(directory: directory).isEmpty)
        let firstHook = try hookCommand(
            ClaudeAccountSessions.launchArguments(account: first, directory: directory))
        let secondHook = try hookCommand(
            ClaudeAccountSessions.launchArguments(account: second, directory: directory))
        try run(firstHook, input: event("synthetic-start"))
        try run(firstHook, input: event("synthetic-clear", source: "clear"))
        try run(firstHook, input: event("synthetic-resumed"))
        try run(secondHook, input: event("synthetic-resumed", source: "resume"))
        let ledger = directory.appendingPathComponent("sessions.jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: ledger.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(
            try ClaudeAccountSessions.accounts(directory: directory) == [
                "synthetic-start": first, "synthetic-clear": first, "synthetic-resumed": second,
            ])
    }

    @Test func malformedLedgerLinesAreIgnored() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let account = UUID()
        let lines = [
            "not json",
            "{\"account\":\"not-a-uuid\",\"event\":{\"session_id\":\"synthetic-a\"}}",
            "{\"account\":\"\(account.uuidString)\",\"event\":{\"session_id\":\"\"}}",
            "{\"account\":\"\(account.uuidString)\"}",
            "{\"account\":\"\(account.uuidString)\",\"event\":{\"session_id\":\"synthetic-b\"}}",
        ]
        let ledger = directory.appendingPathComponent("sessions.jsonl")
        #expect(
            FileManager.default.createFile(
                atPath: ledger.path, contents: Data(lines.joined(separator: "\n").utf8),
                attributes: [.posixPermissions: 0o600]))
        #expect(
            try ClaudeAccountSessions.accounts(directory: directory) == ["synthetic-b": account])
    }

    @Test func sharedLedgerIsRejected() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let ledger = directory.appendingPathComponent("sessions.jsonl")
        #expect(
            FileManager.default.createFile(
                atPath: ledger.path, contents: Data(), attributes: [.posixPermissions: 0o644]))
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountSessions.accounts(directory: directory)
        }
    }
}
