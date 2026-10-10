import Foundation
import Testing
@testable import PluginsExtension

@Suite struct PluginsInertToolsTests {
    private final class MemoryDefaults: UserDefaults {
        override func object(forKey key: String) -> Any? { nil }
        override func dictionary(forKey key: String) -> [String: Any]? { nil }
        override func set(_ value: Any?, forKey key: String) {}
    }

    @MainActor @Test func explicitUnavailableResolverOwnsDiscoveryAndShutdown() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(MemoryDefaults(suiteName: UUID().uuidString))
        let documents = SkillDocumentStore(cacheDirectory: root) { _ in
            throw SkillsError.message("Fixture download unavailable")
        }
        let installer = SkillInstaller(recordInstalled: { _, _ in
            Issue.record("Unavailable installation must not record success")
        }, unavailableReason: "Fixture installation unavailable", run: { _, _ in
            Issue.record("Unavailable installation must not construct a tool process")
            throw SkillsError.message("Unexpected process")
        })
        let model = SkillsModel(defaults: defaults, documents: documents, installer: installer,
            detectAgents: { [] }, discoverInstaller: { false })
        await model.discoverAgents()
        #expect(model.agentsLoaded)
        #expect(model.agents.isEmpty)
        #expect(!model.installerAvailable)
        await model.shutdown()
        #expect(model.isStopped)
        await model.discoverAgents()
        #expect(!model.installerAvailable)
    }

    @Test func unavailableInstallRejectsBeforeSanitizingEnvironmentOrRunningTools() async throws {
        let installer = SkillInstaller(recordInstalled: { _, _ in
            Issue.record("Unavailable installation must not record success")
        }, unavailableReason: "Fixture installation unavailable", run: { _, _ in
            Issue.record("Unavailable installation must not run a process")
            throw SkillsError.message("Unexpected process")
        })
        await #expect(throws: (any Error).self) {
            try await installer.install(skill: EdithSkillLibrary.skills[0], agentIDs: ["unsupported"],
                home: URL(fileURLWithPath: "/nonexistent-fixture"), environment: [:])
        }
    }
}
