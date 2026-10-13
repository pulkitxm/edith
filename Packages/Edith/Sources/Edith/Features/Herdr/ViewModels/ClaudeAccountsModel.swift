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
    private let storage: ClaudeAccountStorage

    init(directory: URL? = nil) {
        self.directory = directory ?? ClaudeAccountStorage.directory
        storage = ClaudeAccountStorage(directory: self.directory)
    }

    func read() async {
        guard !saving else { return }
        do {
            try await load()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func load() async throws {
        state = try await storage.load()
        ready = true
    }

    func save(_ next: ClaudeAccountsState) async {
        guard ready, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await persist(next)
            try? UsageAgentOperations.requestLimitsRefresh()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func importCurrentCLIAccount(on machine: Machine? = nil) async -> ClaudeAccount? {
        guard ready, !saving else { return nil }
        saving = true
        defer { saving = false }
        do {
            let account: ClaudeAccount
            if let machine {
                account = try await ClaudeAccount.currentCLIAccount(on: machine)
            } else {
                let environment = try await ClaudeAccount.currentCLIEnvironment()
                account = try await Task.detached {
                    try ClaudeAccount.currentCLIAccount(
                        environment: environment,
                        savedLoginData: ClaudeSavedLogin.credentials(environment: environment))
                }.value
            }
            var next = state
            next.accounts.append(account)
            next.defaultID = account.id
            try await persist(next)
            try? UsageAgentOperations.requestLimitsRefresh()
            error = nil
            return account
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func connectLimitsLogin(
        _ account: ClaudeAccount,
        startLogin: (ClaudeAccount) async throws -> Void = { profile in
            let pane = try await HerdrLaunchOperations.createWorkspace(
                label: "Limits: " + profile.name, on: nil)
            try await HerdrLaunchOperations.launchAccount(
                account: profile,
                command: HerdrLaunchSettings.command(for: "Claude Code"),
                arguments: HerdrLaunchSettings.sharedArguments().split(separator: "\n").map(
                    String.init),
                environment: HerdrLaunchSettings.sharedEnvironment(), pane: pane.paneID, on: nil,
                authenticationOnly: true)
            let store = HerdrStore.shared
            let host = store.hosts.first { $0.isLocal }
            store.open(
                HerdrAgent.make(
                    machineID: host?.id ?? "local", machineName: host?.name ?? "This Mac",
                    machineIsLocal: true, sshTarget: nil, session: "default", pane: pane.paneID,
                    kind: "Claude Code", status: .unknown, title: "Limits: " + profile.name,
                    workspace: "Limits: " + profile.name, cwd: ""))
            store.revealWorkspaceWindow()
        }
    ) async -> ClaudeAccount? {
        guard ready, !saving, state.accounts.contains(where: { $0.id == account.id }),
            account.authentication == .oauthToken
        else { return nil }
        saving = true
        defer { saving = false }
        do {
            try account.validateLaunch()
            let profile = ClaudeAccount(name: account.name, authentication: .browserLogin)
            try await startLogin(profile)
            var linked = account
            linked.limitsProfileID = profile.id
            var next = state
            next.accounts[next.accounts.firstIndex(where: { $0.id == account.id })!] = linked
            try await persist(next)
            try? UsageAgentOperations.requestLimitsRefresh()
            error = nil
            return linked
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func persist(_ next: ClaudeAccountsState) async throws {
        try await storage.save(next)
        state = next
        ready = true
    }

    func account(_ id: UUID?) -> ClaudeAccount? { state.accounts.first { $0.id == id } }

    func rememberLaunchSelection(_ selection: String) async {
        guard let id = UUID(uuidString: selection), account(id) != nil else { return }
        do {
            state = try await storage.rememberLaunchAccount(id)
            try? UsageAgentOperations.requestLimitsRefresh()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func launchSelection(_ selection: String) -> String {
        if let id = UUID(uuidString: selection), account(id) != nil { return id.uuidString }
        return (account(state.defaultID) ?? state.accounts.first)?.id.uuidString ?? "cli"
    }
}
