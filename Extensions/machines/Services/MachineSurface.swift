import EdithExtensionSupport
import Foundation

public struct MachineSurfaceItem: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let detail: String
    public let connected: Bool
    public init(id: UUID, name: String, detail: String, connected: Bool) {
        self.id = id; self.name = name; self.detail = detail; self.connected = connected
    }
}

@MainActor public final class MachineSurface {
    private let items: @MainActor () -> [MachineSurfaceItem]
    private let open: @MainActor (UUID) -> Void
    private let stopped: @MainActor () -> Bool
    private let privacy: @MainActor () -> [String: String]
    private let health: @MainActor () async -> MachineHealthSnapshot?
    private var actions: [UUID: UUID] = [:]

    public init(
        items: @escaping @MainActor () -> [MachineSurfaceItem],
        open: @escaping @MainActor (UUID) -> Void,
        stopped: @escaping @MainActor () -> Bool,
        privacy: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        },
        health: @escaping @MainActor () async -> MachineHealthSnapshot? = { nil }
    ) {
        self.items = items; self.open = open; self.stopped = stopped; self.privacy = privacy
        self.health = health
    }

    public func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped() else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "machines", command: command,
            payload: payload, snapshot: { try await self.snapshot($0) },
            perform: { try self.perform($0) },
            privacyValues: privacy)
    }

    private func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        guard !stopped() else { throw ExtensionPeerError.unavailable }
        let report = await health()
        try Task.checkCancellation()
        guard !stopped() else { throw ExtensionPeerError.unavailable }
        let monitored = report.map { !$0.skipped } ?? false
        let reachable = Dictionary(
            (report?.machines ?? []).map { ($0.id, $0.reachable) }, uniquingKeysWith: { $1 })
        let all = items()
        guard all.count <= 1_025, Set(all.map(\.id)).count == all.count else {
            throw ExtensionPeerError.invalidRequest
        }
        actions = actions.filter { key, _ in all.contains { $0.id == key } }
        for item in all where actions[item.id] == nil { actions[item.id] = UUID() }
        let selected = all.filter { tile.sourceIDs?.contains($0.id.uuidString) ?? true }
        let field = tile.widget == .desk ? "machines" : nil
        let rows = selected.prefix(tile.itemLimit).map { item in
            SurfaceDataRow(
                item.id.uuidString, sourceID: item.id.uuidString,
                title: String(item.name.prefix(128)), detail: String(item.detail.prefix(256)),
                value: monitored
                    ? (reachable[item.id.uuidString] == true ? "Online" : "Offline") : "Unknown",
                icon: "desktopcomputer",
                field: field,
                actions: [
                    .init(
                        actions[item.id]!.uuidString, "Open fleet", "arrow.up.right", field: field)
                ])
        }
        var metrics: [SurfaceMetric] = [.init("total", "Registered", "\(selected.count)")]
        if monitored {
            let online = selected.filter { reachable[$0.id.uuidString] == true }.count
            metrics.insert(
                contentsOf: [
                    .init("online", "Reachable", "\(online)"),
                    .init("offline", "Unreachable", "\(selected.count - online)"),
                ], at: 0)
        } else {
            metrics.insert(.init("status", "Health monitoring", "Off"), at: 0)
        }
        return SurfaceSnapshot(
            providerID: "machines",
            metrics: metrics, rows: rows,
            sources: all.map { .init($0.id.uuidString, String($0.name.prefix(128))) },
            message: monitored
                ? (selected.isEmpty ? "No machines in this selection." : nil)
                : "Reachability monitoring is off.",
            updatedAt: report?.checkedAt ?? Date())
    }

    private func perform(_ action: String) throws {
        guard !stopped(), let token = UUID(uuidString: action),
            let id = actions.first(where: { $0.value == token })?.key,
            items().contains(where: { $0.id == id })
        else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        open(id)
    }
}
