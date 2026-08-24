import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct ExtensionControlOperationTests {
    static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources")

    static func source(_ path: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func exactControlsHaveOneSharedOperationPlacement() {
        let expected: [(surface: String, action: String, cli: [String])] = [
            (
                "Companion settings", "point at another companion",
                ["config", "set", "companionEndpoint", "http://127.0.0.1:4820"]
            ),
            (
                "Quinjet terminal menu", "select the external terminal",
                ["config", "set", "quinjetTerminal", "cmux"]
            ),
            (
                "Quinjet theme menu", "select the review theme",
                ["config", "set", "quinjetTheme", "tokyo-night"]
            ),
            (
                "Extension sheet", "install a required CLI tool",
                ["tools", "install", "yt-dlp"]
            ),
            ("Download sheet", "cancel running downloads", ["download", "cancel"]),
            (
                "Download queue row", "cancel one active download",
                ["download", "cancel", "1"]
            ),
        ]

        for item in expected {
            let matching = UserInterfaceActionCatalog.actions.filter {
                $0.surface == item.surface && $0.action == item.action && $0.cli == item.cli
            }
            #expect(matching.count == 1)
            #expect(
                !UIParity.legacyCapabilities.contains {
                    $0.surface == item.surface && $0.action == item.action && $0.cli == item.cli
                })
        }
    }

    @Test func typedDescriptorsKeepWriteAndConfirmationContracts() {
        for descriptor in [
            ConfigurationOperation.set.descriptor,
            ExtensionMutationOperation.provisionTool.descriptor,
            DownloadOperation.cancel.descriptor,
        ] {
            #expect(descriptor.effect == .write)
            #expect(!descriptor.requiresPreview)
        }
    }

    @Test func extensionConfigurationKeysShareValidationAndStorage() throws {
        let suite = "ExtensionControlOperationTests.\(UUID().uuidString)"
        let standardSuite = suite + ".standard"
        let shared = UserDefaults(suiteName: suite)!
        let standard = UserDefaults(suiteName: standardSuite)!
        shared.removePersistentDomain(forName: suite)
        standard.removePersistentDomain(forName: standardSuite)
        defer {
            shared.removePersistentDomain(forName: suite)
            standard.removePersistentDomain(forName: standardSuite)
        }
        var announcements = 0
        let executor = ConfigurationExecutor(
            shared: shared, standard: standard, announceChange: { announcements += 1 })

        try executor.set(
            .string("http://127.0.0.1:4820"), forKey: AppStorageKeys.Companion.endpoint)
        try executor.set(.string("cmux"), forKey: AppStorageKeys.Quinjet.terminal)
        try executor.set(.string("tokyo-night"), forKey: AppStorageKeys.Quinjet.theme)

        #expect(shared.string(forKey: AppStorageKeys.Companion.endpoint) == "http://127.0.0.1:4820")
        #expect(shared.string(forKey: AppStorageKeys.Quinjet.terminal) == "cmux")
        #expect(shared.string(forKey: AppStorageKeys.Quinjet.theme) == "tokyo-night")
        #expect(announcements == 3)
        #expect(throws: ConfigurationError.self) {
            try executor.set(.string("unknown"), forKey: AppStorageKeys.Quinjet.terminal)
        }
        #expect(shared.string(forKey: AppStorageKeys.Quinjet.terminal) == "cmux")
        #expect(announcements == 3)
    }

    @Test func appAndCLIControlsUseTheSameExecutionLayers() throws {
        let companion = try Self.source(
            "Edith/Features/Companion/Views/CompanionSettingsView.swift")
        let extensions = try Self.source(
            "Edith/Features/Settings/Views/ExtensionsPane.swift")
        let toolsUI = try Self.source(
            "Edith/Features/Extensions/Views/ToolProvisioningViews.swift")
        let downloadsUI = try Self.source(
            "EdithKit/Features/Music/Services/YoutubeDownloader.swift")
        let configCLI = try Self.source("EdithCLI/Commands/ConfigCommands.swift")
        let toolsCLI = try Self.source("EdithCLI/Commands/ToolsCommands.swift")
        let downloadsCLI = try Self.source("EdithCLI/Commands/DownloadCommands.swift")

        #expect(
            companion.contains(
                "$endpoint.configured(AppStorageKeys.Companion.endpoint).wrappedValue"))
        #expect(
            extensions.contains(
                "$terminal.configured(AppStorageKeys.Quinjet.terminal)"))
        #expect(extensions.contains("$theme.configured(AppStorageKeys.Quinjet.theme)"))
        #expect(toolsUI.contains("center.provision([tool])"))
        #expect(toolsCLI.contains("mutationCenter().install("))
        #expect(downloadsUI.contains("DownloadOperationExecution.cancel(id: targetID)"))
        #expect(downloadsCLI.contains("DownloadOperationExecution.cancel("))
        #expect(configCLI.contains("store.set(parsed, for: found, announce: true)"))
    }

    @Test func completionCoversEveryControlArgumentShape() {
        func plan(_ words: [String], _ index: Int) -> CompletionResult {
            CompletionEngine.plan(
                CompletionRequest(words: words, index: index), machines: [],
                configKeys: ConfigCatalog.keys, extensionIDs: ExtensionRegistry.entries.map(\.id))
        }

        #expect(
            plan(["ed", "config", "set", "quinjetTerminal", ""], 4).candidates
                == ["embedded", "cmux"])
        #expect(
            plan(["ed", "config", "set", "quinjetTheme", "tokyo"], 4).candidates
                == ["tokyo-night"])
        #expect(plan(["ed", "tools", "install", "yt"], 3).candidates == ["yt-dlp"])
        #expect(!plan(["ed", "download", "cancel", ""], 3).wantsFiles)
        #expect(!plan(["ed", "config", "set", "companionEndpoint", ""], 4).wantsFiles)
    }
}

