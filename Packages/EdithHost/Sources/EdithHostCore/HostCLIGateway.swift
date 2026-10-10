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
        guard let id = request.id, marketplace.entries.contains(where: { $0.id == id }) else {
            throw HostCLIError.rejected("Unknown extension identifier.")
        }
        if request.action == .info { return try encodedInfo(id) }
        if request.action == .invoke { return try await invoke(request, id: id) }
        guard marketplace.operationID == nil else {
            throw HostCLIError.rejected(
                "Another marketplace operation is running. Try again when it finishes.")
        }
        switch request.action {
        case .install:
            guard !marketplace.downloadedIDs.contains(id) else {
                throw HostCLIError.rejected(
                    "The extension is already installed. Use extensions update.")
            }
            await marketplace.download(id: id)
        case .update:
            guard marketplace.downloadedIDs.contains(id) else {
                throw HostCLIError.rejected("Install the extension before updating it.")
            }
            await marketplace.download(id: id)
        case .enable:
            guard marketplace.installed[id] != nil else {
                throw HostCLIError.rejected("Install a compatible extension before enabling it.")
            }
            await marketplace.enable(id: id)
        case .disable: await marketplace.disable(id: id)
        case .remove: await marketplace.remove(id: id)
        default: throw HostCLIError.usage("Invalid marketplace action.")
        }
        try Task.checkCancellation()
        if let message = marketplace.error { throw HostCLIError.rejected(message) }
        return try encodedInfo(id)
    }

    private func invoke(_ request: HostCLIRequest, id: String) async throws -> Data {
        guard let package = marketplace.installed[id],
            marketplace.sessions.activeIDs.contains(id),
            marketplace.sessions.versions[id] == package.version,
            let pid = marketplace.sessions.processIdentifiers[id], kill(pid, 0) == 0,
            let operation = request.operation
        else {
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

    private func info(_ id: String) -> [String: Any] {
        let entry = marketplace.entries.first { $0.id == id }
        return [
            "id": id, "title": entry?.title ?? id,
            "installed": marketplace.installedVersions[id] != nil,
            "removalPending": marketplace.pendingRemovalIDs.contains(id),
            "disablePending": marketplace.sessions.pendingDisableIDs.contains(id),
            "compatible": marketplace.installed[id] != nil,
            "enabled": marketplace.sessions.enabledIDs.contains(id),
            "running": marketplace.sessions.activeIDs.contains(id),
            "state": marketplace.sessions.states[id]?.rawValue ?? "notInstalled",
            "version": marketplace.installed[id]?.version as Any? ?? NSNull(),
            "availableVersion": marketplace.available[id]?.version as Any? ?? NSNull(),
            "updateAvailable": marketplace.updateAvailable(id: id), "offline": marketplace.offline,
        ]
    }
}
