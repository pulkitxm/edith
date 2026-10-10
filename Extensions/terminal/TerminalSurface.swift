import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class TerminalSurface {
    private let engine: TerminalEngine
    private let privacyValues: @MainActor () -> [String: String]
    private let home: String
    private let showWindow: @MainActor () -> Void

    init(
        engine: TerminalEngine,
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        },
        home: String = NSHomeDirectory(),
        showWindow: @escaping @MainActor () -> Void = { ExtensionPresentation.showWindow() }
    ) {
        self.engine = engine
        self.privacyValues = privacyValues
        self.home = home
        self.showWindow = showWindow
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !engine.isStopped else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "terminal", command: command, payload: payload,
            snapshot: { try self.snapshot($0) }, perform: { try await self.perform($0) },
            privacyValues: privacyValues)
    }

    func snapshot(_ tile: SurfaceTile) throws -> SurfaceSnapshot {
        guard !engine.isStopped else { throw ExtensionPeerError.unavailable }
        let allTabs = try engine.snapshot().sessions
        let tabs = allTabs.filter { tile.sourceIDs?.contains($0.id.uuidString) ?? true }
        let rows = tabs.prefix(tile.itemLimit).map { tab in
            SurfaceDataRow(
                tab.id.uuidString, sourceID: tab.id.uuidString,
                title: TerminalWorker.bounded(tab.title, bytes: 512),
                detail: TerminalWorker.bounded(
                    abbreviated(tab.directory), bytes: 1_024),
                value: tab.running ? "Running" : "Ended", icon: "terminal",
                actions: [.init("focus/" + tab.id.uuidString, "Show", "macwindow")])
        }
        return SurfaceSnapshot(
            providerID: "terminal",
            metrics: [
                .init("sessions", "Sessions", "\(tabs.count)"),
                .init("running", "Running", "\(tabs.filter(\.running).count)"),
            ],
            rows: Array(rows),
            actions: [.init("new", "New terminal", "plus")],
            sources: allTabs.map {
                .init($0.id.uuidString, TerminalWorker.bounded($0.title, bytes: 512))
            },
            message: tabs.isEmpty ? "No terminals open" : nil, updatedAt: Date())
    }

    private func abbreviated(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func perform(_ actionID: String) async throws {
        guard !engine.isStopped else { throw ExtensionPeerError.unavailable }
        if actionID == "new" {
            _ = try await engine.execute("terminal.open", payload: Data())
            showWindow()
            return
        }
        let parts = actionID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "focus", let id = UUID(uuidString: parts[1]),
            let session = try engine.snapshot().sessions.first(where: { $0.id == id })
        else { throw ExtensionPeerError.invalidRequest }
        _ = try await engine.execute(
            "terminal.select",
            payload: JSONEncoder().encode(
                TerminalEngine.SessionRequest(id: session.id, generation: session.generation)))
        showWindow()
    }
}
