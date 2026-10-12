import Darwin
import Foundation
import Testing
@testable import EdithExtensionAccounts

@Suite struct AccountSupportStorageTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func storageUsesPrivateFilesAndAtomicExpectedState() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        let state = ClaudeAccountsState(accounts: [account], defaultID: account.id)
        try await store.save(state, expected: .init())
        #expect(try await store.load() == state)
        #expect(try mode(directory) == 0o700)
        #expect(try mode(directory.appendingPathComponent("accounts.json")) == 0o600)
        await #expect(throws: ClaudeAccountError.self) {
            try await store.save(.init(), expected: .init())
        }
        await #expect(throws: ClaudeAccountError.self) { try await store.save(.init()) }
        #expect(try await store.load() == state)
    }

    @Test func launcherIsExclusivePrivateBoundedAndAccountScoped() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        try await store.save(.init(accounts: [account]))
        let first = try await store.writeLauncher(account: account) { _, _ in
            Data("synthetic-launcher".utf8)
        }
        let second = try await store.writeLauncher(account: account) { _, _ in
            Data("other-synthetic-launcher".utf8)
        }
        #expect(
            first != second
                && first.deletingLastPathComponent().lastPathComponent == account.id.uuidString)
        #expect(try mode(first) == 0o700)
        try await store.removeLauncher(first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        await #expect(throws: ClaudeAccountError.self) {
            try await store.writeLauncher(account: account) { _, _ in
                Data(repeating: 0, count: 65_537)
            }
        }
        await #expect(throws: ClaudeAccountError.self) {
            try await store.removeLauncher(root.appendingPathComponent("unowned.sh"))
        }
    }

    @Test func logoutAndForgetOnlyRemoveOwnedUUIDCopies() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original-cli-credentials")
        try Data("synthetic-original-login".utf8).write(to: original)
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        var account = ClaudeAccount(name: "Synthetic", authentication: .browserLogin)
        account.credential = "synthetic-token"
        account.loginData = "{\"claudeAiOauth\":{\"accessToken\":\"synthetic-token\"}}"
        let other = ClaudeAccount(name: "Other", credential: "synthetic-other")
        try await store.save(.init(accounts: [account, other], defaultID: account.id))
        try await store.seedLogin(account: account)
        let scope = directory.appendingPathComponent(account.id.uuidString, isDirectory: true)
        let link = scope.appendingPathComponent("original-login-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let erased = AccountSupportSecretRecorder()
        let state = try await store.logout(id: account.id, eraseScopedSecret: { erased.record($0) })
        #expect(
            state.accounts[0].isLoggedOut && state.accounts[0].credential.isEmpty
                && state.accounts[0].loginData == nil)
        #expect(!FileManager.default.fileExists(atPath: scope.path))
        #expect(try String(contentsOf: original, encoding: .utf8) == "synthetic-original-login")
        #expect(erased.values == [scope])
        let forgotten = try await store.forget(
            id: account.id, eraseScopedSecret: { erased.record($0) })
        #expect(forgotten.accounts == [other] && forgotten.defaultID == nil)
        #expect(try await store.load() == forgotten)
    }

    @Test func cleanupFailureStillInvalidatesImportedLogin() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        var account = ClaudeAccount(name: "Synthetic", authentication: .browserLogin)
        account.loginData = "synthetic-saved-login"
        try await store.save(.init(accounts: [account]))
        await #expect(throws: ClaudeAccountError.self) {
            try await store.logout(
                id: account.id, eraseScopedSecret: { _ in throw ClaudeAccountError.invalidRequest })
        }
        let state = try await store.load()
        #expect(state.accounts[0].isLoggedOut && state.accounts[0].loginData == nil)
        #expect(
            ClaudeSavedLogin.scopedToken(
                account: state.accounts[0], directory: directory,
                readScopedSecret: { _ in
                    Issue.record("Logged-out account must not read a residual secret"); return nil
                }) == nil)
    }

    @Test func cancelledSaveAndLauncherLeaveCommittedStateUnchanged() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        let state = ClaudeAccountsState(accounts: [account])
        try await store.save(state)
        let update = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.save(.init(accounts: [account, ClaudeAccount(name: "Other")]))
        }
        await #expect(throws: CancellationError.self) { try await update.value }
        let launch = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.writeLauncher(account: account) { _, _ in
                Issue.record("Cancelled launch must not generate a script")
                return Data()
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await launch.value }
        #expect(try await store.load() == state)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(account.id.uuidString).path))
    }

    @Test func symlinkPermissiveRootOversizedAndHardlinkedFilesReject() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        _ = try await store.load()
        let target = root.appendingPathComponent("synthetic-target")
        try Data("{}".utf8).write(to: target)
        let file = directory.appendingPathComponent("accounts.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        await #expect(throws: ClaudeAccountError.self) { _ = try await store.load() }
        await #expect(throws: ClaudeAccountError.self) { try await store.save(.init()) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: target, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        await #expect(throws: ClaudeAccountError.self) { _ = try await store.load() }
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0, count: 60_001).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        await #expect(throws: ClaudeAccountError.self) { _ = try await store.load() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        await #expect(throws: ClaudeAccountError.self) { _ = try await store.load() }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        await #expect(throws: ClaudeAccountError.self) {
            _ = try await ClaudeAccountStorage(directory: alias).load()
        }
    }

    @Test func resolverRequiresOnlyConfiguredHerdrOrUsageContext() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = [
            "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith.dev.synthetic",
            "EDITH_EXTENSION_ID": "herdr",
            "EDITH_EXTENSION_DATA_ROOT": root.appendingPathComponent("Data/herdr").path,
            "EDITH_EXTENSION_STATE_ROOT": root.appendingPathComponent("ExtensionState").path,
        ]
        #expect(
            try ClaudeAccountStorage.directory(environment: environment)
                == root.appendingPathComponent("Accounts", isDirectory: true))
        environment["EDITH_EXTENSION_ID"] = "clipboard"
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountStorage.directory(environment: environment)
        }
        environment["EDITH_EXTENSION_ID"] = "herdr"
        environment["EDITH_EXTENSION_STATE_ROOT"] =
            root.appendingPathComponent("unrelated-state").path
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountStorage.directory(environment: environment)
        }
    }

    @Test func refreshedLoginIsNeverOverwrittenAndProfileSymlinksReject() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        var account = ClaudeAccount(name: "Synthetic", authentication: .browserLogin)
        account.loginData = "synthetic-imported-login"
        try await store.save(.init(accounts: [account]))
        try await store.seedLogin(account: account)
        let profile = directory.appendingPathComponent(account.id.uuidString, isDirectory: true)
        let file = profile.appendingPathComponent(".credentials.json")
        try Data("synthetic-refreshed-login".utf8).write(to: file)
        try await store.seedLogin(account: account)
        #expect(try String(contentsOf: file, encoding: .utf8) == "synthetic-refreshed-login")
        try FileManager.default.removeItem(at: profile)
        let outside = root.appendingPathComponent("original-cli", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let original = outside.appendingPathComponent(".credentials.json")
        try Data("synthetic-original-login".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: outside)
        await #expect(throws: ClaudeAccountError.self) {
            try await store.seedLogin(account: account)
        }
        await #expect(throws: ClaudeAccountError.self) {
            try await store.writeLauncher(account: account) { _, _ in
                Data("synthetic-launcher".utf8)
            }
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "synthetic-original-login")
    }

    @Test func failedForgetRetainsAnInvalidatedIDForOwnedCleanupRetry() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original-cli-login")
        try Data("synthetic-original".utf8).write(to: original)
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        var account = ClaudeAccount(name: "Synthetic", authentication: .browserLogin)
        account.credential = "synthetic-access"
        account.loginData = "synthetic-refresh"
        try await store.save(.init(accounts: [account], defaultID: account.id))
        try await store.seedLogin(account: account)
        await #expect(throws: ClaudeAccountError.self) {
            try await store.forget(
                id: account.id, eraseScopedSecret: { _ in throw ClaudeAccountError.invalidRequest })
        }
        let retained = try await store.load()
        #expect(retained.accounts.count == 1 && retained.defaultID == account.id)
        #expect(
            retained.accounts[0].isLoggedOut && retained.accounts[0].credential.isEmpty
                && retained.accounts[0].loginData == nil)
        let scope = directory.appendingPathComponent(account.id.uuidString, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: scope.path))
        let erased = AccountSupportSecretRecorder()
        let forgotten = try await store.forget(
            id: account.id, eraseScopedSecret: { erased.record($0) })
        #expect(forgotten.accounts.isEmpty && forgotten.defaultID == nil)
        #expect(erased.values == [scope] && !FileManager.default.fileExists(atPath: scope.path))
        #expect(try String(contentsOf: original, encoding: .utf8) == "synthetic-original")
    }

    @Test func deepProfileCleanupRejectsWithoutLosingItsRetryRecord() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic", authentication: .browserLogin)
        try await store.save(.init(accounts: [account]))
        var child = try await store.profileDirectory(for: account.id)
        for _ in 0..<33 {
            child.appendPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(
                at: child, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let leaf = child.appendingPathComponent("synthetic-leaf")
        try Data("synthetic-deep-data".utf8).write(to: leaf)
        await #expect(throws: ClaudeAccountError.self) {
            try await store.forget(id: account.id, eraseScopedSecret: { _ in })
        }
        #expect(try await store.load().accounts.first?.isLoggedOut == true)
        #expect(try String(contentsOf: leaf, encoding: .utf8) == "synthetic-deep-data")
    }

    @Test func cancelledTaskStillRemovesItsOwnedUnusedLauncher() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        let state = ClaudeAccountsState(accounts: [account])
        try await store.save(state)
        let launcher = try await store.writeLauncher(account: account) { _, _ in
            Data("synthetic-unused-launcher".utf8)
        }
        let cleanup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.removeLauncher(launcher)
        }
        try await cleanup.value
        #expect(!FileManager.default.fileExists(atPath: launcher.path))
        #expect(try await store.load() == state)
    }
}

private final class AccountSupportSecretRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var values: [URL] { lock.withLock { stored } }
    func record(_ url: URL) { lock.withLock { stored.append(url) } }
}
