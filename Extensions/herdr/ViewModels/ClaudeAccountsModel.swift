import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class ClaudeAccountsModel {
    static let shared = ClaudeAccountsModel()
    private(set) var state = ClaudeAccountsState()
    private(set) var error: String?
    private(set) var ready = false
    private(set) var saving = false
    private let suppliedDirectory: URL?
    let client: HerdrUIClient?
    private var storage: ClaudeAccountStorage?
    let limitsLoginOwner: HerdrLimitsLogin
    let subscriptionLogin = HerdrLimitsLoginPresentation()
    private var requests: [UUID: Task<Data, Error>] = [:]
    private var stopped = false
    private let eraseSecret: @Sendable (URL) throws -> Void
    private let readState: @Sendable (ClaudeAccountStorage) async throws -> ClaudeAccountsState
    private let invalidateUsage: @Sendable () async -> Void
    private let refreshUsage: @Sendable () async -> Void

    var hasConfiguredStore: Bool {
        suppliedDirectory != nil
            || (try? ClaudeAccountStorage.directory(
                environment: ProcessInfo.processInfo.environment)) != nil
    }

    var directory: URL {
        get throws {
            if let suppliedDirectory { return suppliedDirectory }
            return try ClaudeAccountStorage.directory(
                environment: ProcessInfo.processInfo.environment)
        }
    }

    init(
        directory: URL? = nil, client: HerdrUIClient? = nil,
        limitsLogin: HerdrLimitsLogin? = nil,
        readState: @escaping @Sendable (ClaudeAccountStorage) async throws -> ClaudeAccountsState =
            {
                try await $0.load()
            },
        eraseSecret: @escaping @Sendable (URL) throws -> Void = ClaudeAccountImport
            .eraseScopedSecret,
        invalidateUsage: @escaping @Sendable () async -> Void = ClaudeAccountsModel
            .invalidateEnabledUsage,
        refreshUsage: @escaping @Sendable () async -> Void = ClaudeAccountsModel
            .refreshEnabledUsage
    ) {
        suppliedDirectory = directory
        self.client = client
        limitsLoginOwner = limitsLogin ?? HerdrLimitsLogin()
        self.readState = readState
        self.eraseSecret = eraseSecret
        self.invalidateUsage = invalidateUsage
        self.refreshUsage = refreshUsage
    }

    private func ownedStorage() throws -> ClaudeAccountStorage {
        guard !stopped, client == nil else { throw ExtensionPeerError.unavailable }
        if let storage { return storage }
        let value = ClaudeAccountStorage(directory: try directory)
        storage = value
        return value
    }

    func read() async {
        guard !saving, !stopped else { return }
        do {
            try await load()
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func load() async throws {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let next: ClaudeAccountsState
        if client != nil {
            next = try await perform("herdr.ui.accounts.read")
        } else {
            next = try await readState(ownedStorage())
        }
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try next.validate()
        state = next
        ready = true
        error = nil
    }

    func save(_ next: ClaudeAccountsState) async {
        guard ready, !stopped else {
            if !stopped { error = "Reload accounts before making a change." }
            return
        }
        guard !saving else {
            error = "An account change is already in progress. Try again when it finishes."
            return
        }
        saving = true
        defer { saving = false }
        do {
            if client != nil {
                let payload = try JSONEncoder().encode(
                    ClaudeAccountsMutation(baseline: state, state: next))
                state = try await perform("herdr.ui.accounts.save", payload: payload)
            } else {
                try await persist(next)
            }
            await notifyChanged()
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func importCurrentCLIAccount(on machine: Machine? = nil, machineID: String? = nil) async
        -> ClaudeAccount?
    {
        guard ready, !saving, !stopped else { return nil }
        saving = true
        defer { saving = false }
        do {
            let previous = Set(state.accounts.map(\.id))
            if client != nil {
                let payload = try JSONSerialization.data(
                    withJSONObject: (machine?.id.uuidString ?? machineID).map { ["machineID": $0] }
                        ?? [:])
                state = try await perform("herdr.ui.accounts.import", payload: payload)
            } else {
                var account: ClaudeAccount
                if let machine {
                    account = try await ClaudeAccount.currentCLIAccount(on: machine)
                    account.remoteMachineID = machine.id.uuidString
                } else {
                    let environment = try await ClaudeAccount.currentCLIEnvironment()
                    try Task.checkCancellation()
                    account = try ClaudeAccount.currentCLIAccount(
                        environment: environment,
                        savedLoginData: ClaudeAccountImport.credentials(environment: environment))
                }
                try Task.checkCancellation()
                var next = state
                next.accounts.append(account)
                next.defaultID = account.id
                try await persist(next)
            }
            await notifyChanged()
            error = nil
            return state.accounts.first { !previous.contains($0.id) }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
            return nil
        }
    }

    func forget(_ id: UUID) async {
        guard ready, !saving, !stopped else { return }
        saving = true
        defer { saving = false }
        do {
            if client != nil {
                state = try await perform(
                    "herdr.ui.accounts.forget",
                    payload: JSONSerialization.data(withJSONObject: ["id": id.uuidString]))
            } else {
                await limitsLoginOwner.cancel(accountID: id)
                let previous = account(id)
                state = try await ownedStorage().logout(
                    id: id, eraseScopedSecret: eraseSecret)
                if let machineID = previous?.remoteMachineID {
                    try await ClaudeAccountImport.removeRemoteProfile(
                        accountID: id, machineID: machineID)
                }
                state = try await ownedStorage().forget(
                    id: id, eraseScopedSecret: eraseSecret)
            }
            try Task.checkCancellation()
            await notifyChanged()
            error = nil
        } catch {
            let failure = error.localizedDescription
            if client == nil {
                if !Task.isCancelled { try? await load() }
                await notifyChanged()
            }
            if !Task.isCancelled { self.error = failure }
        }
    }

    func logout(_ id: UUID) async {
        guard ready, !saving, !stopped else { return }
        saving = true
        defer { saving = false }
        do {
            if client != nil {
                state = try await perform(
                    "herdr.ui.accounts.logout",
                    payload: JSONSerialization.data(withJSONObject: ["id": id.uuidString]))
            } else {
                await limitsLoginOwner.cancel(accountID: id)
                let previous = account(id)
                state = try await ownedStorage().logout(
                    id: id, eraseScopedSecret: eraseSecret)
                if let machineID = previous?.remoteMachineID {
                    try await ClaudeAccountImport.removeRemoteProfile(
                        accountID: id, machineID: machineID)
                }
            }
            await notifyChanged()
            error = nil
        } catch {
            let failure = error.localizedDescription
            if client == nil {
                if !Task.isCancelled { try? await load() }
                await notifyChanged()
            }
            if !Task.isCancelled { self.error = failure }
        }
    }

    func persist(_ next: ClaudeAccountsState) async throws {
        try Task.checkCancellation()
        try await ownedStorage().save(next, expected: state)
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
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
        guard ready, !stopped else {
            if !stopped { error = "Reload accounts before choosing an account." }
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
            let next: ClaudeAccountsState
            if client != nil {
                next = try await perform(
                    "herdr.ui.accounts.select",
                    payload: JSONSerialization.data(withJSONObject: ["id": id.uuidString]))
            } else {
                next = try await ownedStorage().rememberLaunchAccount(id)
            }
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            state = next
            ready = true
            await notifyLaunchSelection()
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            error = nil
            return true
        } catch {
            if !Task.isCancelled, !stopped { self.error = error.localizedDescription }
            return false
        }
    }

    func performData(_ command: String, payload: Data = Data("{}".utf8)) async throws -> Data {
        guard !stopped, let client, requests.count < 8 else { throw ExtensionPeerError.unavailable }
        let id = UUID()
        let task = Task { try await client.perform(command, payload: payload) }
        requests[id] = task
        defer { requests[id] = nil }
        let data = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard !stopped, data.count <= 65_536 else { throw ExtensionPeerError.invalidRequest }
        return data
    }

    private func perform(_ command: String, payload: Data = Data("{}".utf8)) async throws
        -> ClaudeAccountsState
    {
        let next = try JSONDecoder().decode(
            ClaudeAccountsState.self, from: await performData(command, payload: payload))
        try next.validate()
        return next
    }

    func startLimitsLogin(_ id: UUID, ticket: UUID, defaults: UserDefaults) async throws
        -> HerdrLimitsLoginState
    {
        guard ready, !stopped, !saving, let account = account(id) else {
            throw ExtensionPeerError.invalidRequest
        }
        saving = true
        defer { saving = false }
        if client != nil {
            return try limitsLoginReply(
                await performData(
                    "herdr.ui.accounts.limitsStart",
                    payload: JSONSerialization.data(withJSONObject: [
                        "id": id.uuidString, "ticket": ticket.uuidString,
                    ])), accountID: id, ticket: ticket)
        }
        var environment = CLIToolEnvironment.sanitized()
        if let fixture = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] {
            environment["HOME"] = fixture
            environment["ZDOTDIR"] = fixture
        }
        return try limitsLoginOwner.begin(
            account: account, ticket: ticket, storage: ownedStorage(),
            command: HerdrLaunchSettings.command(for: "Claude Code", in: defaults),
            sharedEnvironment: HerdrLaunchSettings.sharedEnvironment(in: defaults),
            inheritedEnvironment: environment,
            didConnect: { [weak self] in
                guard let self, !self.stopped else { return }
                try? await self.load()
                await self.notifyChanged()
            })
    }

    func limitsLoginStatus(_ state: HerdrLimitsLoginState) async throws -> HerdrLimitsLoginState {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if client != nil { return try await performLimitsLogin("limitsStatus", state: state) }
        return try limitsLoginOwner.status(accountID: state.accountID, ticket: state.ticket)
    }

    func cancelLimitsLogin(_ state: HerdrLimitsLoginState) async throws -> HerdrLimitsLoginState {
        if client != nil { return try await performLimitsLogin("limitsCancel", state: state) }
        return try await limitsLoginOwner.cancel(accountID: state.accountID, ticket: state.ticket)
    }

    func limitsTerminal(_ operation: String, payload: Data) async throws -> Data {
        if client != nil { return try await performData(operation, payload: payload) }
        return try await limitsLoginOwner.executeTerminal(operation, payload: payload)
    }

    private func performLimitsLogin(_ operation: String, state: HerdrLimitsLoginState) async throws
        -> HerdrLimitsLoginState
    {
        try limitsLoginReply(
            await performData(
                "herdr.ui.accounts." + operation,
                payload: JSONSerialization.data(withJSONObject: [
                    "id": state.accountID.uuidString, "ticket": state.ticket.uuidString,
                ])), accountID: state.accountID, ticket: state.ticket)
    }

    private func limitsLoginReply(_ data: Data, accountID: UUID, ticket: UUID) throws
        -> HerdrLimitsLoginState
    {
        let reply = try JSONDecoder().decode(HerdrLimitsLoginState.self, from: data)
        guard reply.accountID == accountID, reply.ticket == ticket else {
            throw ExtensionPeerError.invalidRequest
        }
        return reply
    }

    nonisolated static func invalidateEnabledUsage() async {
        guard let endpoint = ExtensionPeerEndpoint.current(owner: "usage") else { return }
        _ = try? await endpoint.invoke(
            "usage.accounts.changed", payload: Data("{}".utf8), timeout: 5)
    }

    nonisolated static func refreshEnabledUsage() async {
        guard let endpoint = ExtensionPeerEndpoint.current(owner: "usage") else { return }
        _ = try? await endpoint.invoke(
            "usage.limits.project", payload: Data("{}".utf8), timeout: 5)
    }

    private func notifyLaunchSelection() async {
        guard client == nil else { return }
        let refresh = refreshUsage
        let task = Task.detached { await refresh() }
        await task.value
    }

    func notifyChanged() async {
        guard client == nil else { return }
        let invalidate = invalidateUsage
        let cleanup = Task.detached { await invalidate() }
        await cleanup.value
    }

    func cancelPendingWork() {
        subscriptionLogin.cancel()
        limitsLoginOwner.cancelPendingWork()
        for request in requests.values { request.cancel() }
    }
    func shutdown() {
        stopped = true
        limitsLoginOwner.stop()
        cancelPendingWork()
        requests.removeAll()
        ready = false
    }
}

struct ClaudeAccountsMutation: Codable {
    let baseline: ClaudeAccountsState
    let state: ClaudeAccountsState
}
