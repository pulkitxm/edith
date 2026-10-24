import EdithKit
import Foundation
import Observation

@MainActor @Observable final class ClaudeAccountsModel {
    static let shared = ClaudeAccountsModel()
    private(set) var state = ClaudeAccountsState()
    private(set) var error: String?
    private(set) var ready = false
    private(set) var saving = false
    let directory: URL
    let storage: ClaudeAccountStorage
    let subscriptionLogin: ClaudeSubscriptionLogin
    private let eraseSecret: @Sendable (URL) throws -> Void
    private let notifyUsage: @Sendable () async -> Void

    init(
        directory: URL = ClaudeAccountStorage.defaultDirectory,
        subscriptionLogin: ClaudeSubscriptionLogin? = nil,
        eraseSecret: @escaping @Sendable (URL) throws -> Void = {
            try ClaudeAccountKeychain.eraseScopedSecret($0)
        },
        notifyUsage: @escaping @Sendable () async -> Void = {
            try? UsageAgentOperations.requestLimitsRefresh()
        }
    ) {
        self.directory = directory
        storage = ClaudeAccountStorage(directory: directory)
        self.subscriptionLogin = subscriptionLogin ?? ClaudeSubscriptionLogin()
        self.eraseSecret = eraseSecret
        self.notifyUsage = notifyUsage
    }

    func read() async {
        guard !saving else { return }
        do {
            try await load()
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func load() async throws {
        let next = try await storage.load()
        try Task.checkCancellation()
        try next.validate()
        state = next
        ready = true
        error = nil
    }

    func save(_ next: ClaudeAccountsState) async {
        guard ready else {
            error = "Reload accounts before making a change."
            return
        }
        guard !saving else {
            error = "An account change is already in progress. Try again when it finishes."
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await persist(next)
            await notifyChanged()
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func importCurrentCLIAccount(on machine: Machine? = nil) async -> ClaudeAccount? {
        guard ready, !saving else { return nil }
        saving = true
        defer { saving = false }
        do {
            var account: ClaudeAccount
            if let machine {
                account = try await ClaudeAccount.currentCLIAccount(on: machine)
                account.remoteMachineID = machine.id.uuidString
            } else {
                let environment = try await ClaudeAccount.currentCLIEnvironment()
                try Task.checkCancellation()
                account = try ClaudeAccount.currentCLIAccount(
                    environment: environment,
                    savedLoginData: ClaudeAccountKeychain.credentials(environment: environment))
            }
            try Task.checkCancellation()
            var next = state
            next.accounts.append(account)
            next.defaultID = account.id
            try await persist(next)
            await notifyChanged()
            error = nil
            return account
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
            return nil
        }
    }

    func forget(_ id: UUID) async {
        await remove(id, forget: true)
    }

    func logout(_ id: UUID) async {
        await remove(id, forget: false)
    }

    private func remove(_ id: UUID, forget: Bool) async {
        guard ready, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            await subscriptionLogin.cancel(accountID: id)
            let previous = account(id)
            state = try await storage.logout(id: id, eraseScopedSecret: eraseSecret)
            if let machineID = previous?.remoteMachineID {
                try await ClaudeAccountImport.removeRemoteProfile(
                    accountID: id, machineID: machineID)
            }
            if forget {
                state = try await storage.forget(id: id, eraseScopedSecret: eraseSecret)
            }
            try Task.checkCancellation()
            await notifyChanged()
            error = nil
        } catch {
            let failure = error.localizedDescription
            if !Task.isCancelled { try? await load() }
            await notifyChanged()
            if !Task.isCancelled { self.error = failure }
        }
    }

    func persist(_ next: ClaudeAccountsState) async throws {
        try Task.checkCancellation()
        try await storage.save(next, expected: state)
        try Task.checkCancellation()
        state = next
        ready = true
    }

    func account(_ id: UUID?) -> ClaudeAccount? { state.accounts.first { $0.id == id } }

    var launchAccounts: [ClaudeAccount] { state.accounts }

    func launchSelection(_ selection: String) -> String {
        if selection == "cli" { return selection }
        if let id = UUID(uuidString: selection), account(id) != nil { return id.uuidString }
        return (account(state.defaultID) ?? state.accounts.first)?.id.uuidString ?? "cli"
    }

    func rememberLaunchSelection(_ selection: String) async -> Bool {
        if selection == "cli" { return true }
        guard ready else {
            error = "Reload accounts before choosing an account."
            return false
        }
        guard !saving else {
            error = "An account change is already in progress. Try again when it finishes."
            return false
        }
        guard let id = UUID(uuidString: selection), account(id) != nil else {
            error = "This account was removed. Choose another account."
            return false
        }
        saving = true
        defer { saving = false }
        do {
            let next = try await storage.rememberLaunchAccount(id)
            try Task.checkCancellation()
            state = next
            ready = true
            await notifyChanged()
            try Task.checkCancellation()
            error = nil
            return true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
            return false
        }
    }

    func notifyChanged() async {
        let notify = notifyUsage
        await Task.detached { await notify() }.value
    }
}
