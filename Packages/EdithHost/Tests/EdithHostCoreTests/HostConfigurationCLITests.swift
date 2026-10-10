import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@MainActor @Suite struct HostConfigurationCLITests {
    @Test func originalSetGetUnsetAndScopeBehaviorUsesOnlyExplicitSuites() throws {
        let sharedName = "com.pulkit.edith.tests.config-\(UUID().uuidString)"
        let standardName = sharedName + ".standard"
        let shared = try #require(UserDefaults(suiteName: sharedName))
        let standard = try #require(UserDefaults(suiteName: standardName))
        defer {
            shared.removePersistentDomain(forName: sharedName);
            standard.removePersistentDomain(forName: standardName)
        }
        var changes = 0
        let service = try HostConfigurationCLI(
            shared: shared, standard: standard,
            settings: [
                .init(
                    "sampleEnabled", .bool, group: "sample", summary: "Enabled",
                    fallback: .bool(false)),
                .init(
                    "sampleZoom", .number, group: "sample", summary: "Zoom", scope: "standard",
                    fallback: .number(1)),
            ], changed: { changes += 1 })
        let set = try service.execute(["set", "sampleEnabled", "on", "--json"])
        let object = try JSONDecoder().decode(HostCLIJSON.self, from: Data(set.stdout.utf8)).object
        #expect(object?["previous"] == .bool(false) && object?["value"] == .bool(true))
        #expect(
            shared.bool(forKey: "sampleEnabled") && standard.object(forKey: "sampleEnabled") == nil)
        #expect(try service.execute(["get", "sampleEnabled"]).stdout == "true\n")
        _ = try service.execute(["set", "sampleZoom", "1.5"])
        #expect(
            standard.double(forKey: "sampleZoom") == 1.5
                && shared.object(forKey: "sampleZoom") == nil)
        _ = try service.execute(["unset", "sampleEnabled"])
        #expect(shared.object(forKey: "sampleEnabled") == nil)
        #expect(try service.execute(["get", "sampleEnabled"]).stdout == "false\n")
        #expect(changes == 3)
    }

    @Test func importPreviewSkipsUnknownInvalidAndReadOnlyAndAnnouncesOnceOnApply() throws {
        let name = "com.pulkit.edith.tests.config-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        var changes = 0
        let service = try HostConfigurationCLI(
            shared: store, standard: store,
            settings: [
                .init(
                    "threshold", .int, group: "sample", summary: "Threshold", minimum: 0,
                    maximum: 100, fallback: .integer(20)),
                .init(
                    "enabled", .bool, group: "sample", summary: "Enabled", fallback: .bool(false)),
                .init(
                    "readonly", .bool, group: "sample", summary: "Read only",
                    fallback: .bool(false), readOnly: true),
            ], changed: { changes += 1 })
        let input = Data(
            "{\"threshold\":40,\"enabled\":\"invalid\",\"readonly\":true,\"unknown\":1}".utf8)
        let preview = try service.execute(["import", "-", "--dry-run", "--json"], input: input)
        let object = try JSONDecoder().decode(HostCLIJSON.self, from: Data(preview.stdout.utf8))
            .object
        #expect(object?["applied"] == .strings(["threshold"]))
        #expect(object?["skipped"] == .strings(["enabled", "readonly", "unknown"]))
        #expect(store.object(forKey: "threshold") == nil && changes == 0)
        _ = try service.execute(["import", "-", "--json"], input: input)
        #expect(store.integer(forKey: "threshold") == 40 && changes == 1)
        #expect(try service.execute(["export"]).stdout == "{\"threshold\":40}\n")
        let second = try service.execute(["import", "-", "--json"], input: input)
        let secondObject = try JSONDecoder().decode(
            HostCLIJSON.self, from: Data(second.stdout.utf8)
        ).object
        #expect(secondObject?["unchanged"] == .strings(["threshold"]) && changes == 1)
    }

    @Test func invalidFlagsValuesAndCatalogDefinitionsDoNotWrite() throws {
        let name = "com.pulkit.edith.tests.config-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        let service = try HostConfigurationCLI(shared: store, standard: store)
        for arguments in [
            ["set", "appearance", "sepia"], ["set", "mainWindowZoom", "nan"],
            ["get", "appearance", "--changed"], ["ls", "--json", "--json"], ["get", "unknown"],
        ] {
            #expect(throws: HostCLIError.self) { try service.execute(arguments) }
        }
        #expect(
            store.persistentDomain(forName: name) == nil
                || store.persistentDomain(forName: name)?.isEmpty == true)
    }
}
