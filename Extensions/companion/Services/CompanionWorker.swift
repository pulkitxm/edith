import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor
final class CompanionWorker {
    static let commands: Set<String> = [
        "companion.status", "companion.health", "companion.search", "companion.episodes",
        "companion.index", "companion.stopGenerations",
    ]
    static let maximumQueryBytes = 4_096
    static let maximumResponseBytes = 1_048_576

    let monitor: CompanionMonitor
    let workspace: CompanionWorkspaceSession
    let transport: CompanionTransport
    private(set) var isStopped = false
    private let client: @MainActor () -> CompanionClient

    init(
        monitor: CompanionMonitor? = nil, transport: CompanionTransport = .shared,
        privacy: SurfacePrivacyState? = nil,
        client: @escaping @MainActor () -> CompanionClient = {
            CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
        }
    ) {
        self.monitor = monitor ?? CompanionMonitor()
        self.transport = transport
        self.client = client
        workspace = CompanionWorkspaceSession(
            privacy: privacy
                ?? ExtensionSharedState.current.map { SurfacePrivacyState(channel: $0) })
        transport.open()
        CompanionBackgroundOperation.monitor = self.monitor
    }

    func start() {
        guard !isStopped else { return }
        monitor.start()
    }

    func openEpisode(_ id: String?) {
        guard !isStopped else { return }
        if let id {
            SharedDefaults.store.set(
                CompanionTab.library.rawValue, forKey: AppStorageKeys.Companion.tab)
            let library = workspace.library
            Task { await library.select(id) }
        }
        ExtensionPresentation.showWindow()
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !isStopped else { throw ExtensionPeerError.unavailable }
        guard Self.commands.contains(command), payload.count <= 16_384 else {
            throw ExtensionPeerError.invalidRequest
        }
        let object = try Self.object(payload)
        let result: Data
        switch command {
        case "companion.status":
            let waiting = await Task.detached(priority: .utility) {
                CompanionOutbox.waiting().count
            }.value
            let deployment = CompanionDeploymentStore.load()
            result = try JSONSerialization.data(withJSONObject: [
                "configured": CompanionClient.hasConfiguredEndpointOrDeployment(),
                "endpoint": CompanionClient.endpoint(override: nil).absoluteString,
                "monitoring": monitor.isRunning,
                "deployed": deployment != nil,
                "remote": deployment?.machineID != nil,
                "outboxWaiting": waiting,
            ])
        case "companion.health":
            let refresh = object["refresh"] as? Bool ?? false
            let snapshot = refresh ? await monitor.refresh() : await monitor.current()
            result = try JSONEncoder().encode(snapshot)
        case "companion.search":
            guard let query = object["query"] as? String,
                !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                query.utf8.count <= Self.maximumQueryBytes, !query.utf8.contains(0)
            else { throw ExtensionPeerError.invalidRequest }
            let limit = min(max(object["limit"] as? Int ?? 10, 1), 50)
            result = try JSONEncoder().encode(try await client().search(query: query, k: limit))
        case "companion.episodes":
            let limit = min(max(object["limit"] as? Int ?? 20, 1), 200)
            result = try JSONEncoder().encode(try await client().episodes(limit: limit))
        case "companion.index":
            result = try JSONEncoder().encode(try await client().index())
        default:
            result = try JSONSerialization.data(withJSONObject: [
                "stopped": CompanionGeneration.stopAll()
            ])
        }
        try Task.checkCancellation()
        guard !isStopped else { throw ExtensionPeerError.unavailable }
        guard result.count <= Self.maximumResponseBytes else {
            throw ExtensionPeerError.rejected("The Memory response exceeded its size limit.")
        }
        return result
    }

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        workspace.shutdown()
        if CompanionBackgroundOperation.monitor === monitor {
            CompanionBackgroundOperation.monitor = nil
        }
        transport.close()
        await monitor.stop()
    }

    private static func object(_ payload: Data) throws -> [String: Any] {
        guard !payload.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        return object
    }
}
