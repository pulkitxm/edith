import Darwin
import Foundation
import Testing

@testable import EdithKit

enum HerdrAccountFixture {
    static func root() throws -> URL {
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        var attributes = stat()
        try #require(
            lstat(physical, &attributes) == 0 && attributes.st_uid == getuid()
                && attributes.st_mode & S_IFMT == S_IFDIR && attributes.st_mode & 0o777 == 0o700)
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("herdr-account-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    static func stage(_ account: ClaudeAccount, directory: URL) async throws -> URL {
        try await ClaudeAccountStorage(directory: directory).stageLaunchCredential(
            account: account, name: ClaudeAccountLaunchCredential.fileName())
    }

    static func run(
        _ command: String, home: URL, shell: String = "/bin/sh"
    ) async throws -> [String: String] {
        let result = try await CLICommandRunner.runLocal(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: shell), arguments: ["-lic", command],
                environment: [
                    "PATH": "/usr/bin:/bin", "SHELL": shell, "HOME": home.path,
                    "ZDOTDIR": home.path, "TMPDIR": home.path,
                    "ANTHROPIC_API_KEY": "synthetic-inherited-key",
                    "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-inherited-token",
                    "ANTHROPIC_AUTH_TOKEN": "synthetic-inherited-auth",
                    "ANTHROPIC_PROFILE": "synthetic-inherited-profile",
                    "CLAUDE_CODE_USE_BEDROCK": "1",
                    "CLAUDE_CONFIG_DIR": home.appendingPathComponent("native-config").path,
                    "CLAUDE_SECURESTORAGE_CONFIG_DIR": home.appendingPathComponent("native-secure")
                        .path,
                    "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST": "synthetic-inherited-provider",
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
        let suite = "herdr-account-shell." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
        let command = HerdrLaunchSettings.command(for: "Claude Code", in: defaults)
        let arguments = HerdrLaunchSettings.launchArguments(
            kind: "Claude Code", options: .none, in: defaults)
        var profiles = Set<String>()
        for account in accounts {
            let staged = try await HerdrAccountFixture.stage(account, directory: directory)
            let launch = try account.launchCommand(
                command: command, arguments: arguments,
                environment: HerdrLaunchSettings.sharedEnvironment(in: defaults),
                credentialPath: staged.path)
            #expect(!launch.contains(account.credential))
            let environment = try await HerdrAccountFixture.run(
                launch, home: root, shell: "/bin/zsh")
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            #expect(environment["FLAG_VALUE"] == "two words")
            #expect(environment["IS_DEMO"] == "1")
            #expect(environment["LITERAL"] == "$(touch forbidden); 'quoted'")
            #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == account.credential)
            #expect(environment["ANTHROPIC_API_KEY"] == nil)
            #expect(
                environment["CLAUDE_CONFIG_DIR"]
                    == root.appendingPathComponent("native-config").path)
            profiles.insert(try #require(environment["CLAUDE_CONFIG_DIR"]))
            #expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(account.id.uuidString).path))
        }
        #expect(profiles.count == 1)
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
        let first = try personal.launchCommand(
            command: "/usr/bin/env", arguments: [],
            credentialPath: try await HerdrAccountFixture.stage(personal, directory: directory).path)
        let second = try company.launchCommand(
            command: "/usr/bin/env", arguments: [],
            credentialPath: try await HerdrAccountFixture.stage(company, directory: directory).path)
        #expect(!first.contains("synthetic-'token") && !second.contains(company.credential))
        try await storage.seedLogin(account: browser)
        let third = directory.appendingPathComponent(browser.id.uuidString, isDirectory: true)
        let personalEnvironment = try await HerdrAccountFixture.run(first, home: root)
        let companyEnvironment = try await HerdrAccountFixture.run(second, home: root)
        #expect(personalEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] == token)
        #expect(personalEnvironment["ANTHROPIC_API_KEY"] == nil)
        #expect(companyEnvironment["ANTHROPIC_API_KEY"] == company.credential)
        #expect(companyEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(personalEnvironment["CLAUDE_CONFIG_DIR"] == companyEnvironment["CLAUDE_CONFIG_DIR"])
        #expect(personalEnvironment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(personalEnvironment["CLAUDE_CODE_USE_BEDROCK"] == nil)
        browser.name = "Renamed browser"
        try await storage.save(.init(accounts: [personal, company, browser]))
        try await storage.seedLogin(account: browser)
        let renamed = directory.appendingPathComponent(browser.id.uuidString, isDirectory: true)
        #expect(renamed == third)
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        let launch = try browser.launchCommand(
            command: "/usr/bin/env", arguments: [], configurationPath: renamed.path)
        let browserEnvironment = try await HerdrAccountFixture.run(launch, home: root)
        #expect(browserEnvironment["CLAUDE_CONFIG_DIR"] == renamed.path)
        #expect(browserEnvironment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == renamed.path)
        #expect(browserEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(browserEnvironment["ANTHROPIC_API_KEY"] == nil)
        #expect(browserEnvironment["ANTHROPIC_PROFILE"] == nil)
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
    }
    @Test(arguments: ["/bin/bash", "/bin/zsh"])
    func directStartupKeepsNativeConfigurationAliasesAndLiteralArguments(shell: String) async throws
    {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let startup = shell == "/bin/zsh" ? ".zshrc" : ".bash_profile"
        try Data(
            "export ANTHROPIC_AUTH_TOKEN=synthetic-startup-auth\nalias cc='/usr/bin/env'\n".utf8
        ).write(to: root.appendingPathComponent(startup))
        let accounts = [
            ClaudeAccount(name: "Token", credential: "synthetic-'token;$(touch forbidden)"),
            ClaudeAccount(name: "Key", authentication: .apiKey, credential: "synthetic-'key"),
        ]
        for account in accounts {
            let staged = try await HerdrAccountFixture.stage(
                account, directory: root.appendingPathComponent("accounts"))
            let command = try account.launchCommand(
                command: "cc",
                arguments: ["MODEL=synthetic model", "LITERAL_ARG=$(touch forbidden)"],
                environment: "IS_DEMO=1\nLITERAL_ENV=$(touch forbidden); 'quoted'",
                credentialPath: staged.path)
            let result = try await HerdrAccountFixture.run(command, home: root, shell: shell)
            let selected =
                account.authentication == .apiKey ? "ANTHROPIC_API_KEY" : "CLAUDE_CODE_OAUTH_TOKEN"
            let competing =
                account.authentication == .apiKey ? "CLAUDE_CODE_OAUTH_TOKEN" : "ANTHROPIC_API_KEY"
            #expect(result[selected] == account.credential)
            #expect(result[competing] == nil)
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            #expect(result["ANTHROPIC_AUTH_TOKEN"] == nil)
            #expect(result["CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST"] == nil)
            #expect(result["MODEL"] == "synthetic model")
            #expect(result["LITERAL_ARG"] == "$(touch forbidden)")
            #expect(result["LITERAL_ENV"] == "$(touch forbidden); 'quoted'")
            #expect(result["IS_DEMO"] == "1")
            #expect(
                result["CLAUDE_CONFIG_DIR"] == root.appendingPathComponent("native-config").path)
            #expect(
                result["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
                    == root.appendingPathComponent("native-secure").path)
        }
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
    }

