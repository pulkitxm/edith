import EdithExtensionSupport
import Foundation
import Testing
@testable import PluginsExtension

@Suite(.serialized) @MainActor struct PluginsRemoteTests {
    @Test func originalPreviewAndCLIShareTheOwnedDocumentAndSelections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = EdithSkillLibrary.skills[0]
        let markdown =
            "---\nname: \(skill.id)\ndescription: Synthetic fixture.\n---\n# Synthetic instructions\n"
        let documents = SkillDocumentStore(cacheDirectory: root) { _ in Data(markdown.utf8) }
        let agents = Array(SkillAgentCatalog.agents.prefix(2))
        let suite = "plugins.remote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = SkillsModel(defaults: defaults, documents: documents, detectAgents: { agents })
        let bridge = PluginsUIBridge(invoke: {
            try await PluginsUIBridge.execute($0, payload: $1, model: engine)
        })
        let ui = SkillsModel(remote: bridge)
        await ui.discoverAgents()
        await ui.present(skill)
        #expect(ui.presentedSkill == skill && ui.selectedAgentIDs == Set(agents.map(\.id)))
        #expect(try await ui.documents.load(skill).markdown == markdown)
        _ = try await bridge.perform(.init(action: "select", agentID: agents[0].id, enabled: false))
        #expect(!engine.selectedAgentIDs.contains(agents[0].id))
        await #expect(throws: (any Error).self) {
            _ = try await bridge.perform(.init(action: "select", agentID: "unknown", enabled: true))
        }
        let copied = try await SkillsCLIExecution.run(
            .init(arguments: ["copy", skill.id]), model: engine)
        #expect(copied.exitCode == 0 && copied.stdout == markdown && copied.stderr.isEmpty)
        let listed = try await SkillsCLIExecution.run(
            .init(arguments: ["ls", "--json"]), model: engine)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [String: Any])
        #expect((object["skills"] as? [[String: Any]])?.count == EdithSkillLibrary.skills.count)
        let invalid = try await SkillsCLIExecution.run(
            .init(arguments: ["preview", "missing"]), model: engine)
        #expect(invalid.exitCode != 0 && invalid.stderr.contains("missing"))
        await ui.shutdown()
        #expect(!engine.isStopped && engine.presentedSkill == skill)
        await engine.shutdown()
    }
}
