import EdithExtensionSupport
import Foundation

@MainActor final class TerminalSurface {
    private let worker: TerminalWorker
    private let privacyValues: @MainActor () -> [String: String]
    private let home: String

    init(
        worker: TerminalWorker,
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        },
        home: String = NSHomeDirectory()
    ) {
        self.worker = worker
        self.privacyValues = privacyValues
        self.home = home
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "terminal", command: command, payload: payload,
            snapshot: { try self.snapshot($0) }, perform: { try self.perform($0) },
            privacyValues: privacyValues)
    }

    func snapshot(_ tile: SurfaceTile) throws -> SurfaceSnapshot {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        let allTabs = worker.model.tabs
        let tabs = allTabs.filter { tile.sourceIDs?.contains($0.id.uuidString) ?? true }
        let rows = tabs.prefix(tile.itemLimit).map { tab in
            SurfaceDataRow(
                tab.id.uuidString, sourceID: tab.id.uuidString,
                title: TerminalWorker.bounded(tab.displayTitle, bytes: 512),
                detail: TerminalWorker.bounded(
                    abbreviated(tab.holder.currentWorkingDirectory), bytes: 1_024),
                value: tab.holder.started ? "Running" : "Ended", icon: "terminal",
                actions: [.init("focus/" + tab.id.uuidString, "Show", "macwindow")])
        }
        return SurfaceSnapshot(
            providerID: "terminal",
            metrics: [
                .init("sessions", "Sessions", "\(tabs.count)"),
                .init("running", "Running", "\(tabs.filter(\.holder.started).count)"),
            ],
            rows: Array(rows),
            actions: [.init("new", "New terminal", "plus")],
            sources: allTabs.map {
                .init($0.id.uuidString, TerminalWorker.bounded($0.displayTitle, bytes: 512))
            },
            message: tabs.isEmpty ? "No terminals open" : nil, updatedAt: Date())
    }

    private func abbreviated(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func perform(_ actionID: String) throws {
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        if actionID == "new" {
            guard worker.openTab() != nil else { throw ExtensionPeerError.invalidRequest }
            return
        }
        let parts = actionID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "focus", let id = UUID(uuidString: parts[1]),
            worker.model.tabs.contains(where: { $0.id == id })
        else { throw ExtensionPeerError.invalidRequest }
        worker.focus(id)
    }
}
