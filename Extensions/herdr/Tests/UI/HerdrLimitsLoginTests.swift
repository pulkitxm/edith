import Darwin
import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrUI

@Suite @MainActor struct HerdrLimitsLoginTests {
    private func fixture() throws -> URL {
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func finished(
        _ login: HerdrLimitsLogin, _ state: HerdrLimitsLoginState
    ) async throws -> HerdrLimitsLoginState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            let current = try login.status(accountID: state.accountID, ticket: state.ticket)
            if current.phase != .connecting { return current }
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func loginLaunchPreservesAliasAndPrivateScopeWithoutLaunchAuthentication() throws {
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch-secret")
        let profileID = UUID()
        let folder = URL(fileURLWithPath: "/synthetic/accounts").appendingPathComponent(
            profileID.uuidString)
        let launch = try HerdrLimitsLoginLaunch.prepare(
            account: account, profileID: profileID, folder: folder, command: "cc",
            sharedEnvironment: "LITERAL=$(touch forbidden); 'quoted'",
            inheritedEnvironment: [
                "PATH": "/usr/bin:/bin", "anthropic_api_key": "synthetic-inherited-key",
                "CLAUDE_CODE_OAUTH_TOKEN": account.credential,
                "CLAUDE_CONFIG_DIR": "/synthetic/other", "HISTFILE": "/synthetic/history",
            ])
        #expect(launch.executable == "/bin/zsh")
        #expect(Array(launch.arguments.prefix(3)) == ["-l", "-i", "-c"])
        let script = try #require(launch.arguments.last)
        #expect(script.contains("cc auth login"))
        #expect(script.contains("CLAUDE_CONFIG_DIR=" + ShellQuote.quote(folder.path)))
        #expect(script.contains("CLAUDE_SECURESTORAGE_CONFIG_DIR=" + ShellQuote.quote(folder.path)))
        #expect(script.contains("unset HISTFILE; SAVEHIST=0;"))
        #expect(!script.contains(account.credential))
        #expect(!launch.environment.contains(where: { $0.contains("synthetic-inherited") }))
        #expect(!launch.environment.contains(where: { $0.contains(account.credential) }))
        #expect(!launch.environment.contains(where: { $0.contains("/synthetic/other") }))
        #expect(launch.environment.contains("HISTFILE=/dev/null"))
        #expect(launch.currentDirectory == folder.path)
        #expect(!launch.allowsLocalFileLinks && !launch.resetTerminalAfterInterrupt)
        #expect(
            script.contains("export LITERAL=" + ShellQuote.quote("$(touch forbidden); 'quoted'")))
        for history in [
            "HISTFILE=/synthetic/history", "histfile=/synthetic/history",
            "SAVEHIST=1000", "SaveHist=1000",
        ] {
            #expect(throws: ClaudeAccountError.self) {
                _ = try HerdrLimitsLoginLaunch.prepare(
                    account: account, profileID: profileID, folder: folder, command: "cc",
                    sharedEnvironment: history, inheritedEnvironment: [:])
            }
            #expect(try HerdrLaunchSettings.environmentAssignments(history).count == 1)
        }
        var rejected = account
        rejected.isLoggedOut = true
        #expect(throws: ClaudeAccountError.self) {
            _ = try HerdrLimitsLoginLaunch.prepare(
                account: rejected, profileID: profileID, folder: folder, command: "cc",
                sharedEnvironment: "", inheritedEnvironment: [:])
        }
        #expect(throws: ClaudeAccountError.self) {
            _ = try HerdrLimitsLoginLaunch.prepare(
                account: account, profileID: account.id, folder: folder, command: "cc",
                sharedEnvironment: "", inheritedEnvironment: [:])
        }
    }

    @Test func successfulLoginPublishesIdentityOnlyAndSavesAfterTerminalJoin() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ClaudeAccountStorage(directory: root.appendingPathComponent("Accounts"))
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch-secret")
        let original = ClaudeAccountsState(accounts: [account], defaultID: account.id)
        try await storage.save(original)
        let terminal = HerdrLimitsTerminalFixture()
        let login = HerdrLimitsLogin(
            services: .init(create: { _ in terminal }, eraseScopedSecret: { _ in }))
        do {
            let state = try login.begin(
                account: account, ticket: UUID(), storage: storage, command: "cc",
                sharedEnvironment: "",
                inheritedEnvironment: [:])
            await terminal.waitUntilExitHeld()
            let waiting = try login.status(accountID: account.id, ticket: state.ticket)
            #expect(waiting.session == terminal.handle && waiting.phase == .connecting)
            let encoded = try JSONEncoder().encode(waiting)
            let object = try #require(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(Set(object.keys) == ["accountID", "ticket", "session", "phase"])
            #expect(!String(decoding: encoded, as: UTF8.self).contains(account.credential))
            #expect(throws: ExtensionPeerError.self) {
                _ = try login.begin(
                    account: account, ticket: UUID(), storage: storage, command: "cc",
                    sharedEnvironment: "",
                    inheritedEnvironment: [:])
            }
            #expect(throws: ExtensionPeerError.self) {
                _ = try login.status(accountID: UUID(), ticket: state.ticket)
            }
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await login.cancel(accountID: account.id, ticket: UUID())
            }
            terminal.completeExit(0)
            await terminal.waitUntilCloseHeld()
            #expect(try await storage.load() == original)
            #expect(
                try login.status(accountID: account.id, ticket: state.ticket).phase == .connecting)
            terminal.releaseClose()
            let result = try await finished(login, state)
            #expect(result.phase == .connected && result.session == nil)
            let saved = try await storage.load()
            #expect(saved.accounts.first?.limitsProfileID != nil)
            #expect(saved.accounts.first?.credential == account.credential)
            #expect(saved.defaultID == original.defaultID)
            #expect(terminal.closeCalls == 1)
            #expect(throws: ExtensionPeerError.self) {
                _ = try login.begin(
                    account: account, ticket: state.ticket, storage: storage, command: "cc",
                    sharedEnvironment: "", inheritedEnvironment: [:])
            }
            await login.stopAndWait()
        } catch {
            terminal.releaseClose()
            await login.stopAndWait()
            throw error
        }
    }

    @Test(arguments: ["cancel", "logout", "forget", "shutdown"])
    func revocationAndShutdownJoinTerminalBeforeRetiringLogin(action: String) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ClaudeAccountStorage(directory: root.appendingPathComponent("Accounts"))
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch-secret")
        try await storage.save(.init(accounts: [account]))
        let terminal = HerdrLimitsTerminalFixture()
        let login = HerdrLimitsLogin(
            services: .init(create: { _ in terminal }, eraseScopedSecret: { _ in }))
        let state = try login.begin(
            account: account, ticket: UUID(), storage: storage, command: "cc",
            sharedEnvironment: "",
            inheritedEnvironment: [:])
        await terminal.waitUntilExitHeld()
        let completed = HerdrLimitsCompletionFixture()
        let revoke = Task {
            if action == "cancel" {
                _ = try await login.cancel(accountID: account.id, ticket: state.ticket)
            } else if action == "logout" {
                _ = try await storage.logout(id: account.id, eraseScopedSecret: { _ in })
            } else if action == "forget" {
                _ = try await storage.forget(id: account.id, eraseScopedSecret: { _ in })
            } else {
                await login.stopAndWait()
            }
            completed.finished = true
        }
        do {
            await terminal.waitUntilCloseHeld()
            #expect(!completed.finished)
            #expect(
                try login.status(accountID: account.id, ticket: state.ticket).phase == .connecting)
            terminal.releaseClose()
            try await revoke.value
            let result = try await finished(login, state)
            #expect(result.phase == .cancelled && result.session == nil)
            #expect(terminal.closeCalls == 1)
            let saved = try await storage.load()
            if action == "forget" {
                #expect(saved.accounts.isEmpty)
            } else if action == "logout" {
                #expect(saved.accounts.first?.isLoggedOut == true)
            } else {
                #expect(saved.accounts.first == account)
            }
            await login.stopAndWait()
        } catch {
            terminal.releaseClose()
            revoke.cancel()
            await login.stopAndWait()
            _ = try? await revoke.value
            throw error
        }
    }

    @Test func failedExitAndForeignTerminalIdentityAllowAJoinedRetry() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ClaudeAccountStorage(directory: root.appendingPathComponent("Accounts"))
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch-secret")
        let original = ClaudeAccountsState(accounts: [account])
        try await storage.save(original)
        let failed = HerdrLimitsTerminalFixture()
        let foreign = HerdrLimitsTerminalFixture(owner: "foreign")
        let retry = HerdrLimitsTerminalFixture()
        var terminals = [failed, foreign, retry]
        let login = HerdrLimitsLogin(
            services: .init(create: { _ in terminals.removeFirst() }, eraseScopedSecret: { _ in }))
        do {
            let first = try login.begin(
                account: account, ticket: UUID(), storage: storage, command: "cc",
                sharedEnvironment: "",
                inheritedEnvironment: [:])
            await failed.waitUntilExitHeld()
            failed.completeExit(2)
            await failed.waitUntilCloseHeld()
            #expect(try await storage.load() == original)
            failed.releaseClose()
            #expect(try await finished(login, first).phase == .failed)
            #expect(try await storage.load() == original)
            let second = try login.begin(
                account: account, ticket: UUID(), storage: storage, command: "cc",
                sharedEnvironment: "",
                inheritedEnvironment: [:])
            await foreign.waitUntilCloseHeld()
            #expect(!foreign.exitWasRequested)
            foreign.releaseClose()
            #expect(try await finished(login, second).phase == .failed)
            #expect(try await storage.load() == original)
            let third = try login.begin(
                account: account, ticket: UUID(), storage: storage, command: "cc",
                sharedEnvironment: "",
                inheritedEnvironment: [:])
            await retry.waitUntilExitHeld()
            retry.completeExit(0)
            await retry.waitUntilCloseHeld()
            retry.releaseClose()
            #expect(try await finished(login, third).phase == .connected)
            #expect([failed, foreign, retry].allSatisfy { $0.closeCalls == 1 })
            await login.stopAndWait()
        } catch {
            for terminal in [failed, foreign, retry] { terminal.releaseClose() }
            await login.stopAndWait()
            throw error
        }
    }
}

