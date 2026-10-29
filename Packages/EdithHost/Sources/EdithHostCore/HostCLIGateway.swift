import Darwin
import EdithExtensionSupport
import Foundation

@MainActor public final class HostCLIGateway {
    private let marketplace: HostMarketplace
    public init(marketplace: HostMarketplace) { self.marketplace = marketplace }

    public func execute(_ request: HostCLIRequest) async throws -> Data {
        try request.validate()
        try Task.checkCancellation()
        if request.action == .ls {
            return try JSONSerialization.data(
                withJSONObject: marketplace.entries.map { info($0.id) },
                options: .sortedKeys)
        }
        if request.action == .updateAll { return try await updateAll() }
        guard let id = request.id, marketplace.entries.contains(where: { $0.id == id }) else {
            throw HostCLIError.rejected("Unknown extension identifier.")
        }
        if request.action == .info { return try encodedInfo(id) }
        if request.action == .invoke || request.action == .terminal {
            return try await invoke(request, id: id)
        }
        guard !marketplace.isBusy(id) else {
            throw HostCLIError.rejected(
                "Another operation is running for this extension. Try again when it finishes.")
        }
        var failure: String?
        switch request.action {
        case .install:
            if !marketplace.downloadedIDs.contains(id) {
                failure = await marketplace.download(id: id)
            }
            if failure == nil, marketplace.installed[id] != nil,
                marketplace.sessions.states[id] != .active
            {
                failure = await marketplace.enable(id: id)
            }
        case .update:
            guard marketplace.downloadedIDs.contains(id) else {
                throw HostCLIError.rejected("Install the extension before updating it.")
            }
            failure = await marketplace.download(id: id)
        case .enable:
            guard marketplace.installed[id] != nil else {
                throw HostCLIError.rejected("Install a compatible extension before enabling it.")
            }
            failure = await marketplace.enable(id: id)
        case .disable: failure = await marketplace.disable(id: id)
        case .remove: failure = await marketplace.remove(id: id)
        default: throw HostCLIError.usage("Invalid marketplace action.")
        }
        try Task.checkCancellation()
        if let message = failure { throw HostCLIError.rejected(message) }
        return try encodedInfo(id)
    }

    private func updateAll() async throws -> Data {
        await marketplace.checkForUpdates()
        let candidates = marketplace.updatableIDs
        let failed = await marketplace.updateAll()
        try Task.checkCancellation()
        let updated = candidates.filter {
            failed[$0] == nil && !marketplace.updateAvailable(id: $0)
        }
        let skipped = Set(candidates).subtracting(updated).subtracting(failed.keys)
        var failures = failed
        for id in skipped { failures[id] = "Another operation is running for this extension." }
        return try JSONSerialization.data(
            withJSONObject: [
                "updated": updated, "failed": failures,
                "upToDate": marketplace.downloadedIDs.subtracting(candidates).sorted(),
            ], options: .sortedKeys)
    }

    private func invoke(_ request: HostCLIRequest, id: String) async throws -> Data {
        guard let package = marketplace.installed[id],
            marketplace.sessions.activeIDs.contains(id),
            marketplace.sessions.versions[id] == package.version,
            let pid = marketplace.sessions.processIdentifiers[id], kill(pid, 0) == 0,
            let generation = marketplace.sessions.workerGenerations[id],
            let operation = request.operation
        else {
            if request.action == .terminal {
                let title = marketplace.entries.first { $0.id == id }?.title ?? id
                return try JSONEncoder().encode(
                    ExtensionCLIReply(
                        stdout: "",
                        stderr:
                            "error: the \(title) extension is off\nhint: run `ed extensions enable \(id)`\n",
                        exitCode: 4))
            }
            throw HostCLIError.rejected(
                "Install and enable a compatible extension before invoking it.")
        }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: marketplace.identity.identifier, owner: id,
            directory: marketplace.identity.root.appendingPathComponent("ExtensionState/Commands"))
        let result: Data
        do {
            result = try await endpoint.invoke(
                operation, payload: request.payload, timeout: request.timeout)
        } catch ExtensionPeerError.timedOut { throw HostCLIError.timedOut }
        try Task.checkCancellation()
        guard marketplace.sessions.activeIDs.contains(id),
            marketplace.sessions.processIdentifiers[id] == pid,
            marketplace.sessions.workerGenerations[id] == generation,
            marketplace.sessions.versions[id] == package.version,
            marketplace.installed[id]?.version == package.version,
            result.count <= ExtensionPeerEndpoint.maximumPayloadBytes,
            (try? JSONSerialization.jsonObject(with: result, options: .fragmentsAllowed)) != nil
        else {
            throw HostCLIError.rejected(
                "The worker changed during the command or returned invalid JSON.")
        }
        return result
    }

    private func encodedInfo(_ id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: info(id), options: .sortedKeys)
    }

    private func state(_ id: String) -> HostActivationState {
        let live = marketplace.sessions.states[id]
        if marketplace.downloadedIDs.contains(id) { return live ?? .disabled }
        switch live {
        case .starting, .active, .stopping, .failed: return live ?? .notInstalled
        default: return .notInstalled
        }
    }

    private func info(_ id: String) -> [String: Any] {
        let entry = marketplace.entries.first { $0.id == id }
        return [
            "id": id, "title": entry?.title ?? id,
            "installed": marketplace.installedVersions[id] != nil,
            "removalPending": marketplace.pendingRemovalIDs.contains(id),
            "disablePending": marketplace.sessions.pendingDisableIDs.contains(id),
            "compatible": marketplace.installed[id] != nil || marketplace.available[id] != nil,
            "enabled": marketplace.sessions.enabledIDs.contains(id),
            "running": marketplace.sessions.activeIDs.contains(id),
            "processIdentifier": marketplace.sessions.processIdentifiers[id] as Any? ?? NSNull(),
            "state": state(id).rawValue,
            "version": marketplace.installed[id]?.version as Any? ?? NSNull(),
            "availableVersion": marketplace.available[id]?.version as Any? ?? NSNull(),
            "updateAvailable": marketplace.updateAvailable(id: id), "offline": marketplace.offline,
        ]
    }
}
