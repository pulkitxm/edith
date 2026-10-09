import EdithExtensionUI
import EdithExtensionSupport
import Foundation

@MainActor final class HerdrSurface {
    private let worker: HerdrWorker
    private let privacyValues: @MainActor () -> [String: String]
    private var actions: [String: UUID] = [:]
    init(
        worker: HerdrWorker,
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.worker = worker
        self.privacyValues = privacyValues
    }
    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "herdr", command: command, payload: payload,
            snapshot: { try self.snapshot($0) }, perform: { try await self.perform($0) },
            privacyValues: privacyValues)
    }
    func snapshot(_ tile: SurfaceTile) throws -> SurfaceSnapshot {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        let all = Array(worker.store.hosts.prefix(64))
        let hosts = all.filter { tile.sourceIDs?.contains($0.id) ?? true }
        let agents = hosts.flatMap(\.agents)
        let activeIDs = Set(all.flatMap(\.agents).map(\.id))
        actions = actions.filter { activeIDs.contains($0.key) }
        let rows = agents.prefix(tile.itemLimit).map { agent in
            let token = actions[agent.id] ?? UUID()
            actions[agent.id] = token
            return SurfaceDataRow(
                token.uuidString, sourceID: agent.machineID,
                title: HerdrWorker.bounded(agent.title, 512),
                detail: HerdrWorker.bounded(agent.machineName + " · " + agent.workspace, 1_024),
                value: agent.status.title, icon: "rectangle.3.group",
                actions: [.init(token.uuidString, "Open", "macwindow")])
        }
        return SurfaceSnapshot(
            providerID: "herdr",
            metrics: [
                .init("agents", "Agents", "\(agents.filter { !$0.isTerminal }.count)"),
                .init("working", "Working", "\(agents.filter { $0.status == .working }.count)"),
                .init("blocked", "Blocked", "\(agents.filter { $0.status == .blocked }.count)"),
            ], rows: Array(rows), actions: [.init("open", "Open Herdr", "macwindow")],
            sources: all.prefix(64).map { .init($0.id, HerdrWorker.bounded($0.name, 256)) },
            message: agents.isEmpty ? "No live Herdr agents" : nil, updatedAt: Date())
    }
    private func perform(_ action: String) async throws {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        if action == "open" {
            ExtensionPresentation.showWindow()
            return
        }
        guard let id = actions.first(where: { $0.value.uuidString == action })?.key,
            worker.currentAgent(id) != nil
        else { throw ExtensionPeerError.invalidRequest }
        _ = try await worker.execute(
            "herdr.open", payload: JSONSerialization.data(withJSONObject: ["agentID": id]))
    }
}
