import DatabaseCore
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class DatabaseSurface {
    private let session: DatabasePageSession
    private let privacyValues: @MainActor () -> [String: String]
    private let sender: any DatabaseBrokerCommandSending
    private var stopped = false

    init(
        session: DatabasePageSession,
        sender: any DatabaseBrokerCommandSending = DatabaseWorkerClient(),
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.session = session
        self.sender = sender
        self.privacyValues = privacyValues
    }

    func shutdown() { stopped = true }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "database", command: command, payload: payload,
            snapshot: { try await self.snapshot($0) },
            perform: { try await self.perform($0) }, privacyValues: privacyValues)
    }

    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        let all = try await connections()
        let selected = all.filter { tile.sourceIDs?.contains($0.id.rawValue.uuidString) ?? true }
        let rows = selected.prefix(tile.itemLimit).map { connection in
            let id = connection.id.rawValue.uuidString
            return SurfaceDataRow(
                id, sourceID: id, title: String(connection.displayName.prefix(256)),
                detail: connection.productHint.displayName, value: connection.isFavorite ? "Favorite" : "Saved",
                icon: "externaldrive", actions: [.init("open/" + id, "Open", "macwindow")])
        }
        return SurfaceSnapshot(
            providerID: "database", metrics: [.init("connections", "Connections", "\(selected.count)")],
            rows: Array(rows), sources: all.map {
                .init($0.id.rawValue.uuidString, String($0.displayName.prefix(256)))
            }, message: selected.isEmpty ? "No saved connections" : nil, updatedAt: Date())
    }

    private func connections() async throws -> [DatabaseConnectionDefinition] {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let response = try await sender.send(.connectionList(.init()))
        try Task.checkCancellation()
        guard !stopped, case .connectionList(let result) = response, let payload = result.payload else {
            throw ExtensionPeerError.unavailable
        }
        return Array(payload.connections.prefix(1_024))
    }

    private func perform(_ action: String) async throws {
        let parts = action.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, parts[0] == "open", let id = UUID(uuidString: String(parts[1])),
            try await connections().contains(where: { $0.id.rawValue == id })
        else { throw ExtensionPeerError.invalidRequest }
        await session.connections.loadConnections()
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        session.connections.selectConnection(.init(rawValue: id))
        ExtensionPresentation.showWindow()
    }
}