    @Test func directWindowsBuilderQuotesSecretsAndUsesSelectedTerminal() throws {
        let account = ClaudeAccount(
            name: "Windows", authentication: .apiKey, credential: "synthetic'key;$env:HOME")
        let arguments = ["--model", "synthetic model", "literal'argument;$(Get-Item secret)"]
        let credentialPath = "C:\\Users\\synthetic o'user\\launch-staged"
        let command = try account.launchCommand(
            command: "cc", arguments: arguments,
            environment: "IS_DEMO=1\nLITERAL=synthetic'value;$env:HOME",
            platform: .windows, credentialPath: credentialPath)
        #expect(
            command.contains(
                "Remove-Item Env:CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue"))
        #expect(!command.contains("synthetic'key") && !command.contains("synthetic''key"))
        #expect(
            command.contains(
                "$env:ANTHROPIC_API_KEY=[IO.File]::ReadAllText("
                    + PowerShell.literal(credentialPath) + ")"))
        #expect(
            command.contains(
                "Remove-Item -LiteralPath " + PowerShell.literal(credentialPath)
                    + " -Force -ErrorAction SilentlyContinue"))
        #expect(command.contains("$env:LITERAL='synthetic''value;$env:HOME'"))
        #expect(!command.contains("CLAUDE_CONFIG_DIR"))
        #expect(
            command.hasSuffix(
                HerdrPaneRunCommand.commandText("cc", appending: arguments, platform: .windows)))
        let launch = try HerdrLaunchOperations.accountLaunch(
            account: account, command: "cc", arguments: arguments,
            environment: "IS_DEMO=1\nLITERAL=synthetic'value;$env:HOME",
            credentialPath: credentialPath, pane: "synthetic-selected-pane")
        #expect(
            launch.local.prefix(5) == [
                "--session", "default", "pane", "run", "synthetic-selected-pane",
            ])
        #expect(launch.timeout == 15)
        let encoded = try #require(launch.remote(.windows).split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        let decoded = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(decoded.contains(PowerShell.literal(PowerShell.nativeArgument(command))))
        #expect(decoded.contains("synthetic-selected-pane"))
        #expect(launch.remote(.linux).contains("synthetic-selected-pane"))
    }

    @Test func directLaunchRejectsUnboundedOrCompetingInputs() throws {
        let account = ClaudeAccount(name: "Validation", credential: "synthetic-token")
        let staged = "/synthetic/launch-staged"
        _ = try account.launchCommand(command: "cc", arguments: [], credentialPath: staged)
        for path in [nil, "", "bad\0", "/synthetic/\nlaunch", String(repeating: "p", count: 8193)] {
            #expect(throws: ClaudeAccountError.self) {
                try account.launchCommand(command: "cc", arguments: [], credentialPath: path)
            }
        }
        for command in ["", " \n", "cc\0", String(repeating: "c", count: 16_385)] {
            #expect(throws: ClaudeAccountError.self) {
                try account.launchCommand(command: command, arguments: [], credentialPath: staged)
            }
        }
        for arguments in [
            ["bad\0"], [String(repeating: "x", count: 8193)], Array(repeating: "x", count: 257),
        ] {
            #expect(throws: ClaudeAccountError.self) {
                try account.launchCommand(command: "cc", arguments: arguments, credentialPath: staged)
            }
        }
        for environment in [
            "BAD-NAME=value", "MISSING_VALUE", "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1",
            "ANTHROPIC_API_KEY=wrong", "anthropic_api_key=wrong", "Claude_Config_Dir=/wrong",
            "X=bad\0", "X=" + String(repeating: "x", count: 8191),
        ] {
            #expect(throws: ClaudeAccountError.self) {
                try account.launchCommand(
                    command: "cc", arguments: [], environment: environment, credentialPath: staged)
            }
        }
        #expect(throws: ClaudeAccountError.self) {
            try account.launchCommand(
                command: "cc",
                arguments: Array(repeating: String(repeating: "x", count: 8192), count: 9),
                credentialPath: staged)
        }
        #expect(throws: ClaudeAccountError.self) {
            try HerdrLaunchOperations.accountLaunch(
                account: account, command: "cc",
                arguments: Array(repeating: String(repeating: "x", count: 8192), count: 3),
                environment: "", credentialPath: staged, pane: "synthetic")
        }
        let browser = ClaudeAccount(name: "Browser", authentication: .browserLogin)
        #expect(throws: ClaudeAccountError.self) {
            try browser.launchCommand(command: "cc", arguments: [])
        }
        #expect(throws: ClaudeAccountError.self) {
            try browser.launchCommand(
                command: "cc", arguments: [], configurationPath: "/synthetic/profile",
                credentialPath: staged)
        }
        for profile in ["", "bad\0", "/synthetic/\nprofile", String(repeating: "p", count: 8193)] {
            #expect(throws: ClaudeAccountError.self) {
                try browser.launchCommand(command: "cc", arguments: [], configurationPath: profile)
            }
        }
        let command = try browser.launchCommand(
            command: "cc", arguments: [], configurationPath: "/synthetic/private'profile")
        #expect(
            command.contains(
                "export CLAUDE_CONFIG_DIR=" + ShellQuote.quote("/synthetic/private'profile")))
        #expect(!command.contains("export ANTHROPIC_API_KEY="))
        #expect(!command.contains("export CLAUDE_CODE_OAUTH_TOKEN="))
    }

}
