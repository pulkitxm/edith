import Darwin
import EdithCore
import Foundation
import Testing
@testable import EdithKit

@Suite struct ClaudeAccountStorageTests {
    private func fixture() throws -> URL {
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func physicalRootRemainsUsableBeforeAndAfterCreation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try await store.load() == .init())
        #expect(FileManager.default.fileExists(atPath: directory.path))
        let account = ClaudeAccount(name: "Synthetic physical", credential: "synthetic-token")
        let state = ClaudeAccountsState(accounts: [account], defaultID: account.id)
        try await store.save(state, expected: .init())
        #expect(try await store.load() == state)
    }

    @Test func symlinkAncestorIsRejectedBeforeRootCreation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let directory = alias.appendingPathComponent("Accounts", isDirectory: true)
        await #expect(throws: ClaudeAccountError.self) {
            _ = try await ClaudeAccountStorage(directory: directory).load()
        }
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("Accounts").path))
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

    @Test func rememberedSelectionUsesLatestFieldsAndRejectsStaleWholeState() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let editor = ClaudeAccountStorage(directory: directory)
        let first = ClaudeAccount(name: "Synthetic first", credential: "synthetic-first")
        let second = ClaudeAccount(name: "Synthetic second", credential: "synthetic-second")
        let initial = ClaudeAccountsState(accounts: [first, second], defaultID: first.id)
        try await store.save(initial, expected: .init())
        var renamed = first
        renamed.name = "Synthetic renamed"
        let edited = ClaudeAccountsState(accounts: [renamed, second], defaultID: first.id)
        try await editor.save(edited, expected: initial)
        let selected = try await store.rememberLaunchAccount(second.id)
        #expect(selected.accounts == edited.accounts)
        #expect(selected.defaultID == second.id)
        #expect(try await editor.load() == selected)
        #expect(try mode(directory) == 0o700)
        #expect(try mode(directory.appendingPathComponent("accounts.json")) == 0o600)
        await #expect(throws: ClaudeAccountError.self) {
            try await editor.save(edited, expected: edited)
        }
        #expect(try await store.load() == selected)
    }

    @Test func removedSelectionCannotRewriteAccountsOrChooseAnotherAccount() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic retained", credential: "synthetic-token")
        let state = ClaudeAccountsState(accounts: [account], defaultID: account.id)
        try await store.save(state, expected: .init())
        let file = directory.appendingPathComponent("accounts.json")
        let before = try Data(contentsOf: file)
        await #expect(throws: ClaudeAccountError.self) {
            try await store.rememberLaunchAccount(UUID())
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try await store.load() == state)
    }

    @Test(arguments: ["symlink", "hardlink", "public", "oversized"])
    func rememberedSelectionRetainsOwnedStateFileAdmission(kind: String) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let first = ClaudeAccount(name: "Synthetic first", credential: "synthetic-first")
        let second = ClaudeAccount(name: "Synthetic second", credential: "synthetic-second")
        try await store.save(.init(accounts: [first, second], defaultID: first.id))
        let file = directory.appendingPathComponent("accounts.json")
        let outside = root.appendingPathComponent("synthetic-original-state")
        let original = try Data(contentsOf: file)
        if kind == "symlink" {
            try FileManager.default.moveItem(at: file, to: outside)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        } else if kind == "hardlink" {
            try FileManager.default.linkItem(at: file, to: outside)
        } else if kind == "public" {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: file.path)
        } else {
            try Data(repeating: 0x78, count: 60_001).write(to: file)
        }
        let before = try Data(contentsOf: file)
        await #expect(throws: ClaudeAccountError.self) {
            try await store.rememberLaunchAccount(second.id)
        }
        #expect(try Data(contentsOf: file) == before)
        if kind == "symlink" || kind == "hardlink" {
            #expect(try Data(contentsOf: outside) == original)
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
        let erased = ClaudeAccountSecretRecorder()
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

    @Test func cancelledSaveAndSeedLeaveCommittedStateUnchanged() async throws {
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
            try await store.seedLogin(account: account)
        }
        await #expect(throws: CancellationError.self) { try await launch.value }
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

    @Test func accountsFolderKeepsTheProductionAndDevelopmentPaths() {
        let home = URL(fileURLWithPath: "/Users/synthetic", isDirectory: true)
        func accounts(_ identifier: String) -> String {
            let directories = AppDirectories(
                homeDirectory: home,
                directoryName: AppBuildIdentity.directoryName(for: identifier))
            return ClaudeAccountStorage.directory(support: directories.data).path
        }
        #expect(
            accounts(AppBuildIdentity.production)
                == "/Users/synthetic/Library/Application Support/Edith/Accounts")
        #expect(
            accounts(AppBuildIdentity.developmentPrefix + "alpha")
                == "/Users/synthetic/Library/Application Support/Edith Dev/alpha/Accounts")
        #expect(
            ClaudeAccountStorage.defaultDirectory.path
                == ClaudeAccountStorage.directory(support: DataRoot.support).path)
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
        let erased = ClaudeAccountSecretRecorder()
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
        try await store.seedLogin(account: account)
        var child = directory.appendingPathComponent(account.id.uuidString, isDirectory: true)
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

    private func limitsFixture() throws -> URL {
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func linkedLoginPreservesLaunchCredentialsForeignEditsAndSelectedDefault() async throws {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let first = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-exact-launch")
        let second = ClaudeAccount(name: "Synthetic other", credential: "synthetic-other")
        let original = ClaudeAccountsState(accounts: [first, second], defaultID: first.id)
        try await store.save(original)
        let native = ClaudeAccountSecretRecorder()
        let linked = try await store.connectLimitsLogin(
            account: first,
            startLogin: { id, folder in
                #expect(id != first.id && folder.lastPathComponent == id.uuidString)
                await #expect(throws: ClaudeAccountError.self) {
                    _ = try await store.limitsLoginCredentials(account: first)
                }
                var changed = original
                changed.accounts[1].name = "Synthetic foreign edit"
                changed.defaultID = second.id
                try await ClaudeAccountStorage(directory: directory).save(
                    changed, expected: original)
            }, eraseScopedSecret: { native.record($0) })
        let account = try #require(linked.accounts.first)
        var expected = first
        expected.limitsProfileID = account.limitsProfileID
        #expect(account == expected)
        #expect(linked.defaultID == second.id)
        #expect(linked.accounts[1].name == "Synthetic foreign edit")
        let (folder, credentials) = try await store.limitsLoginCredentials(account: account)
        #expect(credentials == nil)
        #expect(try mode(folder) == 0o700)
        #expect(native.values.isEmpty)
        let data = Data("synthetic-private-login".utf8)
        try await store.saveLimitsLoginCredentials(account: account, expected: nil, data: data)
        #expect(try await store.limitsLoginCredentials(account: account).1 == data)
        #expect(try mode(folder.appendingPathComponent(".credentials.json")) == 0o600)
        await #expect(throws: ClaudeAccountError.self) {
            try await store.saveLimitsLoginCredentials(
                account: account, expected: nil, data: Data())
        }
        #expect(try await store.load() == linked)
        let reconnected = try await store.connectLimitsLogin(
            account: account,
            startLogin: { id, replacement in
                #expect(id != account.limitsProfileID && replacement != folder)
                let loaded = try await store.load()
                let credentials = try await store.limitsLoginCredentials(account: account)
                #expect(loaded == linked)
                #expect(credentials.1 == data)
            }, eraseScopedSecret: { native.record($0) })
        var reconnectedExpected = linked
        reconnectedExpected.accounts[0].limitsProfileID = reconnected.accounts[0].limitsProfileID
        #expect(reconnected == reconnectedExpected)
        #expect(native.values == [folder])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try await store.limitsLoginCredentials(account: reconnected.accounts[0]).1 == nil)
    }

    @Test(arguments: [false, true])
    func failedReconnectPreservesPreviousScopeUntilItsHeldWriterJoins(cancelled: Bool) async throws
    {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let first = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-exact-launch")
        try await store.save(.init(accounts: [first], defaultID: first.id))
        let linked = try await store.connectLimitsLogin(
            account: first, startLogin: { _, _ in }, eraseScopedSecret: { _ in })
        let account = try #require(linked.accounts.first)
        let (oldFolder, _) = try await store.limitsLoginCredentials(account: account)
        let oldData = Data("synthetic-old-subscription".utf8)
        try await store.saveLimitsLoginCredentials(account: account, expected: nil, data: oldData)
        let gate = ClaudeAccountLimitsGate()
        let scopes = ClaudeAccountSecretRecorder()
        let erased = ClaudeAccountSecretRecorder()
        let finished = AccountSupportLimitsCompletion()
        let reconnect = Task {
            do {
                let result = try await store.connectLimitsLogin(
                    account: account,
                    startLogin: { id, folder in
                        #expect(id != account.limitsProfileID)
                        scopes.record(folder)
                        await gate.hold()
                        if !cancelled { throw ClaudeAccountLinkedFailure.startup }
                        let file = folder.appendingPathComponent(".credentials.json")
                        try Data("synthetic-late-new-subscription".utf8).write(to: file)
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o600], ofItemAtPath: file.path)
                    }, eraseScopedSecret: { erased.record($0) })
                await finished.finish()
                return result
            } catch {
                await finished.finish()
                throw error
            }
        }
        await gate.waitUntilHeld()
        do {
            let newFolder = try #require(scopes.values.first)
            #expect(newFolder != oldFolder)
            if cancelled { reconnect.cancel() }
            #expect(await finished.isFinished == false)
            #expect(try await store.load() == linked)
            #expect(try await store.limitsLoginCredentials(account: account).1 == oldData)
            #expect(FileManager.default.fileExists(atPath: newFolder.path))
            #expect(erased.values.isEmpty)
            await gate.release()
            if cancelled {
                await #expect(throws: CancellationError.self) { _ = try await reconnect.value }
            } else {
                await #expect(throws: ClaudeAccountLinkedFailure.self) {
                    _ = try await reconnect.value
                }
            }
            #expect(await finished.isFinished)
            #expect(try await store.load() == linked)
            #expect(try await store.limitsLoginCredentials(account: account).1 == oldData)
            #expect(erased.values == [newFolder])
            #expect(!FileManager.default.fileExists(atPath: newFolder.path))
            #expect(FileManager.default.fileExists(atPath: oldFolder.path))
        } catch {
            await gate.release()
            reconnect.cancel()
            _ = try? await reconnect.value
            throw error
        }
    }

    @Test func replacedScopeCleanupRetainsNewAuthorityAndRetriesOwnedJournal() async throws {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let first = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-exact-launch")
        try await store.save(.init(accounts: [first], defaultID: first.id))
        let linked = try await store.connectLimitsLogin(
            account: first, startLogin: { _, _ in }, eraseScopedSecret: { _ in })
        let account = try #require(linked.accounts.first)
        let (oldFolder, _) = try await store.limitsLoginCredentials(account: account)
        let oldData = Data("synthetic-old-subscription".utf8)
        try await store.saveLimitsLoginCredentials(account: account, expected: nil, data: oldData)
        let gate = ClaudeAccountLimitsGate()
        let scopes = ClaudeAccountSecretRecorder()
        let reconnect = Task {
            try await store.connectLimitsLogin(
                account: account,
                startLogin: { _, folder in scopes.record(folder) },
                eraseScopedSecret: { folder in
                    #expect(folder == oldFolder)
                    await gate.hold()
                    throw ClaudeAccountLinkedFailure.cleanup
                })
        }
        await gate.waitUntilHeld()
        do {
            let current = try await store.load()
            let replacement = try #require(current.accounts.first)
            #expect(replacement.limitsProfileID != account.limitsProfileID)
            #expect(replacement.credential == first.credential)
            #expect(current.defaultID == linked.defaultID)
            let (newFolder, newData) = try await store.limitsLoginCredentials(account: replacement)
            #expect(newFolder == scopes.values.first && newData == nil)
            #expect(FileManager.default.fileExists(atPath: oldFolder.path))
            await gate.release()
            await #expect(throws: ClaudeAccountLinkedFailure.self) {
                _ = try await reconnect.value
            }
            #expect(try await store.load() == current)
            let journal = directory.appendingPathComponent("limits-cleanup.json")
            #expect(
                try String(contentsOf: journal, encoding: .utf8).contains(
                    oldFolder.lastPathComponent))
            let erased = ClaudeAccountSecretRecorder()
            let retried = try await store.connectLimitsLogin(
                account: replacement, startLogin: { _, _ in },
                eraseScopedSecret: { erased.record($0) })
            #expect(Set(erased.values) == Set([oldFolder, newFolder]))
            #expect(!FileManager.default.fileExists(atPath: oldFolder.path))
            #expect(!FileManager.default.fileExists(atPath: newFolder.path))
            #expect(retried.accounts.first?.credential == first.credential)
            #expect(retried.defaultID == linked.defaultID)
            let retained = try String(contentsOf: journal, encoding: .utf8)
            #expect(!retained.contains(oldFolder.lastPathComponent))
            #expect(!retained.contains(newFolder.lastPathComponent))
        } catch {
            await gate.release()
            reconnect.cancel()
            _ = try? await reconnect.value
            throw error
        }
    }

    @Test func failedOrCancelledLinkedLoginJoinsCleanupWithoutChangingAccounts() async throws {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-exact-launch")
        let state = ClaudeAccountsState(accounts: [account], defaultID: account.id)
        try await store.save(state)
        let native = ClaudeAccountSecretRecorder()
        for cancelled in [false, true] {
            let task = Task {
                try await store.connectLimitsLogin(
                    account: account,
                    startLogin: { _, _ in
                        if cancelled {
                            withUnsafeCurrentTask { $0?.cancel() }
                        } else {
                            throw ClaudeAccountError.invalidRequest
                        }
                    }, eraseScopedSecret: { native.record($0) })
            }
            await #expect(throws: (any Error).self) { _ = try await task.value }
            #expect(try await store.load() == state)
        }
        #expect(native.values.count == 2)
        for folder in native.values {
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }

    @Test func linkedLoginRejectsStaleAccountAndUnownedProfileAssignments() async throws {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-exact-launch")
        let original = ClaudeAccountsState(accounts: [account], defaultID: account.id)
        try await store.save(original)
        var forged = original
        forged.accounts[0].limitsProfileID = UUID()
        await #expect(throws: ClaudeAccountError.self) { try await store.save(forged) }
        let native = ClaudeAccountSecretRecorder()
        await #expect(throws: ClaudeAccountError.self) {
            _ = try await store.connectLimitsLogin(
                account: account,
                startLogin: { _, _ in
                    var changed = original
                    changed.accounts[0].credential = "synthetic-foreign-credential"
                    try await ClaudeAccountStorage(directory: directory).save(
                        changed, expected: original)
                }, eraseScopedSecret: { native.record($0) })
        }
        #expect(try await store.load().accounts[0].credential == "synthetic-foreign-credential")
        #expect(try await store.load().accounts[0].limitsProfileID == nil)
        #expect(native.values.count == 1)
        #expect(!FileManager.default.fileExists(atPath: try #require(native.values.first).path))
    }

    @Test func linkedLoginPrivateFilesRejectUnsafeCredentialEntries() async throws {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let first = ClaudeAccount(name: "Synthetic first", credential: "synthetic-launch")
        try await store.save(.init(accounts: [first]))
        let state = try await store.connectLimitsLogin(
            account: first, startLogin: { _, _ in }, eraseScopedSecret: { _ in })
        let account = try #require(state.accounts.first)
        let (folder, _) = try await store.limitsLoginCredentials(account: account)
        let file = folder.appendingPathComponent(".credentials.json")
        let donor = root.appendingPathComponent("synthetic-donor")
        try Data("synthetic-donor-data".utf8).write(to: donor)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: donor.path)
        for kind in ["symlink", "hardlink", "public", "oversized"] {
            switch kind {
            case "symlink":
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: donor)
            case "hardlink": try FileManager.default.linkItem(at: donor, to: file)
            case "public":
                try Data("synthetic-public".utf8).write(to: file)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: file.path)
            default:
                try Data(repeating: 1, count: 65_537).write(to: file)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            await #expect(throws: ClaudeAccountError.self) {
                _ = try await store.limitsLoginCredentials(account: account)
            }
            await #expect(throws: ClaudeAccountError.self) {
                try await store.saveLimitsLoginCredentials(
                    account: account, expected: nil, data: Data())
            }
            try FileManager.default.removeItem(at: file)
        }
        #expect(try Data(contentsOf: donor) == Data("synthetic-donor-data".utf8))
    }

    @Test func linkedLoginLogoutRevokesReadAuthorityAndRetriesBothOwnedScopes() async throws {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let first = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-exact-launch")
        try await store.save(.init(accounts: [first]))
        let state = try await store.connectLimitsLogin(
            account: first, startLogin: { _, _ in }, eraseScopedSecret: { _ in })
        let account = try #require(state.accounts.first)
        let (folder, _) = try await store.limitsLoginCredentials(account: account)
        await #expect(throws: ClaudeAccountError.self) {
            _ = try await store.logout(
                id: account.id,
                eraseScopedSecret: { scope in
                    if scope == folder { throw ClaudeAccountError.invalidRequest }
                })
        }
        let revoked = try #require(try await store.load().accounts.first)
        #expect(revoked.isLoggedOut && revoked.credential.isEmpty)
        #expect(revoked.limitsProfileID == account.limitsProfileID)
        await #expect(throws: ClaudeAccountError.self) {
            _ = try await store.limitsLoginCredentials(account: revoked)
        }
        let native = ClaudeAccountSecretRecorder()
        let loggedOut = try await store.logout(
            id: account.id, eraseScopedSecret: { native.record($0) })
        #expect(loggedOut.accounts.first?.limitsProfileID == nil)
        #expect(
            native.values.map(\.path) == [
                directory.appendingPathComponent(account.id.uuidString).path, folder.path,
            ])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func failedLinkedCleanupPreservesBothErrorsAndRetriesPersistedOwnershipAfterReload()
        async throws
    {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-exact-launch")
        let state = ClaudeAccountsState(accounts: [account], defaultID: account.id)
        try await store.save(state)
        let profiles = ClaudeAccountSecretRecorder()
        do {
            _ = try await store.connectLimitsLogin(
                account: account,
                startLogin: { _, folder in
                    profiles.record(folder)
                    throw ClaudeAccountLinkedFailure.startup
                }, eraseScopedSecret: { _ in throw ClaudeAccountLinkedFailure.cleanup })
            Issue.record("Failed cleanup was reported as a successful link")
        } catch let failure as ClaudeLimitsLoginCleanupError {
            #expect(failure.originalError as? ClaudeAccountLinkedFailure == .startup)
            #expect(failure.cleanupError as? ClaudeAccountLinkedFailure == .cleanup)
        }
        #expect(try await store.load() == state)
        let folder = try #require(profiles.values.first)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        let journal = directory.appendingPathComponent("limits-cleanup.json")
        #expect(try mode(journal) == 0o600)
        let text = try String(contentsOf: journal, encoding: .utf8)
        #expect(text.contains(account.id.uuidString) && text.contains(folder.lastPathComponent))
        #expect(!text.contains(account.credential))
        let restored = ClaudeAccountStorage(directory: directory)
        let erased = ClaudeAccountSecretRecorder()
        _ = try await restored.logout(id: account.id, eraseScopedSecret: { erased.record($0) })
        #expect(
            erased.values.map(\.path) == [
                directory.appendingPathComponent(account.id.uuidString).path, folder.path,
            ])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(
            try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: String]]
                == [])
    }

    @Test func linkedProfileCollisionsRejectBeforeStartingLoginAndPreserveExistingScopes()
        async throws
    {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let first = ClaudeAccount(name: "Synthetic first", credential: "synthetic-first")
        let second = ClaudeAccount(name: "Synthetic second", credential: "synthetic-second")
        try await store.save(.init(accounts: [first, second], defaultID: first.id))
        let linked = try await store.connectLimitsLogin(
            account: second, startLogin: { _, _ in }, eraseScopedSecret: { _ in })
        let limitsID = try #require(linked.accounts[1].limitsProfileID)
        let (owned, _) = try await store.limitsLoginCredentials(account: linked.accounts[1])
        for id in [first.id, second.id, limitsID] {
            await #expect(throws: ClaudeAccountError.self) {
                _ = try await store.connectLimitsLogin(
                    account: first, newProfileID: id,
                    startLogin: { _, _ in Issue.record("Colliding profile reached login") },
                    eraseScopedSecret: { _ in Issue.record("Colliding profile erased a secret") })
            }
            #expect(try await store.load() == linked)
            #expect(FileManager.default.fileExists(atPath: owned.path))
        }
    }

    @Test(arguments: [false, true])
    func revocationJoinsHeldLimitsStartupBeforeRetiringItsLateWriter(forget: Bool) async throws {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch")
        try await store.save(.init(accounts: [account], defaultID: account.id))
        let gate = ClaudeAccountLimitsGate()
        let scopes = ClaudeAccountSecretRecorder()
        let started = Task {
            try await store.connectLimitsLogin(
                account: account,
                startLogin: { _, folder in
                    scopes.record(folder)
                    await gate.hold()
                    if !FileManager.default.fileExists(atPath: folder.path) {
                        try FileManager.default.createDirectory(
                            at: folder, withIntermediateDirectories: false,
                            attributes: [.posixPermissions: 0o700])
                    }
                    let file = folder.appendingPathComponent(".credentials.json")
                    try Data("synthetic-late-login".utf8).write(to: file)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: file.path)
                }, eraseScopedSecret: { scopes.record($0) })
        }
        await gate.waitUntilHeld()
        let finished = AccountSupportLimitsCompletion()
        let revoked = Task {
            let state =
                try await
                (forget
                ? store.forget(id: account.id, eraseScopedSecret: { scopes.record($0) })
                : store.logout(id: account.id, eraseScopedSecret: { scopes.record($0) }))
            await finished.finish()
            return state
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while try await store.load().accounts.first?.isLoggedOut != true {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await finished.isFinished == false)
            let folder = try #require(scopes.values.first)
            #expect(FileManager.default.fileExists(atPath: folder.path))
            let journal = directory.appendingPathComponent("limits-cleanup.json")
            #expect(try String(contentsOf: journal, encoding: .utf8).contains("true"))
            await gate.release()
            await #expect(throws: CancellationError.self) { _ = try await started.value }
            let result = try await revoked.value
            #expect(await finished.isFinished)
            #expect(forget ? result.accounts.isEmpty : result.accounts.first?.isLoggedOut == true)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            #expect(try String(contentsOf: journal, encoding: .utf8) == "[]")
        } catch {
            await gate.release()
            started.cancel()
            revoked.cancel()
            _ = try? await started.value
            _ = try? await revoked.value
            throw error
        }
    }

    @Test func foreignRevocationKeepsActiveCleanupOwnershipUntilStartupJoins() async throws {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch")
        try await store.save(.init(accounts: [account]))
        let gate = ClaudeAccountLimitsGate()
        let scopes = ClaudeAccountSecretRecorder()
        let startup = Task {
            try await store.connectLimitsLogin(
                account: account,
                startLogin: { _, folder in
                    scopes.record(folder)
                    await gate.hold()
                    let file = folder.appendingPathComponent(".credentials.json")
                    try Data("synthetic-late-login".utf8).write(to: file)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: file.path)
                }, eraseScopedSecret: { scopes.record($0) })
        }
        await gate.waitUntilHeld()
        do {
            let foreign = ClaudeAccountStorage(directory: directory)
            await #expect(throws: ClaudeAccountError.self) {
                _ = try await foreign.forget(
                    id: account.id,
                    eraseScopedSecret: { _ in
                        Issue.record("Foreign revocation erased before startup joined")
                    })
            }
            #expect(try await foreign.load().accounts.first?.isLoggedOut == true)
            let folder = try #require(scopes.values.first)
            #expect(FileManager.default.fileExists(atPath: folder.path))
            await gate.release()
            await #expect(throws: ClaudeAccountError.self) { _ = try await startup.value }
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            #expect(
                try await foreign.forget(id: account.id, eraseScopedSecret: { _ in }).accounts
                    .isEmpty)
        } catch {
            await gate.release()
            startup.cancel()
            _ = try? await startup.value
            throw error
        }
    }

    @Test func staleConnectingMarkerRecoversOnlyAfterAcquiringThePrivateStartupLease() async throws
    {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let store = ClaudeAccountStorage(directory: directory)
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch")
        try await store.save(.init(accounts: [account]))
        let scopes = ClaudeAccountSecretRecorder()
        await #expect(throws: ClaudeLimitsLoginCleanupError.self) {
            _ = try await store.connectLimitsLogin(
                account: account,
                startLogin: { _, folder in
                    scopes.record(folder)
                    throw ClaudeAccountLinkedFailure.startup
                }, eraseScopedSecret: { _ in throw ClaudeAccountLinkedFailure.cleanup })
        }
        let lease = directory.appendingPathComponent(".limits-start.lock")
        #expect(try mode(lease) == 0o600)
        let journal = directory.appendingPathComponent("limits-cleanup.json")
        var entries = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [[String: Any]])
        try #require(entries.count == 1)
        entries[0]["isConnecting"] = true
        try JSONSerialization.data(withJSONObject: entries).write(to: journal)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let restored = ClaudeAccountStorage(directory: directory)
        let erased = ClaudeAccountSecretRecorder()
        let revoked = try await restored.logout(
            id: account.id, eraseScopedSecret: { erased.record($0) })
        #expect(revoked.accounts.first?.isLoggedOut == true)
        #expect(erased.values.contains { $0.path == scopes.values.first?.path })
        #expect(!FileManager.default.fileExists(atPath: try #require(scopes.values.first).path))
        #expect(try String(contentsOf: journal, encoding: .utf8) == "[]")
    }

    @Test(arguments: [false, true])
    func revocationJoinsHeldRenewalBeforeErasingItsLateNativeWrite(forget: Bool) async throws {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeAccountStorage(directory: root.appendingPathComponent("Accounts"))
        let original = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch")
        try await store.save(.init(accounts: [original], defaultID: original.id))
        let account = try #require(
            try await store.connectLimitsLogin(
                account: original, startLogin: { _, _ in }, eraseScopedSecret: { _ in }
            )
            .accounts.first)
        let (folder, _) = try await store.limitsLoginCredentials(account: account)
        let previous = Data("synthetic-previous".utf8)
        let renewed = Data("synthetic-renewed".utf8)
        try await store.saveLimitsLoginCredentials(account: account, expected: nil, data: previous)
        let gate = ClaudeAccountLimitsGate()
        let operations = ClaudeAccountSecretRecorder()
        let renewal = Task {
            try await store.renewLimitsLogin(
                account: account, expected: previous, data: renewed,
                writeScopedSecret: { scope, data in
                    #expect(scope == folder && data == renewed)
                    await gate.hold()
                    operations.record(scope)
                })
        }
        await gate.waitUntilHeld()
        let finished = AccountSupportLimitsCompletion()
        let revocation = Task {
            let state =
                try await
                (forget
                ? store.forget(id: account.id, eraseScopedSecret: { operations.record($0) })
                : store.logout(id: account.id, eraseScopedSecret: { operations.record($0) }))
            await finished.finish()
            return state
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while try await store.load().accounts.first?.isLoggedOut != true {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await finished.isFinished == false)
            #expect(operations.values.isEmpty)
            #expect(FileManager.default.fileExists(atPath: folder.path))
            await gate.release()
            await #expect(throws: CancellationError.self) { try await renewal.value }
            let state = try await revocation.value
            #expect(forget ? state.accounts.isEmpty : state.accounts.first?.isLoggedOut == true)
            #expect(operations.values.filter { $0 == folder }.count == 2)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        } catch {
            await gate.release()
            renewal.cancel()
            revocation.cancel()
            _ = try? await renewal.value
            _ = try? await revocation.value
            throw error
        }
    }

    @Test func foreignRevocationRetainsRenewalCleanupAuthorityUntilTheWriterJoins() async throws {
        let root = try limitsFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts")
        let store = ClaudeAccountStorage(directory: directory)
        let original = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch")
        try await store.save(.init(accounts: [original]))
        let account = try #require(
            try await store.connectLimitsLogin(
                account: original, startLogin: { _, _ in }, eraseScopedSecret: { _ in }
            )
            .accounts.first)
        let (folder, _) = try await store.limitsLoginCredentials(account: account)
        let gate = ClaudeAccountLimitsGate()
        let operations = ClaudeAccountSecretRecorder()
        let renewal = Task {
            try await store.renewLimitsLogin(
                account: account, expected: nil, data: Data("synthetic-renewed".utf8),
                writeScopedSecret: { scope, _ in
                    await gate.hold()
                    operations.record(scope)
                })
        }
        await gate.waitUntilHeld()
        do {
            let foreign = ClaudeAccountStorage(directory: directory)
            await #expect(throws: ClaudeAccountError.self) {
                _ = try await foreign.forget(
                    id: account.id, eraseScopedSecret: { operations.record($0) })
            }
            #expect(operations.values.isEmpty)
            #expect(try await foreign.load().accounts.first?.isLoggedOut == true)
            let journal = directory.appendingPathComponent("limits-cleanup.json")
            #expect(try String(contentsOf: journal, encoding: .utf8).contains("true"))
            await gate.release()
            await #expect(throws: ClaudeAccountError.self) { try await renewal.value }
            #expect(operations.values == [folder])
            #expect(try String(contentsOf: journal, encoding: .utf8).contains("false"))
            #expect(
                try await foreign.forget(
                    id: account.id, eraseScopedSecret: { operations.record($0) }
                )
                .accounts.isEmpty)
            #expect(operations.values.filter { $0 == folder }.count == 2)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            #expect(try String(contentsOf: journal, encoding: .utf8) == "[]")
        } catch {
            await gate.release()
            renewal.cancel()
            _ = try? await renewal.value
            throw error
        }
    }
}

private final class ClaudeAccountSecretRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var values: [URL] { lock.withLock { stored } }
    func record(_ url: URL) { lock.withLock { stored.append(url) } }
}

private enum ClaudeAccountLinkedFailure: Error {
    case startup
    case cleanup
}

private actor ClaudeAccountLimitsGate {
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func hold() async {
        held = true
        waiting?.resume()
        waiting = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor AccountSupportLimitsCompletion {
    private(set) var isFinished = false
    func finish() { isFinished = true }
}