@MainActor private final class HerdrLimitsCompletionFixture {
    var finished = false
}

@MainActor final class HerdrLimitsTerminalFixture: HerdrLimitsLoginTerminal {
    let handle: OwnedTerminalHandle
    private var exit: CheckedContinuation<Int32, Error>?
    private var exitWaiting: CheckedContinuation<Void, Never>?
    private var closeWaiting: CheckedContinuation<Void, Never>?
    private var close: CheckedContinuation<Void, Never>?
    private var closing = false
    private var closeReleased = false
    private var cancelled = false
    private(set) var closeCalls = 0
    private(set) var exitWasRequested = false

    init(owner: String = "herdr") {
        handle = .init(owner: owner, id: UUID(), generation: UUID())
    }

    func waitForExit() async throws -> Int32 {
        try Task.checkCancellation()
        exitWasRequested = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    exit = continuation
                }
                exitWaiting?.resume()
                exitWaiting = nil
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelled = true
                self.exit?.resume(throwing: CancellationError())
                self.exit = nil
            }
        }
    }

    func waitUntilExitHeld() async {
        if exitWasRequested { return }
        await withCheckedContinuation { exitWaiting = $0 }
    }

    func completeExit(_ code: Int32) {
        exit?.resume(returning: code)
        exit = nil
    }

    func closeAndWait() async {
        closeCalls += 1
        closing = true
        closeWaiting?.resume()
        closeWaiting = nil
        if closeReleased { return }
        await withCheckedContinuation { close = $0 }
    }

    func waitUntilCloseHeld() async {
        if closing { return }
        await withCheckedContinuation { closeWaiting = $0 }
    }

    func releaseClose() {
        closeReleased = true
        close?.resume()
        close = nil
    }
}