@Suite(.serialized) struct ExtensionControlCLITests {
    @Test func sharedCommandsKeepPlainJSONErrorAndExitContracts() async throws {
        await CLIProbe.inWorld { _ in
            CLIEnvironment.executableNamed = { _ in nil }
            CLIEnvironment.installTool = { tool, _ in
                if tool.id == CLIToolSpec.quinjet.id {
                    throw ToolInstallFailure.unverified(tool.displayName)
                }
                return "2026.08.24"
            }

            let endpoint = await CLIProbe.capture([
                "config", "set", "companionEndpoint", "http://127.0.0.1:4820",
            ])
            #expect(endpoint.code == 0)
            #expect(endpoint.stdout == "companionEndpoint = http://127.0.0.1:4820\n")
            #expect(endpoint.stderr.isEmpty)

            let theme = await CLIProbe.capture([
                "config", "set", "quinjetTheme", "tokyo-night", "--json",
            ])
            #expect(theme.code == 0)
            #expect(theme.object?["key"] as? String == "quinjetTheme")
            #expect(theme.object?["value"] as? String == "tokyo-night")

            let invalidTerminal = await CLIProbe.capture([
                "config", "set", "quinjetTerminal", "unknown",
            ])
            #expect(invalidTerminal.code == ExitCodes.failure)
            #expect(invalidTerminal.stdout.isEmpty)
            #expect(invalidTerminal.stderr.contains("allowed: embedded, cmux"))

            let tool = await CLIProbe.capture(["tools", "install", "yt-dlp"])
            #expect(tool.code == 0)
            #expect(tool.stdout == "installed yt-dlp (2026.08.24)\n")

            let toolFailure = await CLIProbe.capture(["tools", "install", "quinjet"])
            #expect(toolFailure.code == ExitCodes.unavailable)
            #expect(toolFailure.stdout.isEmpty)
            #expect(toolFailure.stderr.contains("could not be verified"))

            _ = await CLIProbe.capture([
                "download", "add", "https://youtu.be/one", "https://youtu.be/two", "--json",
            ])
            let one = await CLIProbe.capture(["download", "cancel", "1"])
            #expect(one.code == 0)
            #expect(one.stdout.contains("cancelled"))
            let remaining = await CLIProbe.capture(["download", "cancel", "--json"])
            #expect(remaining.code == 0)
            #expect(remaining.object?["cancelled"] as? Int == 1)
            #expect((remaining.object?["records"] as? [[String: Any]])?.count == 1)
        }
    }
}
