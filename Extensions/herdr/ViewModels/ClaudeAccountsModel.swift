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
    private var requests: [UUID: Task<Data, Error>] = [:]
    private var stopped = false
    private let eraseSecret: @Sendable (URL) throws -> Void
    private let invalidateUsage: @Sendable () async -> Void

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
        eraseSecret: @escaping @Sendable (URL) throws -> Void = ClaudeAccountImport
            .eraseScopedSecret,
        invalidateUsage: @escaping @Sendable () async -> Void = ClaudeAccountsModel
            .invalidateEnabledUsage
    ) {
        suppliedDirectory = directory
        self.client = client
        self.eraseSecret = eraseSecret
        self.invalidateUsage = invalidateUsage
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
            next = try await ownedStorage().load()
        }
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try next.validate()
        state = next
        ready = true
        error = nil
    }

    func save(_ next: ClaudeAccountsState) async {
        guard ready, !saving, !stopped else { return }
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

    nonisolated static func invalidateEnabledUsage() async {
        guard let endpoint = ExtensionPeerEndpoint.current(owner: "usage") else { return }
        _ = try? await endpoint.invoke(
            "usage.accounts.changed", payload: Data("{}".utf8), timeout: 5)
    }

    func notifyChanged() async {
        guard client == nil else { return }
        let invalidate = invalidateUsage
        let cleanup = Task.detached { await invalidate() }
        await cleanup.value
    }

    func cancelPendingWork() { for request in requests.values { request.cancel() } }
    func shutdown() { stopped = true; cancelPendingWork(); requests.removeAll(); ready = false }
}

struct ClaudeAccountsMutation: Codable {
    let baseline: ClaudeAccountsState
    let state: ClaudeAccountsState
}
