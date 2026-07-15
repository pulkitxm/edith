import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct DashboardSourceSelectionTests {
    private func preferences() -> (UserDefaults, String) {
        let name = "DashboardSourceSelectionTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func usage() throws -> DashUsage {
        let json = """
            {
              "schemaVersion": 4,
              "sources": ["cli", "codex"],
              "defaultSources": ["cli", "codex"],
              "sourceMeta": {
                "cli": {"label": "Claude Code"},
                "codex": {"label": "Codex"}
              },
              "daily": [{
                "period": "2026-07-15",
                "bySource": {
                  "cli": [{
                    "modelName": "claude", "inputTokens": 403000, "outputTokens": 0,
                    "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 1
                  }],
                  "codex": [{
                    "modelName": "gpt", "inputTokens": 31000000, "outputTokens": 0,
                    "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 10
                  }]
                }
              }]
            }
            """
        return try JSONDecoder().decode(DashUsage.self, from: Data(json.utf8))
    }

    @Test func migrationPersistsAllSourcesAcrossRelaunch() throws {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("cli", forKey: "dashSources")
        defaults.set("cli,codex", forKey: "dashKnownSources")

        let firstLaunch = DashboardModel(preferences: defaults)
        firstLaunch.ingest(try usage())

        #expect(firstLaunch.selectedSources == ["cli", "codex"])
        #expect(defaults.string(forKey: "dashSources") == "cli,codex")
        #expect(
            defaults.integer(forKey: "dashSourceSelectionVersion")
                == UsageSourceSelection.currentVersion)

        let secondLaunch = DashboardModel(preferences: defaults)
        secondLaunch.ingest(try usage())

        #expect(secondLaunch.selectedSources == ["cli", "codex"])
        #expect(secondLaunch.series.first { $0.id == "2026-07-15" }?.tokens == 31_403_000)
    }

    @Test func versionedIntentionalDeselectionSurvivesRelaunch() throws {
        let (defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("cli", forKey: "dashSources")
        defaults.set("cli,codex", forKey: "dashKnownSources")
        defaults.set(
            UsageSourceSelection.currentVersion, forKey: "dashSourceSelectionVersion")

        let model = DashboardModel(preferences: defaults)
        model.ingest(try usage())

        #expect(model.selectedSources == ["cli"])
        #expect(model.series.first { $0.id == "2026-07-15" }?.tokens == 403_000)
    }
}
