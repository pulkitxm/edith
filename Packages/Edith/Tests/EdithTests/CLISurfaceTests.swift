import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIUsageCommandTests {
    static let document = """
        {
          "generatedAt": "2026-08-07T04:00:00Z",
          "sources": ["cli", "codex"],
          "defaultSources": ["cli"],
          "sourceMeta": { "cli": { "label": "Claude Code", "tool": "Claude Code" } },
          "daily": [
            {
              "period": "2026-08-06",
              "bySource": {
                "cli": [
                  { "modelName": "opus", "inputTokens": 10, "outputTokens": 5,
                    "cacheCreationTokens": 1, "cacheReadTokens": 4, "cost": 2.5 }
                ]
              },
              "projects": [
                { "projectName": "edith", "path": "/tmp/edith", "cost": 2.5, "tokens": 20 }
              ]
            }
          ]
        }
        """

    @Test func everyReadingCommandEitherAnswersOrSaysTheDataIsMissing() async {
        for arguments in [
            ["usage", "summary", "--json"], ["usage", "daily", "--json"],
            ["usage", "models", "--json"], ["usage", "projects", "--json"],
            ["usage", "sources", "--json"],
        ] {
            let result = await CLIProbe.run(arguments)
            guard result.code == 0 else {
                #expect(
                    result.code == ExitCodes.unavailable,
                    "\(arguments) exited \(result.code)")
                #expect(result.stdout.isEmpty)
                continue
            }
            #expect((try? result.decoded()) != nil, "\(arguments) printed no document")
        }
    }

    @Test func aMissingUsageFileIsUnavailableRatherThanEmpty() {
        do {
            _ = try UsageDocument.load(from: URL(fileURLWithPath: "/nowhere/usage.json"))
            Issue.record("loading should have failed")
        } catch let failure as CLIFailure {
            #expect(failure.kind == .unavailable)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func everyRangeIsAccepted() throws {
        for range in UsageRange.allCases {
            let window = try UsageWindow.parse(["--range", range.rawValue])
            #expect(try window.resolved() == range)
        }
    }

    @Test func rangesAreCaseInsensitive() throws {
        let window = try UsageWindow.parse(["--range", "WEEK"])
        #expect(try window.resolved() == .week)
    }

    @Test func repeatingSourceNarrowsToASet() throws {
        let document = try JSONDecoder().decode(
            UsageDocument.self, from: Data(Self.document.utf8))
        #expect(try UsageWindow.parse([]).sources(in: document) == nil)
        let window = try UsageWindow.parse(["--source", "cli", "--source", "codex"])
        #expect(try window.sources(in: document) == ["cli", "codex"])
    }

    @Test func totalsAndPerSourceBreakdownsAddUp() throws {
        let document = try JSONDecoder().decode(
            UsageDocument.self, from: Data(Self.document.utf8))
        let totals = UsageAnalysis.totals(document.daily, sources: nil)
        let bySource = UsageAnalysis.bySource(document.daily, sources: nil)
        #expect(totals.cost == 2.5)
        #expect(bySource.values.reduce(0) { $0 + $1.cost } == totals.cost)
    }

    @Test func limitsWithNoHistoryAreUnavailableRatherThanEmpty() async {
        let result = await CLIProbe.run(["usage", "limits", "--json"])
        #expect(result.code == 0 || result.code == ExitCodes.unavailable)
        guard result.code != 0 else { return }
        #expect(result.stdout.isEmpty)
    }

    static let run: [UsageRefreshEvent] = [
        .phase(name: "cli", detail: "28 days", seconds: 0.88),
        .summary(label: "sources", value: "cli, codex"),
        .finished(seconds: 7.8),
    ]

    @Test func refreshRunsWithoutTheAppAndReportsWhatItCollected() async throws {
        try await CLIProbe.inWorld { world in
            world.helperRunning(false)
            CLIEnvironment.usageRefresh = .scripted(events: Self.run)
            let result = await CLIProbe.capture(["usage", "refresh", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["completed"] as? Bool == true)
            #expect(result.object?["followed"] as? Bool == false)
            #expect(result.object?["seconds"] as? Double == 7.8)
            let summary = result.object?["summary"] as? [String: Any]
            #expect(summary?["sources"] as? String == "cli, codex")
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func refreshAttachesToARunOneWhenTheLockIsAlreadyHeld() async throws {
        try await CLIProbe.inWorld { _ in
            CLIEnvironment.usageRefresh = .scripted(events: Self.run, busy: true)
            let result = await CLIProbe.capture(["usage", "refresh", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["followed"] as? Bool == true)
        }
    }

    @Test func followWithNothingRunningIsUnavailableRatherThanAFreshRun() async throws {
        try await CLIProbe.inWorld { _ in
            CLIEnvironment.usageRefresh = .scripted(events: Self.run)
            let result = await CLIProbe.capture(["usage", "refresh", "--follow"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("no usage refresh is running"))
        }
    }

    @Test func aPipelineFailureIsAnErrorRatherThanASilentSuccess() async throws {
        try await CLIProbe.inWorld { _ in
            CLIEnvironment.usageRefresh = .scripted(
                events: [], failure: .reported("no usage found from any source"))
            let result = await CLIProbe.capture(["usage", "refresh"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("no usage found from any source"))
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func refreshKeepsStdoutCleanForPipes() async throws {
        try await CLIProbe.inWorld { _ in
            CLIEnvironment.usageRefresh = .scripted(events: Self.run)
            let result = await CLIProbe.capture(["usage", "refresh"])
            #expect(result.code == 0)
            #expect(result.stdoutLines == ["usage refreshed"])
        }
    }

    @Test func refreshMachineFlagsDistinguishAutomaticAndForcedCollection() throws {
        let automatic = try #require(
            try EdRoot.parseAsRoot(["usage", "refresh"]) as? UsageRefreshCommand)
        let forced = try #require(
            try EdRoot.parseAsRoot(["usage", "refresh", "--machines"])
                as? UsageRefreshCommand)
        let skipped = try #require(
            try EdRoot.parseAsRoot(["usage", "refresh", "--no-machines"])
                as? UsageRefreshCommand)
        #expect(!automatic.forceMachines)
        #expect(!automatic.skipMachines)
        #expect(forced.forceMachines)
        #expect(!forced.skipMachines)
        #expect(!skipped.forceMachines)
        #expect(skipped.skipMachines)
    }

    @Test func refreshRejectsConflictingMachineFlags() async {
        let result = await CLIProbe.run([
            "usage", "refresh", "--machines", "--no-machines",
        ])
        #expect(result.code != 0)
        #expect(result.stderr.contains("cannot be used together"))
    }

    @Test func forcedRefreshDoesNotHideMachineCollectionFailures() {
        let busy = UsageRefreshCommand.forcedMachineCollectionFailure(
            MachineUsageRoundResult(skippedBecauseBusy: true))
        let failed = UsageRefreshCommand.forcedMachineCollectionFailure(
            MachineUsageRoundResult(failures: [(machine: "TUF Wired", reason: "offline")]))
        let succeeded = UsageRefreshCommand.forcedMachineCollectionFailure(
            MachineUsageRoundResult())
        #expect(busy?.kind == .unavailable)
        #expect(failed?.kind == .unavailable)
        #expect(failed?.hint == "TUF Wired: offline")
        #expect(succeeded == nil)
    }
}

@Suite struct CLICompletionSurfaceTests {
    static let machines = ["Asus TUF 7", "tuf"]

    static func plan(_ words: [String], _ index: Int) -> CompletionResult {
        CompletionEngine.plan(
            CompletionRequest(words: words, index: index), machines: machines,
            configKeys: ConfigCatalog.keys,
            extensionIDs: ExtensionRegistry.entries.map(\.id))
    }

    @Test func everyArgumentKindEitherOffersValuesOrDefersToTheShell() {
        let kinds: [ArgumentKind] = [
            .machine, .configKey, .configValue, .extensionID, .permission, .shell, .group,
            .usageRange, .localPath, .remotePath, .container, .appAction, .cleanerCategory,
            .colorFormat, .pruneTarget, .composeProject, .historyIndex, .free,
        ]
        for kind in kinds {
            let values = CompletionEngine.values(
                for: kind, machines: Self.machines, configKeys: ConfigCatalog.keys,
                extensionIDs: ExtensionRegistry.entries.map(\.id), previous: nil)
            switch kind {
            case .configValue, .localPath, .remotePath, .container, .composeProject,
                .historyIndex, .free:
                #expect(values.isEmpty, "\(kind) should defer to the shell")
            default:
                #expect(!values.isEmpty, "\(kind) offers nothing")
            }
        }
    }

    @Test func theNewCommandGroupsCompleteAtTheTopLevel() {
        let result = Self.plan(["ed", ""], 1)
        for name in ["app", "clipboard", "color", "shelf", "cleaner"] {
            #expect(result.candidates.contains(name), "\(name) never completes")
        }
    }

    @Test func appActionsCompleteUnderApp() {
        let result = Self.plan(["ed", "app", ""], 2)
        #expect(result.candidates.contains("clean-keys"))
        #expect(result.candidates.contains("check-updates"))
    }

    @Test func cleanerCategoriesCompleteWhereACategoryGoes() {
        let result = CompletionEngine.values(
            for: .cleanerCategory, machines: [], configKeys: [], extensionIDs: [],
            previous: nil)
        #expect(result == JunkCatalog.entries.map(\.id))
    }

    @Test func pruneTargetsCompleteWhereATargetGoes() {
        let result = Self.plan(["ed", "machines", "docker", "prune", "tuf", ""], 5)
        for target in DockerPruneCommand.targets {
            #expect(result.candidates.contains(target))
        }
    }

    @Test func theCursorBeyondTheWordsMeansAFreshWord() {
        let request = CompletionRequest(words: ["ed", "config"], index: 5)
        #expect(request.current.isEmpty)
        #expect(request.leading == ["config"])
    }

    @Test func aNegativeIndexIsClampedRatherThanCrashing() {
        let request = CompletionRequest(words: ["ed"], index: -4)
        #expect(request.index == 0)
    }

    @Test func nothingIsOfferedTwice() {
        let result = Self.plan(["ed", ""], 1)
        #expect(Set(result.candidates).count == result.candidates.count)
    }

    @Test func everyShellScriptDrivesTheHiddenCompletionCommand() {
        for shell in EdithKit.CompletionScripts.Shell.allCases {
            let script = CompletionScripts.script(for: shell)
            #expect(script.contains("__complete"))
            #expect(!script.isEmpty)
        }
    }

    @Test func theCompletionCommandPrintsOneCandidatePerLine() async {
        let result = await CLIProbe.run(["__complete", "--index", "1", "ed", "conf"])
        #expect(result.code == 0)
        #expect(result.stdoutLines == ["config"])
    }

    @Test func theCompletionCommandNeverFailsOnNonsense() async {
        for arguments in [
            ["__complete"], ["__complete", "--index", "99", "ed"],
            ["__complete", "--index", "0"],
        ] {
            let result = await CLIProbe.run(arguments)
            #expect(result.code == 0, "\(arguments) exited \(result.code)")
        }
    }
}

@Suite struct CLIRemoteReportTests {
    @Test func fileRowsCarryStableFields() {
        let fields = ["d", "4096", "1700000000", "755", "logs", ""]
        let entries = FileListing.parse(
            output: fields.joined(separator: FileListing.separator) + "\n", parent: "/var")
        guard let first = entries.first, case let .object(fields) = MachineReports.file(first)
        else {
            Issue.record("a file should parse into an object")
            return
        }
        #expect(fields["name"] == .string("logs"))
        #expect(fields["kind"] == .string("directory"))
    }

    @Test func aQuotedRemoteCommandSurvivesTheShell() {
        #expect(ShellQuote.command(["ls", "-la", "/a b"]).contains("'/a b'"))
        #expect(ShellQuote.quote("plain") == "plain")
    }

    @Test func remoteCompletionOnlyRunsOverAnOpenSocket() {
        let machine = Machine(name: "nowhere", host: "203.0.113.1", username: "root")
        #expect(!MachineDirectory.hasLiveControlSocket(machine))
    }

    @Test func dockerAvailabilityExplainsEveryFailure() {
        #expect(
            DockerBridge.describe(DockerAvailability(status: .missing))
                == "docker is not installed there")
        #expect(
            DockerBridge.describe(DockerAvailability(status: .permissionDenied))
                .contains("socket"))
        #expect(
            DockerBridge.describe(DockerAvailability(status: .daemonDown(message: "down")))
                == "down")
    }
}

@Suite struct CLIGuideTests {
    @Test func theGuideDocumentsEveryExitCodeTheCLIUses() {
        for code in ["0 success", "1 failure", "2 bad usage", "3 not found", "4 unavailable"] {
            let number = String(code.prefix(1))
            #expect(Guide.text.contains(number), "the guide never mentions exit \(number)")
        }
        #expect(Guide.text.contains("2 bad usage"))
    }

    @Test func theGuideNamesEveryTopLevelCommand() {
        var missing: [String] = []
        for child in EdRoot.configuration.subcommands where child.configuration.shouldDisplay {
            let name = CommandCrawler.name(of: child)
            if !Guide.text.contains("ed \(name)") { missing.append(name) }
        }
        #expect(missing.isEmpty, "the guide never shows: \(missing)")
    }

    @Test func theClaudeSnippetStaysShortAndActionable() {
        #expect(Guide.claudeSnippet.contains("--json"))
        #expect(Guide.claudeSnippet.contains("ed guide"))
        #expect(Guide.claudeSnippet.count < 3000)
    }

    @Test func theGuideIsPrintedAsOneDocumentOnStdout() async {
        let result = await CLIProbe.run(["guide"])
        #expect(result.code == 0)
        #expect(result.stdout.hasPrefix("# ed, in five minutes"))
        #expect(result.stderr.isEmpty)
    }

    @Test func theClaudeTopicIsPrintedOnStdout() async {
        let result = await CLIProbe.run(["guide", "claude"])
        #expect(result.code == 0)
        #expect(result.stdout.contains("Edith, from the command line"))
    }
}
