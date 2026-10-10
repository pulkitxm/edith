import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

@MainActor
final class HostRemoteEngineOwner {
    let process: HostRemoteKernelIdentity
    private let marketplace: HostMarketplace
    private let configuration: HostRemoteConfiguration
    private var pending = Set<UUID>()

    init(marketplace: HostMarketplace, configuration: HostRemoteConfiguration) throws {
        guard !configuration.uiOnly,
            let pid = marketplace.sessions.processIdentifiers[configuration.package.id]
        else { throw HostWorkerError.rejected }
        self.marketplace = marketplace
        self.configuration = configuration
        process = try HostRemoteKernelIdentity.read(pid)
        try validate()
    }

    func validate() throws {
        let id = configuration.package.id
        guard !configuration.uiOnly,
            marketplace.installed[id] == configuration.package,
            !marketplace.pendingRemovalIDs.contains(id),
            marketplace.sessions.activeIDs.contains(id),
            marketplace.sessions.versions[id] == configuration.package.version,
            marketplace.sessions.processIdentifiers[id] == process.pid,
            process.isRunning
        else { throw HostWorkerError.rejected }
    }

    func invoke(_ request: ExtensionEngineRequest) async throws -> Data {
        try request.validate()
        guard pending.count < 8, !pending.contains(request.token) else {
            throw HostWorkerError.rejected
        }
        pending.insert(request.token)
        defer { pending.remove(request.token) }
        try validate()
        try Task.checkCancellation()
        let endpoint = try ExtensionPeerEndpoint(
            namespace: marketplace.identity.identifier, owner: configuration.package.id,
            directory: marketplace.identity.root.appendingPathComponent("ExtensionState/Commands"))
        let result = try await endpoint.invoke(
            request.operation, payload: request.payload, timeout: request.timeout)
        try Task.checkCancellation()
        try validate()
        guard result.count <= ExtensionEngineWire.maximumPayloadBytes,
            (try? JSONSerialization.jsonObject(with: result, options: .fragmentsAllowed)) != nil
        else { throw HostWorkerError.invalidResponse }
        return result
    }
}
