import Darwin
import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrUI

enum HerdrAccountFixture {
    static func root() throws -> URL {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("herdr-account-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    static func run(
        _ launcher: URL, home: URL, shell: String = "/bin/sh"
    ) async throws -> [String: String] {
        let result = try await CLICommandRunner.runLocal(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [launcher.path],
                environment: [
                    "PATH": "/usr/bin:/bin", "SHELL": shell, "HOME": home.path,
                    "ZDOTDIR": home.path, "TMPDIR": home.path,
                    "ANTHROPIC_API_KEY": "synthetic-inherited-key",
                    "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-inherited-token",
                    "ANTHROPIC_AUTH_TOKEN": "synthetic-inherited-auth",
                    "ANTHROPIC_PROFILE": "synthetic-inherited-profile",
                    "CLAUDE_CODE_USE_BEDROCK": "1",
                ], currentDirectoryURL: home, timeout: 5, maximumOutputBytes: 65_536,
                terminatesProcessGroup: true), onLine: { _ in })
        try #require(result.terminationStatus == 0)
        return Dictionary(
            result.standardOutput.split(separator: "\n").compactMap { line in
                let parts = line.split(
                    separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }, uniquingKeysWith: { _, last in last })
    }
}

@Suite struct HerdrAccountShellTests {
    @Test func freshCLIImportReadsChangedStartupWithoutInheritedAuthentication() async throws {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let startup = root.appendingPathComponent(".zshrc")
        let base = [
            "PATH": "/usr/bin:/bin", "ZDOTDIR": root.path, "TMPDIR": root.path,
            "ANTHROPIC_API_KEY": "synthetic-old-key",
            "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-old-token",
            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("old-profile").path,
        ]
        try Data("export CLAUDE_CODE_OAUTH_TOKEN=synthetic-fresh-token\n".utf8).write(to: startup)
        let first = try await ClaudeAccount.currentCLIEnvironment(
            shell: URL(fileURLWithPath: "/bin/zsh"), home: root, base: base)
        #expect(first["ANTHROPIC_API_KEY"] == nil)
        #expect(first["CLAUDE_CONFIG_DIR"] == nil)
        #expect(
            try ClaudeAccount.currentCLIAccount(environment: first).credential
                == "synthetic-fresh-token")
        try Data("export ANTHROPIC_API_KEY=synthetic-fresh-key\n".utf8).write(to: startup)
        let second = try await ClaudeAccount.currentCLIEnvironment(
            shell: URL(fileURLWithPath: "/bin/zsh"), home: root, base: base)
        #expect(second["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        let imported = try ClaudeAccount.currentCLIAccount(environment: second)
        #expect(imported.authentication == .apiKey)
        #expect(imported.credential == "synthetic-fresh-key")
        try Data().write(to: startup)
        let third = try await ClaudeAccount.currentCLIEnvironment(
            shell: URL(fileURLWithPath: "/bin/zsh"), home: root, base: base)
        let saved = Data(
            #"{"claudeAiOauth":{"accessToken":"synthetic-saved-token","refreshToken":"synthetic-refresh"}}"#
                .utf8)
        let login = try ClaudeAccount.currentCLIAccount(environment: third, savedLoginData: saved)
        #expect(login.authentication == .browserLogin)
        #expect(login.loginData == String(data: saved, encoding: .utf8))
    }

