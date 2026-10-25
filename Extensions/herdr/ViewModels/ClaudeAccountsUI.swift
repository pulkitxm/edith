import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation

struct ClaudeSharedLaunchState: Codable, Equatable {
    let arguments: String
    let environment: String
}

struct ClaudeSharedLaunchMutation: Codable {
    let baseline: ClaudeSharedLaunchState
    let state: ClaudeSharedLaunchState
}

@MainActor enum ClaudeAccountsUI {
    static func execute(_ command: String, payload: Data, worker: HerdrWorker) async throws -> Data
    {
        guard !worker.isStopped, payload.count <= 131_072,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        let model = worker.store.claudeAccounts
        if command == "herdr.ui.accounts.launchRead" || command == "herdr.ui.accounts.launchSave" {
            let defaults = worker.store.uiDefaults
            let current = ClaudeSharedLaunchState(
                arguments: HerdrLaunchSettings.sharedArguments(in: defaults),
                environment: HerdrLaunchSettings.sharedEnvironment(in: defaults))
            if command == "herdr.ui.accounts.launchSave" {
                guard Set(object.keys) == ["baseline", "state"] else {
                    throw ExtensionPeerError.invalidRequest
                }
                let change = try JSONDecoder().decode(
                    ClaudeSharedLaunchMutation.self, from: payload)
                guard change.baseline == current else {
                    throw ExtensionPeerError.rejected(
                        "Launch settings changed. Reload and try again.")
                }
                try Task.checkCancellation()
                try HerdrLaunchSettings.setSharedClaudeLaunch(
                    arguments: change.state.arguments, environment: change.state.environment,
                    in: defaults)
                return try JSONEncoder().encode(change.state)
            }
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(current)
        }
        if command == "herdr.ui.accounts.limitsStatus"
            || command == "herdr.ui.accounts.limitsCancel"
        {
            guard payload.count <= 256, Set(object.keys) == ["id", "ticket"],
                let raw = object["id"] as? String, let id = UUID(uuidString: raw),
                let token = object["ticket"] as? String, let ticket = UUID(uuidString: token)
            else { throw ExtensionPeerError.invalidRequest }
            let state =
                command == "herdr.ui.accounts.limitsCancel"
                ? try model.limitsLoginOwner.requestCancellation(accountID: id, ticket: ticket)
                : try model.limitsLoginOwner.status(accountID: id, ticket: ticket)
            return try JSONEncoder().encode(state)
        }
        if command == "herdr.ui.accounts.select" {
            guard payload.count <= 128, Set(object.keys) == ["id"],
                let raw = object["id"] as? String, UUID(uuidString: raw) != nil
            else { throw ExtensionPeerError.invalidRequest }
        }
        if command == "herdr.ui.accounts.limitsStart" {
            guard !model.saving else {
                throw ExtensionPeerError.rejected("An account change is already in progress.")
            }
            guard payload.count <= 256, Set(object.keys) == ["id", "ticket"],
                let raw = object["id"] as? String, let id = UUID(uuidString: raw),
                let token = object["ticket"] as? String, let ticket = UUID(uuidString: token)
            else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(
                await model.startCanonicalLimitsLogin(
                    id, ticket: ticket, defaults: worker.store.uiDefaults))
        }
        guard !model.saving else {
            throw ExtensionPeerError.rejected("An account change is already in progress.")
        }
        try await model.load()
        guard !model.saving else {
            throw ExtensionPeerError.rejected("An account change is already in progress.")
        }
        switch command {
        case "herdr.ui.accounts.read":
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
        case "herdr.ui.accounts.save":
            guard Set(object.keys) == ["baseline", "state"] else {
                throw ExtensionPeerError.invalidRequest
            }
            let change = try JSONDecoder().decode(ClaudeAccountsMutation.self, from: payload)
            guard change.baseline == model.state else {
                throw ExtensionPeerError.rejected("Accounts changed. Reload and try again.")
            }
            await model.save(change.state)
        case "herdr.ui.accounts.select":
            guard let raw = object["id"] as? String,
                await model.rememberLaunchSelection(raw)
            else {
                throw ExtensionPeerError.rejected(
                    model.error ?? "This account could not be selected. Reload and try again.")
            }
        case "herdr.ui.accounts.import":
            guard Set(object.keys).isSubset(of: ["machineID"]) else {
                throw ExtensionPeerError.invalidRequest
            }
            let machine: Machine?
            if let value = object["machineID"] {
                guard let id = value as? String,
                    let host = worker.store.hosts.first(where: {
                        !$0.isLocal && $0.id == id && $0.reachable
                    }),
                    let selected = worker.store.machine(for: host)
                else { throw ExtensionPeerError.invalidRequest }
                machine = selected
            } else {
                machine = nil
            }
            _ = await model.importCurrentCLIAccount(on: machine)
        case "herdr.ui.accounts.forget", "herdr.ui.accounts.logout":
            guard Set(object.keys) == ["id"], let raw = object["id"] as? String,
                let id = UUID(uuidString: raw), model.account(id) != nil
            else { throw ExtensionPeerError.invalidRequest }
            if command == "herdr.ui.accounts.forget" {
                await model.forget(id)
            } else {
                await model.logout(id)
            }
        default: throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        if let error = model.error { throw ExtensionPeerError.rejected(error) }
        let data = try JSONEncoder().encode(model.state)
        guard data.count <= 65_536 else { throw ExtensionPeerError.invalidRequest }
        return data
    }
}
