import Foundation
import Testing
@testable import HerdrUI

@Suite struct ClaudeAccountTests {
    @Test func simultaneousAccountsHaveIsolatedCredentialsAndConfigDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = "synthetic-'token;$(touch forbidden)"
        let personal = ClaudeAccount(name: "Personal", credential: token)
        let company = ClaudeAccount(
            name: "Company", authentication: .apiKey, credential: "synthetic-api-key")
        let first = try personal.launcher(command: "/usr/bin/env", arguments: [], directory: root)
        let second = try company.launcher(command: "/usr/bin/env", arguments: [], directory: root)
        let personalEnvironment = try run(first)
        let companyEnvironment = try run(second)
        #expect(personalEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] == token)
        #expect(personalEnvironment["ANTHROPIC_API_KEY"] == nil)
        #expect(companyEnvironment["ANTHROPIC_API_KEY"] == "synthetic-api-key")
        #expect(companyEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(personalEnvironment["CLAUDE_CONFIG_DIR"] != companyEnvironment["CLAUDE_CONFIG_DIR"])
        #expect(personalEnvironment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(personalEnvironment["CLAUDE_CODE_USE_BEDROCK"] == nil)
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    @Test func browserLoginClearsCredentialsAndKeepsTheConfigPathAcrossRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var account = ClaudeAccount(name: "Work", authentication: .browserLogin)
        let first = try account.launcher(command: "/usr/bin/env", arguments: [], directory: root)
        account.name = "Company"
        let second = try account.launcher(command: "/usr/bin/env", arguments: [], directory: root)
        #expect(first.deletingLastPathComponent() == second.deletingLastPathComponent())
        try FileManager.default.removeItem(at: first)
        let environment = try run(second)
        #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_PROFILE"] == nil)
    }

    @Test func invalidAndIncompleteAccountsCannotLaunch() throws {
        #expect(throws: (any Error).self) { try ClaudeAccount(name: "Work").validateLaunch() }
        #expect(throws: (any Error).self) { try ClaudeAccount(name: " ").validate() }
        #expect(throws: (any Error).self) {
            try ClaudeAccount(name: "Work", credential: "bad\0token").validate()
        }
        let account = ClaudeAccount(name: "Work")
        #expect(throws: (any Error).self) {
            try ClaudeAccountsState(accounts: [account, account]).validate()
        }
        #expect(throws: (any Error).self) {
            try ClaudeAccountsState(accounts: [account], defaultID: UUID()).validate()
        }
    }

    private func run(_ launcher: URL) throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [launcher.path]
        process.currentDirectoryURL = launcher.deletingLastPathComponent()
        process.environment = [
            "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "wrong-api-key",
            "CLAUDE_CODE_OAUTH_TOKEN": "wrong-token", "ANTHROPIC_AUTH_TOKEN": "wrong-auth",
            "ANTHROPIC_PROFILE": "wrong-profile", "CLAUDE_CODE_USE_BEDROCK": "1",
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return Dictionary(
            String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                let parts = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }, uniquingKeysWith: { _, last in last })
    }
}
