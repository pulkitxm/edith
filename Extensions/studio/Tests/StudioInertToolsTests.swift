import EdithStudio
import Foundation
import Testing
@testable import StudioExtension

@Suite struct StudioInertToolsTests {
    private final class MemoryDefaults: UserDefaults {
        override func object(forKey key: String) -> Any? { nil }
        override func string(forKey key: String) -> String? { nil }
        override func set(_ value: Any?, forKey key: String) {}
    }

    @MainActor @Test func explicitInertDependenciesOwnStartupRefreshInstallAndShutdown() async throws {
        let defaults = try #require(MemoryDefaults(suiteName: UUID().uuidString))
        let root = URL(fileURLWithPath: "/synthetic-studio-fixture")
        let model = StudioModel(defaults: defaults, loadsState: false, startsLibrary: false,
            detectEnvironment: {
                StudioEnvironment(temporaryRoot: root, appleIntelligenceAvailable: false,
                    translationAvailable: false)
            }, installEngine: { _, _ in "Fixture installation unavailable" })
        model.start()
        for _ in 0..<10_000 {
            if model.environment.temporaryRoot == root { break }
            await Task.yield()
        }
        #expect(model.environment.temporaryRoot == root)
        #expect(model.environment.ffmpeg == nil)
        #expect(model.environment.qpdf == nil)
        #expect(!model.environment.appleIntelligenceAvailable)
        #expect(model.files.isEmpty)
        #expect(model.videoProjects.isEmpty)
        model.install(.ffmpeg)
        for _ in 0..<10_000 {
            if model.installing == nil { break }
            await Task.yield()
        }
        #expect(model.installing == nil)
        #expect(model.message == "Fixture installation unavailable")
        #expect(model.notice == nil)
        model.shutdown()
        #expect(model.isStopped)
        model.refreshEngines()
        model.install(.qpdf)
        #expect(model.installing == nil)
        #expect(model.environment.qpdf == nil)
    }
}
