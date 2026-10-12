import AppKit
import EdithKit
import SwiftUI
import Foundation
import Testing
@testable import Edith

@Suite struct ClaudeAccountTests {
    @Test func CLIImportReloadsShellCredentialsWithoutInheritingOldAuthentication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let startup = root.appendingPathComponent(".zshrc")
        let base = [
            "PATH": "/usr/bin:/bin", "ZDOTDIR": root.path,
            "ANTHROPIC_API_KEY": "synthetic-old-api-key",
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
        try Data("export ANTHROPIC_API_KEY=synthetic-new-api-key\n".utf8).write(to: startup)
        let second = try await ClaudeAccount.currentCLIEnvironment(
            shell: URL(fileURLWithPath: "/bin/zsh"), home: root, base: base)
        #expect(second["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(
            try ClaudeAccount.currentCLIAccount(environment: second).credential
                == "synthetic-new-api-key")
        try Data().write(to: startup)
        let third = try await ClaudeAccount.currentCLIEnvironment(
            shell: URL(fileURLWithPath: "/bin/zsh"), home: root, base: base)
        let saved = Data(
            "{\"claudeAiOauth\":{\"accessToken\":\"synthetic-login-token\",\"subscriptionType\":\"max\"}}"
                .utf8)
        let account = try ClaudeAccount.currentCLIAccount(environment: third, savedLoginData: saved)
        #expect(account.authentication == .browserLogin)
        #expect(account.loginData == String(data: saved, encoding: .utf8))
    }

    @Test @MainActor func shellEditorPreservesTypedHyphensAndQuotes() throws {
        var value = ""
        let host = NSHostingView(
            rootView: ShellInputEditor(
                text: Binding(get: { value }, set: { value = $0 }), label: "Launch settings"
            )
            .disabled(false).frame(width: 440, height: 48))
        host.layoutSubtreeIfNeeded()
        func findEditor(_ view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView { return editor }
            return view.subviews.compactMap(findEditor).first
        }
        let editor = try #require(findEditor(host))
        #expect(!editor.isAutomaticDashSubstitutionEnabled)
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isAutomaticTextReplacementEnabled)
        let input = "--dangerously-skip-permissions\nIS_DEMO='1'"
        for character in input {
            editor.insertText(
                String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(editor.string == input)
        #expect(value == input)
        host.rootView = ShellInputEditor(
            text: Binding(get: { value }, set: { value = $0 }), label: "Launch settings"
        )
        .disabled(true).frame(width: 440, height: 48)
        host.layoutSubtreeIfNeeded()
        #expect(!editor.isEditable)
    }

    @Test func sharedLaunchOptionsApplyToEveryAccountAndPreserveLiteralValues() throws {
        let defaults = UserDefaults(suiteName: "test.shared-launch." + UUID().uuidString)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try HerdrLaunchSettings.setSharedClaudeLaunch(
            arguments: "FLAG_VALUE=two words",
            environment: "IS_DEMO=1\nLITERAL=$(touch forbidden); 'quoted'", in: defaults)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("alias cc='/usr/bin/env'\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        HerdrLaunchSettings.setCommand("cc", for: "Claude Code", in: defaults)
        let command = HerdrLaunchSettings.launchCommand(for: "Claude Code", in: defaults)
        let arguments = HerdrLaunchSettings.launchArguments(
            kind: "Claude Code", options: .none, in: defaults)
        for credential in ["synthetic-work", "synthetic-personal"] {
            let account = ClaudeAccount(name: credential, credential: credential)
            let file = try account.launcher(command: command, arguments: arguments, directory: root)
            let environment = try run(file, shell: "/bin/zsh", startupDirectory: root)
            #expect(environment["FLAG_VALUE"] == "two words")
            #expect(environment["IS_DEMO"] == "1")
            #expect(environment["LITERAL"] == "$(touch forbidden); 'quoted'")
            #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == credential)
        }
        #expect(HerdrLaunchSettings.launchCommand(for: "Gemini", in: defaults) == "gemini")
        #expect(
            HerdrLaunchSettings.launchArguments(kind: "Gemini", options: .none, in: defaults)
                .isEmpty)
        for value in [
            "BAD-NAME=value", "MISSING_VALUE", "CLAUDE_CODE_OAUTH_TOKEN=wrong",
            "CLAUDE_CONFIG_DIR=/tmp",
        ] {
            #expect(throws: ClaudeAccountError.self) {
                try HerdrLaunchSettings.setSharedClaudeLaunch(
                    arguments: "", environment: value, in: defaults)
            }
        }
        #expect(HerdrLaunchSettings.sharedArguments(in: defaults) == "FLAG_VALUE=two words")
    }

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

    @Test func shellAliasesRunAfterStartupWithoutUsingTheShellsCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(
            "export CLAUDE_CODE_OAUTH_TOKEN=wrong-startup-token\nalias cc='IS_DEMO=1 /usr/bin/env'\n"
                .utf8
        ).write(to: root.appendingPathComponent(".zshrc"))
        let account = ClaudeAccount(name: "Work", credential: "synthetic-selected-token")
        let file = try account.launcher(command: "cc", arguments: [], directory: root)
        let environment = try run(file, shell: "/bin/zsh", startupDirectory: root)
        #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == account.credential)
        #expect(environment["IS_DEMO"] == "1")
        #expect(environment["CLAUDE_CONFIG_DIR"] == file.deletingLastPathComponent().path)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let login = ClaudeAccount(name: "Other", authentication: .browserLogin)
        let second = try login.launcher(command: "cc", arguments: [], directory: root)
        #expect(
            try run(second, shell: "/bin/zsh", startupDirectory: root)["CLAUDE_CODE_OAUTH_TOKEN"]
                == nil)
    }

    @Test func currentCLIImportChoosesOAuthThenAPIKeyThenSavedLogin() throws {
        let token = try ClaudeAccount.currentCLIAccount(environment: [
            "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-token", "ANTHROPIC_API_KEY": "synthetic-key",
        ])
        #expect(token.authentication == .oauthToken)
        #expect(token.credential == "synthetic-token")
        let key = try ClaudeAccount.currentCLIAccount(environment: [
            "ANTHROPIC_API_KEY": "synthetic-key"
        ])
        #expect(key.authentication == .apiKey)
        #expect(key.credential == "synthetic-key")
        #expect(
            try ClaudeAccount.currentCLIAccount(
                environment: [:],
                savedLoginData: Data(
                    #"{"claudeAiOauth":{"accessToken":"synthetic-login","refreshToken":"synthetic-refresh"}}"#
                        .utf8)
            )
            .credential == "synthetic-login")
        #expect(throws: (any Error).self) { try ClaudeAccount.currentCLIAccount(environment: [:]) }
    }

    @Test func importedLoginKeepsRefreshCredentialsAndNeverOverwritesAnUpdatedLogin() throws {
        let data = Data(
            #"{"claudeAiOauth":{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh"}}"#
                .utf8)
        let account = try ClaudeAccount.currentCLIAccount(environment: [:], savedLoginData: data)
        #expect(account.authentication == .browserLogin)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try account.launcher(command: "/usr/bin/env", arguments: [], directory: root)
        let credentials = file.deletingLastPathComponent().appendingPathComponent(
            ".credentials.json")
        #expect(try Data(contentsOf: credentials) == data)
        #expect(
            (try FileManager.default.attributesOfItem(atPath: credentials.path)[.posixPermissions]
                as? NSNumber)?.intValue == 0o600)
        #expect(try run(file)["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        let updated = Data(
            #"{"claudeAiOauth":{"accessToken":"synthetic-updated","refreshToken":"synthetic-refreshed"}}"#
                .utf8)
        try updated.write(to: credentials)
        _ = try account.launcher(command: "/usr/bin/env", arguments: [], directory: root)
        #expect(try Data(contentsOf: credentials) == updated)
        #expect(
            try JSONDecoder().decode(ClaudeAccount.self, from: JSONEncoder().encode(account))
                == account)
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

    private func run(
        _ launcher: URL, shell: String = "/bin/sh", startupDirectory: URL? = nil
    ) throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [launcher.path]
        process.currentDirectoryURL = launcher.deletingLastPathComponent()
        process.environment = [
            "PATH": "/usr/bin:/bin", "SHELL": shell,
            "HOME": launcher.deletingLastPathComponent().path,
            "ZDOTDIR": (startupDirectory ?? launcher.deletingLastPathComponent()).path,
            "ANTHROPIC_API_KEY": "wrong-api-key",
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
