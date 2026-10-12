import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class QuinjetSurface {
    private let worker: QuinjetWorker
    private let privacyValues: @MainActor () -> [String: String]
    private var actions: [UUID: UUID] = [:]
    init(
        worker: QuinjetWorker,
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
            providerID: "quinjet", command: command, payload: payload,
            snapshot: { try self.snapshot($0) }, perform: { try await self.perform($0) },
            privacyValues: privacyValues)
    }
    func snapshot(_ tile: SurfaceTile) throws -> SurfaceSnapshot {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        let tabs = Array(worker.model.tabs.prefix(32))
        let current = Set(tabs.map(\.id))
        actions = actions.filter { current.contains($0.key) }
        let visible = tabs.filter {
            tile.sourceIDs?.contains($0.remote?.machineID.uuidString ?? "local") ?? true
        }
        let rows = visible.prefix(tile.itemLimit).map { tab in
            let token = actions[tab.id] ?? UUID()
            actions[tab.id] = token
            return SurfaceDataRow(
                tab.id.uuidString, sourceID: tab.remote?.machineID.uuidString ?? "local",
                title: bounded(tab.title, 512),
                detail: bounded(tab.remote?.machineName ?? "This Mac", 256),
                value: tab.holder.started ? "Running" : "Ready",
                icon: "point.topleft.down.to.point.bottomright.curvepath",
                actions: [.init(token.uuidString, "Open", "macwindow")])
        }
        let sources = Dictionary(
            tabs.map {
                ($0.remote?.machineID.uuidString ?? "local", $0.remote?.machineName ?? "This Mac")
            }, uniquingKeysWith: { first, _ in first })
        return SurfaceSnapshot(
            providerID: "quinjet", metrics: [.init("sessions", "Reviews", String(visible.count))],
            rows: Array(rows), actions: [.init("open", "Open Quinjet", "macwindow")],
            sources: sources.sorted { $0.key < $1.key }.map {
                .init($0.key, bounded($0.value, 256))
            }, updatedAt: Date())
    }
    private func perform(_ action: String) async throws {
        if action == "open" { ExtensionPresentation.showWindow(); return }
        guard let tab = actions.first(where: { $0.value.uuidString == action })?.key,
            worker.model.tabs.contains(where: { $0.id == tab })
        else { throw ExtensionPeerError.invalidRequest }
        _ = try await worker.execute(
            "quinjet.session.focus",
            payload: JSONSerialization.data(withJSONObject: ["sessionID": tab.uuidString]))
        ExtensionPresentation.showWindow()
    }
    private func bounded(_ text: String, _ limit: Int) -> String {
        var result = ""
        var count = 0
        for character in text where character != "\0" {
            let size = String(character).utf8.count
            guard count + size <= limit else { break }
            result.append(character)
            count += size
        }
        return result
    }
}
