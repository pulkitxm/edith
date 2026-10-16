import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageCLIProviderTests {
    private func config(
        _ arguments: [String], defaults: UserDefaults, input: Data = Data(), directory: String = "/"
    ) async throws -> ExtensionCLIReply {
        let controller = UsageWorkerController(
            dataDirectory: Repo.dataDir, collect: { _, _ in Data() })
        let request = try ExtensionCLIRequest(
            arguments: arguments, standardInput: input, workingDirectory: directory)
        let result = try await UsageCLIEnvironment.$resources.withValue(
            UsageCLIResources(controller: controller, defaults: defaults)
        ) {
            try await ExtensionCLIExecution.run(UsageConfigCommand.self, request: request)
        }
        await controller.shutdown()
        return result
    }

    private func completion(_ words: [String]) throws -> (values: [String], files: Bool) {
        let data = try UsageCLIProvider.complete(
            JSONSerialization.data(withJSONObject: ["words": words, "index": words.count - 1]))
        let value = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (
            try #require(value["candidates"] as? [String]), value["wantsFiles"] as? Bool == true
        )
    }

    @Test func liveCatalogPreservesOriginalParserLeavesInputAndOwnSettings() throws {
        let data = try UsageCLIProvider.catalog()
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["version"] as? Int == 1 && catalog["owner"] as? String == "usage")
        #expect(catalog["acceptsInput"] as? Bool == true)
        #expect(catalog["completionOperation"] as? String == "usage.cli.complete")
        let commands = try #require(catalog["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }.map {
            $0.joined(separator: " ")
        }
        let expected = [
            "usage", "usage summary", "usage daily", "usage models", "usage sources",
            "usage limits",
            "usage alerts", "usage projects", "usage projects list", "usage projects show",
            "usage projects open", "usage projects copy-link", "usage projects copy-chat",
            "usage attribution", "usage attribution ls", "usage attribution reset",
            "usage machines",
            "usage machines ls", "usage machines collect", "usage machines enable",
            "usage machines disable", "usage machines forget", "usage refresh", "usage export",
            "usage statusline", "usage statusline status", "usage statusline install",
            "usage statusline remove", "usage statusline record",
        ]
        #expect(Set(expected).isSubset(of: Set(routes)))
        #expect(Set(routes).count == routes.count)
        #expect(
            commands.allSatisfy {
                $0["operation"] as? String == "usage.cli"
                    && $0["streamOperation"] as? String == "usage.cli"
            })
        let input = commands.filter { $0["readsInput"] as? Bool == true }
        #expect(
            input.count == 1
                && input.first?["route"] as? [String] == ["usage", "statusline", "record"])
        let help = try #require((catalog["parserHelp"] as? [[String: Any]])?.first)
        #expect(help["serializationVersion"] as? Int == 0)
        let parser =
            try JSONSerialization.jsonObject(with: Data(UsageCommand._dumpHelp().utf8))
            as? NSDictionary
        #expect(NSDictionary(dictionary: help) == parser)
        let settings = try #require(catalog["settings"] as? [[String: Any]])
        let keys = Set(settings.compactMap { $0["key"] as? String })
        #expect(keys.contains("usageMachines") && keys.contains("dashSources"))
        #expect(keys.contains(AppStorageKeys.Limits.warnPercent))
        #expect(!keys.contains(AppStorageKeys.Tabs.usageEnabled))
        #expect(!keys.contains(AppStorageKeys.MenuBar.systemStats))
        #expect(!keys.contains(AppStorageKeys.General.theme))
    }

    @Test func completionUsesOriginalOptionsValuesProjectsAndChats() throws {
        try FileManager.default.createDirectory(at: Repo.dataDir, withIntermediateDirectories: true)
        try Data(CLIUsageTests.document.utf8).write(to: Repo.usageJSON)
        defer { try? FileManager.default.removeItem(at: Repo.usageJSON) }
        #expect(try completion(["ed", "usage", "stat"]).values == ["statusline"])
        #expect(try completion(["ed", "usage", "--ran"]).values == ["--range"])
        #expect(try completion(["ed", "usage", "summary", "--range", "w"]).values == ["week"])
        #expect(
            try completion(["ed", "usage", "summary", "--range", ""]).values == [
                "today", "week", "month", "all",
            ])
        #expect(try completion(["ed", "usage", "summary", "--ver"]).values == ["--version"])
        #expect(
            try completion(["ed", "usage", "daily", "--source=co"]).values == ["--source=codex"])
        #expect(
            try completion(["ed", "usage", "export", "--card", "a"]).values == ["activity", "all"])
        #expect(try completion(["ed", "usage", "export", "-o", ""]).files)
        #expect(try completion(["ed", "usage", "statusline", "install", "--settings", ""]).files)
        let projects = try completion(["ed", "usage", "projects", "show", ""]).values
        let document = try UsageDocument.load()
        #expect(projects == UsageAnalysis.projectSelectors(document.daily))
        #expect(
            try completion(["ed", "usage", "projects", "copy-chat", ""]).values
                == UsageAnalysis.chatIDs(document.daily))
        #expect(throws: (any Error).self) {
            try UsageCLIProvider.complete(Data(#"{"words":["ed","usage"],"index":999}"#.utf8))
        }
    }

    @Test func originalConfigGetSetUnsetAndValidationUseOnlyOwnedDefaults() async throws {
        let suite = "usage-config-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = AppStorageKeys.Limits.warnPercent
        let set = try await config(["set", key, "72", "--json"], defaults: defaults)
        #expect(set.exitCode == 0 && defaults.integer(forKey: key) == 72)
        let get = try await config(["get", key, "--json"], defaults: defaults)
        #expect(get.stdout.contains("72") && get.stdout.contains("isSet"))
        let invalid = try await config(
            ["set", AppStorageKeys.Budget.mode, "unknown", "--json"], defaults: defaults)
        #expect(invalid.exitCode != 0 && invalid.stderr.contains("allowed"))
        let foreign = try await config(["set", "foreignKey", "true"], defaults: defaults)
        #expect(foreign.exitCode == 3 && defaults.object(forKey: "foreignKey") == nil)
        let unset = try await config(["unset", key, "--json"], defaults: defaults)
        #expect(unset.exitCode == 0 && defaults.object(forKey: key) == nil)
        let fallback = try await config(["get", key], defaults: defaults)
        #expect(fallback.stdout == "60\n")
    }

    @Test func configImportPreviewAndRelativeFilesPreserveOriginalApplyAndSkipResults() async throws
    {
        let suite = "usage-config-import-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = try JSONSerialization.data(withJSONObject: [
            "dashRange": "month", "dashSources": "codex", "foreignKey": "hidden",
            AppStorageKeys.Budget.mode: "invalid",
        ])
        let preview = try await config(
            ["import", "-", "--dry-run", "--json"], defaults: defaults, input: input)
        #expect(preview.exitCode == 0 && preview.stdout.contains("dryRun"))
        #expect(defaults.object(forKey: "dashRange") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try input.write(to: root.appendingPathComponent("settings.json"))
        let applied = try await config(
            ["import", "settings.json", "--json"], defaults: defaults, directory: root.path)
        #expect(applied.exitCode == 0 && applied.stdout.contains("skipped"))
        #expect(defaults.string(forKey: "dashRange") == "month")
        #expect(defaults.string(forKey: "dashSources") == "codex")
        #expect(defaults.object(forKey: "foreignKey") == nil)
        let export = try await config(["export"], defaults: defaults)
        #expect(export.exitCode == 0 && export.stdout.contains("month"))
        let settings = try #require(
            try JSONSerialization.jsonObject(with: Data(export.stdout.utf8)) as? [String: Any])
        #expect(Set(settings.keys) == ["dashRange", "dashSources"])
    }
}
