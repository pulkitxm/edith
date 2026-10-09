import EdithExtensionSupport
import Foundation

@MainActor final class PluginsSurface {
    private let model: SkillsModel
    private let hidden: @MainActor () -> Bool

    init(
        model: SkillsModel,
        hidden: @escaping @MainActor () -> Bool = {
            let values = ExtensionSharedState.current?.values(for: "presenter") ?? [:]
            return values["active"] == "1" && values["blurShelf"] != "0"
        }
    ) { self.model = model; self.hidden = hidden }

    func execute(_ command: String, payload: Data) async throws -> Data {
        let request: SurfaceSnapshotRequest
        switch command {
        case "surface.snapshot":
            request = try SurfaceSnapshotRequest.decode(payload, providerID: "plugins")
        case "surface.perform":
            let action = try SurfaceActionRequest.decode(payload, providerID: "plugins")
            guard action.actionID == "refreshAgents", action.value == nil,
                action.snapshot.tile.showActions
            else { throw ExtensionPeerError.invalidRequest }
            request = action.snapshot
        default: throw ExtensionPeerError.invalidRequest
        }
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        if hidden() { return try snapshot(request.tile).encoded() }
        await model.discoverAgents()
        try Task.checkCancellation()
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        return try snapshot(request.tile).encoded()
    }

    func snapshot(_ tile: SurfaceTile) -> SurfaceSnapshot {
        if hidden() { return .init(providerID: "plugins", message: "Hidden while presenting") }
        let skills = model.skills.filter { tile.sourceIDs?.contains($0.id) ?? true }
        return .init(
            providerID: "plugins",
            metrics: [
                .init("agents", "Agents", "\(model.agents.count)"),
                .init("skills", "Skills", "\(skills.count)"),
            ],
            rows: skills.prefix(tile.itemLimit).map { skill in
                .init(
                    skill.id, title: skill.name,
                    detail: tile.showDetails ? skill.summary : "",
                    value: model.installedAgents[skill.id]?.isEmpty == false
                        ? "Installed" : "Available",
                    icon: skill.symbol)
            },
            actions: tile.showActions
                ? [.init("refreshAgents", "Refresh agents", "arrow.clockwise")] : [],
            sources: model.skills.map { .init($0.id, $0.name) },
            message: model.isInstalling ? "Installing selected plugin" : nil,
            updatedAt: Date())
    }
}
