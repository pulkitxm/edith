import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite struct ProductionPersistenceTests {
    @Test func productionOwnersResolveTheirOriginalStoredDirectories() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let original = support.appendingPathComponent("Edith")
        for (owner, base) in ExtensionData.productionBases {
            let configured = original.appendingPathComponent("Data/" + owner)
            let environment = [
                "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith", "EDITH_EXTENSION_ID": owner,
                "EDITH_EXTENSION_DATA_ROOT": configured.path,
            ]
            let actual = ExtensionData.resolve(environment: environment, fallback: support)
            #expect(
                actual.path
                    == (base.isEmpty ? original : original.appendingPathComponent(base)).path)
            for relative in ExtensionData.productionLeaves[owner] ?? [] {
                let file = original.appendingPathComponent(relative).appendingPathComponent(
                    "synthetic.json")
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("preserved".utf8).write(to: file)
                #expect(try Data(contentsOf: file) == Data("preserved".utf8))
                #expect(
                    ExtensionData.productionDirectory(
                        relative, fallback: support, environment: environment)
                        == original.appendingPathComponent(relative))
            }
        }
    }

    @Test func developmentFixturesAndForeignProductionPathsNeverUseLegacyStorage() {
        let fallback = URL(fileURLWithPath: "/synthetic/fallback")
        for identifier in ["com.pulkit.edith.tests.synthetic", "com.pulkit.edith.dev.synthetic"] {
            let path = "/synthetic/Edith/Data/usage"
            #expect(
                ExtensionData.resolve(
                    environment: [
                        "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": "usage",
                        "EDITH_EXTENSION_DATA_ROOT": path,
                    ], fallback: fallback
                ).path == path)
        }
        for path in [
            "/synthetic/Other/Data/usage", "/synthetic/Edith/Data/herdr", "/synthetic/Edith/usage",
        ] {
            #expect(
                ExtensionData.resolve(
                    environment: [
                        "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith",
                        "EDITH_EXTENSION_ID": "usage", "EDITH_EXTENSION_DATA_ROOT": path,
                    ], fallback: fallback
                ).path == path)
        }
    }

    @Test func onlyDeclaredOwnerLeavesCanResolveAnOriginalDirectory() {
        let fallback = URL(fileURLWithPath: "/synthetic/fallback")
        let environment = [
            "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith", "EDITH_EXTENSION_ID": "usage",
            "EDITH_EXTENSION_DATA_ROOT": "/synthetic/Edith/Data/usage",
        ]
        for path in ["machines", "../foreign", "/foreign", "music"] {
            #expect(
                ExtensionData.productionDirectory(
                    path, fallback: fallback, environment: environment) == fallback)
        }
    }

    @Test func productionDefaultsResolveTheExistingSuiteWithoutOpeningIt() {
        #expect(
            SharedDefaults.resolvedSuite(
                environment: [:], applicationIdentifier: "com.pulkit.edith")
                == "com.pulkit.edith.shared")
        #expect(
            SharedDefaults.resolvedSuite(
                environment: [:], applicationIdentifier: "com.pulkit.edith.tests.synthetic") == nil)
        #expect(
            SharedDefaults.resolvedSuite(
                environment: ["EDITH_SHARED_DEFAULTS_SUITE": "synthetic-owned"],
                applicationIdentifier: "com.pulkit.edith") == "synthetic-owned")
    }
    @MainActor @Test func originalHomeNotchAndOwnerPreferencesSurviveAStoreReopen() throws {
        let suite = "production-persistence-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var tile = SurfaceTile(.usage)
        tile.title = "Saved usage"
        tile.paddingOverride = 7
        tile.cornerOverride = 11
        let home = SurfaceLayout(tiles: [tile]).normalized()
        let notch = SurfaceLayout(tiles: [SurfaceTile(.music)]).normalized()
        defaults.set(home.encoded, forKey: SurfaceTarget.home.key)
        defaults.set(notch.encoded, forKey: SurfaceTarget.notch.key)
        defaults.set(21, forKey: AppStorageKeys.Herdr.terminalFontSize)
        defaults.set(false, forKey: AppStorageKeys.Tabs.usageEnabled)
        let resolved = try #require(
            SharedDefaults.resolvedSuite(
                environment: ["EDITH_SHARED_DEFAULTS_SUITE": suite],
                applicationIdentifier: "com.pulkit.edith"))
        let reopened = try #require(UserDefaults(suiteName: resolved))
        let layouts = SurfaceLayoutStore(defaults: reopened)
        #expect(layouts.home == home && layouts.notch == notch)
        #expect(reopened.integer(forKey: AppStorageKeys.Herdr.terminalFontSize) == 21)
        #expect(reopened.object(forKey: AppStorageKeys.Tabs.usageEnabled) as? Bool == false)
        #expect(reopened.object(forKey: "enabledExtensions") == nil)
    }

}
