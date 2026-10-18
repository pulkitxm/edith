import EdithExtensionSupport
import Foundation
import Testing
@testable import PluginsExtension

@Suite @MainActor struct PluginsSurfaceTests {
    @Test func snapshotsFilterSkillsWithoutDownloadingOrInstalling() async throws {
        let suite = "plugins.surface.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let agents = [
            SkillAgent("first", "First", "/synthetic/first", []),
            SkillAgent("second", "Second", "/synthetic/second", []),
        ]
        let model = SkillsModel(defaults: defaults, detectAgents: { agents })
        defer { Task { await model.shutdown() } }
        let surface = PluginsSurface(model: model)
        var tile = SurfaceTile(.ability("plugins"))
        tile.itemLimit = 1
        tile.showDetails = false
        tile.showActions = false
        let data = try await surface.execute(
            "surface.snapshot",
            payload: SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
                providerID: "plugins"))
        let result = try SurfaceSnapshot.decode(data, providerID: "plugins")
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.id == "first" && result.rows.first?.icon == "terminal")
        #expect(result.metrics.map(\.title) == ["Detected agents", "Available skills"])
        #expect(result.metrics.map(\.value) == ["2", "\(model.skills.count)"])
        #expect(result.actions.isEmpty)
        #expect(result.sources.isEmpty && result.message == nil)
        #expect(model.documents.cachedDocument(for: model.skills[0]) == nil)
        #expect(model.installedAgents.isEmpty)
        #expect(!model.isInstalling)
        await model.shutdown()
    }

    @Test func actionsRejectInstallationAndHiddenControls() async throws {
        let model = SkillsModel(detectAgents: { [] })
        let surface = PluginsSurface(model: model)
        var tile = SurfaceTile(.ability("plugins"))
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let invalid = SurfaceActionRequest(snapshot: request, actionID: "install:arbitrary")
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform", payload: invalid.encoded(providerID: "plugins"))
        }
        tile.showActions = false
        let hidden = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: tile), actionID: "refreshAgents")
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform", payload: hidden.encoded(providerID: "plugins"))
        }
        await model.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "plugins"))
        }
    }
    @Test func presentingMasksAgentStateBeforeDiscoveryAndEncoding() async throws {
        let model = SkillsModel(detectAgents: { [] })
        let surface = PluginsSurface(model: model, hidden: { true })
        let request = SurfaceSnapshotRequest(target: .notch, tile: SurfaceTile(.ability("plugins")))
        let result = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "plugins")),
            providerID: "plugins")
        #expect(result.rows.isEmpty)
        #expect(result.sources.isEmpty)
        #expect(result.metrics.isEmpty)
        #expect(result.actions.isEmpty)
        #expect(!model.agentsLoaded)
        await model.shutdown()
    }

}
