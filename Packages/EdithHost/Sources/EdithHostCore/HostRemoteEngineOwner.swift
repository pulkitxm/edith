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

    #if EDITH_FUNCTIONAL_FIXTURE
    init(
        marketplace: HostMarketplace, configuration: HostRemoteConfiguration,
        startingWorker: HostWorker, birth: ExtensionProcessIdentity
    ) throws {
        guard !configuration.uiOnly,
            try marketplace.sessions.fixtureStartingWorker(
                configuration: configuration.worker, birth: birth) === startingWorker,
            marketplace.installed[configuration.package.id] == configuration.package,
            !marketplace.pendingRemovalIDs.contains(configuration.package.id)
        else { throw HostWorkerError.rejected }
        self.marketplace = marketplace
        self.configuration = configuration
        process = try HostRemoteKernelIdentity.read(birth.pid)
        guard ExtensionProcessIdentity.read(birth.pid) == birth, process.isRunning else {
            throw HostWorkerError.rejected
        }
    }
    #endif

    func validate() throws {
        try validateIdentity()
        let id = configuration.package.id
        guard !marketplace.pendingRemovalIDs.contains(id),
            marketplace.sessions.activeIDs.contains(id)
        else { throw HostWorkerError.rejected }
    }

    private func validateIdentity() throws {
        let id = configuration.package.id
        guard !configuration.uiOnly,
            marketplace.installed[id] == configuration.package,
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
        if HostRemoteInvocationAdmission.current?.authorizes(request.token) == true {
            try validateIdentity()
        } else {
            try validate()
        }
        try Task.checkCancellation()
        let endpoint = try ExtensionPeerEndpoint(
            namespace: marketplace.identity.identifier, owner: configuration.package.id,
            directory: marketplace.identity.root.appendingPathComponent("ExtensionState/Commands"))
        let result = try await endpoint.invoke(
            request.operation, payload: request.payload, timeout: request.timeout,
            token: request.token)
        try Task.checkCancellation()
        try validateIdentity()
        guard pending.contains(request.token) else { throw HostWorkerError.rejected }
        guard result.count <= ExtensionEngineWire.maximumPayloadBytes,
            (try? JSONSerialization.jsonObject(with: result, options: .fragmentsAllowed)) != nil
        else { throw HostWorkerError.invalidResponse }
        return result
    }
}