    @Test func sharedLiteralOptionsAndAliasesRespectEachSelectedAccount() async throws {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = HerdrUIDefaults()
        try HerdrLaunchSettings.setSharedClaudeLaunch(
            arguments: "FLAG_VALUE=two words",
            environment: "IS_DEMO=1\nLITERAL=$(touch forbidden); 'quoted'", in: defaults)
        try Data(
            "export CLAUDE_CODE_OAUTH_TOKEN=synthetic-startup-token\nalias cc='/usr/bin/env'\n"
                .utf8
        ).write(to: root.appendingPathComponent(".zshrc"))
        HerdrLaunchSettings.setCommand("cc", for: "Claude Code", in: defaults)
        let accounts = [
            ClaudeAccount(name: "Company", credential: "synthetic-company"),
            ClaudeAccount(name: "Personal", credential: "synthetic-personal"),
        ]
        let directory = root.appendingPathComponent("accounts")
        let storage = ClaudeAccountStorage(directory: directory)
        try await storage.save(.init(accounts: accounts))
        let command = HerdrLaunchSettings.launchCommand(for: "Claude Code", in: defaults)
        let arguments = HerdrLaunchSettings.launchArguments(
            kind: "Claude Code", options: .none, in: defaults)
        var profiles = Set<String>()
        for account in accounts {
            let launcher = try await account.launcher(
                command: command, arguments: arguments, directory: directory)
            let environment = try await HerdrAccountFixture.run(
                launcher, home: root, shell: "/bin/zsh")
            #expect(environment["FLAG_VALUE"] == "two words")
            #expect(environment["IS_DEMO"] == "1")
            #expect(environment["LITERAL"] == "$(touch forbidden); 'quoted'")
            #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == account.credential)
            #expect(environment["ANTHROPIC_API_KEY"] == nil)
            #expect(environment["CLAUDE_CONFIG_DIR"] == launcher.deletingLastPathComponent().path)
            profiles.insert(try #require(environment["CLAUDE_CONFIG_DIR"]))
            #expect(!FileManager.default.fileExists(atPath: launcher.path))
        }
        #expect(profiles.count == 2)
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
        #expect(HerdrLaunchSettings.launchCommand(for: "Gemini", in: defaults) == "gemini")
        #expect(
            HerdrLaunchSettings.launchArguments(kind: "Gemini", options: .none, in: defaults)
                .isEmpty)
        for value in [
            "BAD-NAME=value", "MISSING_VALUE", "CLAUDE_CODE_OAUTH_TOKEN=wrong",
            "CLAUDE_CONFIG_DIR=/synthetic/wrong",
        ] {
            #expect(throws: ClaudeAccountError.self) {
                try HerdrLaunchSettings.setSharedClaudeLaunch(
                    arguments: "", environment: value, in: defaults)
            }
        }
        #expect(HerdrLaunchSettings.sharedArguments(in: defaults) == "FLAG_VALUE=two words")
    }

    @Test func simultaneousAuthenticationModesStayIsolatedAndBrowserRenameKeepsProfile()
        async throws
    {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = "synthetic-'token;$(touch forbidden)"
        let personal = ClaudeAccount(name: "Personal", credential: token)
        let company = ClaudeAccount(
            name: "Company", authentication: .apiKey, credential: "synthetic-key")
        var browser = ClaudeAccount(name: "Browser", authentication: .browserLogin)
        let directory = root.appendingPathComponent("accounts")
        let storage = ClaudeAccountStorage(directory: directory)
        try await storage.save(.init(accounts: [personal, company, browser]))
        let first = try await personal.launcher(
            command: "/usr/bin/env", arguments: [], directory: directory)
        let second = try await company.launcher(
            command: "/usr/bin/env", arguments: [], directory: directory)
        let third = try await browser.launcher(
            command: "/usr/bin/env", arguments: [], directory: directory)
        let personalEnvironment = try await HerdrAccountFixture.run(first, home: root)
        let companyEnvironment = try await HerdrAccountFixture.run(second, home: root)
        #expect(personalEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] == token)
        #expect(personalEnvironment["ANTHROPIC_API_KEY"] == nil)
        #expect(companyEnvironment["ANTHROPIC_API_KEY"] == company.credential)
        #expect(companyEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(personalEnvironment["CLAUDE_CONFIG_DIR"] != companyEnvironment["CLAUDE_CONFIG_DIR"])
        #expect(personalEnvironment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(personalEnvironment["CLAUDE_CODE_USE_BEDROCK"] == nil)
        browser.name = "Renamed browser"
        try await storage.save(.init(accounts: [personal, company, browser]))
        let renamed = try await browser.launcher(
            command: "/usr/bin/env", arguments: [], directory: directory)
        #expect(renamed.deletingLastPathComponent() == third.deletingLastPathComponent())
        try await storage.removeLauncher(third)
        let browserEnvironment = try await HerdrAccountFixture.run(renamed, home: root)
        #expect(browserEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(browserEnvironment["ANTHROPIC_API_KEY"] == nil)
        #expect(browserEnvironment["ANTHROPIC_PROFILE"] == nil)
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
    }
}
