import Darwin
import Foundation
import Testing

@testable import EdithKit

@Suite struct ClaudeAccountLaunchCredentialTests {
    private let identifier = "com.pulkit.edith.tests.launch-credential"

    private func runShell(_ script: String, home: URL, stdin: Data) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    @Test func localStagingWritesPrivateOneShotFileAndPrunesStaleOnes() async throws {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("accounts")
        let storage = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(
            name: "Local", credential: "synthetic-'local;$(touch forbidden)")
        let old = try await HerdrAccountFixture.stage(account, directory: directory)
        let fresh = try await HerdrAccountFixture.stage(account, directory: directory)
        let unrelated = directory.appendingPathComponent("accounts.backup")
        try Data("synthetic".utf8).write(to: unrelated)
        let past = Date().addingTimeInterval(-11 * 60)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: unrelated.path)
        let staged = try await HerdrAccountFixture.stage(account, directory: directory)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try String(contentsOf: staged, encoding: .utf8) == account.credential)
        #expect(try mode(staged.path) == 0o600)
        await storage.discardLaunchCredential(name: fresh.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        await storage.discardLaunchCredential(name: "accounts.backup")
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        let browser = ClaudeAccount(name: "Browser", authentication: .browserLogin)
        await #expect(throws: ClaudeAccountError.self) {
            try await storage.stageLaunchCredential(
                account: browser, name: ClaudeAccountLaunchCredential.fileName())
        }
        for name in ["accounts.json", "launch-", "launch-../x", "../launch-" + UUID().uuidString] {
            await #expect(throws: ClaudeAccountError.self) {
                try await storage.stageLaunchCredential(account: account, name: name)
            }
        }
        await #expect(throws: ClaudeAccountError.self) {
            try await storage.stageLaunchCredential(
                account: account, name: staged.lastPathComponent)
        }
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
    }

    @Test(arguments: ["/bin/bash", "/bin/zsh"])
    func launchReadsAndDeletesCredentialWithoutPrintingIt(shell: String) async throws {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = ClaudeAccount(
            name: "Shell", authentication: .apiKey, credential: "synthetic-\"key\" $(id)`x`")
        let staged = try await HerdrAccountFixture.stage(
            account, directory: root.appendingPathComponent("accounts"))
        let command = try account.launchCommand(
            command: "/usr/bin/env", arguments: [], credentialPath: staged.path)
        #expect(!command.contains("synthetic-"))
        let environment = try await HerdrAccountFixture.run(command, home: root, shell: shell)
        #expect(environment["ANTHROPIC_API_KEY"] == account.credential)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func posixRemoteStagingCreatesPrivateFileOnFreshHome() throws {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = ClaudeAccount(
            name: "Remote", credential: "synthetic-'remote;$(touch forbidden)")
        let name = ClaudeAccountLaunchCredential.fileName()
        let command = try ClaudeAccountLaunchCredential.posixStageCommand(
            accountID: account.id, name: name, identifier: identifier)
        #expect(!command.contains("synthetic-"))
        let (status, output) = try runShell(
            command, home: root, stdin: Data(account.credential.utf8))
        #expect(status == 0)
        let path = try ClaudeAccountLaunchCredential.stagedPath(
            output, accountID: account.id, name: name, platform: .linux, identifier: identifier)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == account.credential)
        #expect(try mode(path) == 0o600)
        #expect(try mode((path as NSString).deletingLastPathComponent) == 0o700)
        let (again, _) = try runShell(command, home: root, stdin: Data("synthetic-other".utf8))
        #expect(again != 0)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == account.credential)
        let (discarded, _) = try runShell(
            ClaudeAccountLaunchCredential.discardCommand(path: path, platform: .linux), home: root,
            stdin: Data())
        #expect(discarded == 0)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountLaunchCredential.posixStageCommand(
                accountID: account.id, name: "accounts.json", identifier: identifier)
        }
    }

    @Test func posixRemoteStagingRefusesSymlinkedAccountFolder() throws {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let share = root.appendingPathComponent(".local/share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: share.appendingPathComponent("edith"), withDestinationURL: elsewhere)
        let account = ClaudeAccount(name: "Remote", credential: "synthetic-token")
        let (status, output) = try runShell(
            try ClaudeAccountLaunchCredential.posixStageCommand(
                accountID: account.id, name: ClaudeAccountLaunchCredential.fileName(),
                identifier: identifier),
            home: root, stdin: Data(account.credential.utf8))
        #expect(status != 0)
        #expect(output.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func stagedPathAcceptsOnlyTheExpectedLocation() throws {
        let id = UUID()
        let name = ClaudeAccountLaunchCredential.fileName()
        let posix =
            "/home/synthetic/.local/share/edith/" + identifier + "/accounts/"
            + id.uuidString + "/" + name
        #expect(
            try ClaudeAccountLaunchCredential.stagedPath(
                posix, accountID: id, name: name, platform: .linux, identifier: identifier)
                == posix)
        let windows =
            "C:\\Users\\synthetic\\AppData\\Local\\edith\\" + identifier
            + "\\accounts\\" + id.uuidString + "\\" + name
        #expect(
            try ClaudeAccountLaunchCredential.stagedPath(
                windows, accountID: id, name: name, platform: .windows, identifier: identifier)
                == windows)
        for (output, platform) in [
            ("", RemoteMachinePlatform.linux), ("relative/" + name, .linux),
            (posix + "\n", .linux), (posix.replacingOccurrences(of: name, with: "other"), .linux),
            ("/x/../" + posix, .linux), (posix, .windows), (windows, .linux),
            ("\\\\server\\share\\" + windows.dropFirst(3), .windows),
        ] {
            #expect(throws: ClaudeAccountError.self) {
                try ClaudeAccountLaunchCredential.stagedPath(
                    output, accountID: id, name: name, platform: platform, identifier: identifier)
            }
        }
    }

    @Test func windowsStagingReadsSecretFromStandardInputOnly() throws {
        let id = UUID()
        let name = ClaudeAccountLaunchCredential.fileName()
        let command = try ClaudeAccountLaunchCredential.windowsStageCommand(
            accountID: id, name: name, byteCount: 42, identifier: identifier)
        let encoded = try #require(command.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(script.contains("New-Object byte[] 42"))
        #expect(script.contains("[Console]::OpenStandardInput()"))
        #expect(script.contains("$env:LOCALAPPDATA"))
        #expect(script.contains("[IO.FileMode]::CreateNew"))
        #expect(script.contains(PowerShell.literal(name)))
        #expect(script.contains(id.uuidString))
        for count in [0, OwnedAccountFiles.maximumBytes + 1] {
            #expect(throws: ClaudeAccountError.self) {
                try ClaudeAccountLaunchCredential.windowsStageCommand(
                    accountID: id, name: name, byteCount: count, identifier: identifier)
            }
        }
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountLaunchCredential.windowsStageCommand(
                accountID: id, name: "launch-x", byteCount: 1, identifier: identifier)
        }
    }
}
