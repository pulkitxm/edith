import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLICompletionTests {
    static let machines = ["Asus TUF 7", "tuf"]
    static let extensionIDs = ExtensionRegistry.entries.map(\.id)

    static func plan(
        _ words: [String], _ index: Int, usageSources: [String] = [],
        usageChatIDs: [String] = [], usageProjects: [String] = [],
        quinjetSessions: [String] = []
    ) -> CompletionResult {
        CompletionEngine.plan(
            CompletionRequest(words: words, index: index), machines: machines,
            configKeys: ConfigCatalog.keys, extensionIDs: extensionIDs,
            usageSources: usageSources, usageChatIDs: usageChatIDs,
            usageProjects: usageProjects,
            quinjetSessions: quinjetSessions)
    }

    @Test func theTopLevelOffersCommandsAndMachines() {
        let result = Self.plan(["ed", ""], 1)
        #expect(result.candidates.contains("config"))
        #expect(result.candidates.contains("help"))
        #expect(result.candidates.contains("lid-awake"))
        #expect(result.candidates.contains("machines"))
        #expect(result.candidates.contains("tuf"))
        #expect(result.remoteMachine == nil)
    }

    @Test func candidatesAreFilteredByThePrefix() {
        let result = Self.plan(["ed", "mac"], 1)
        #expect(result.candidates == ["machines"])
    }

    @Test func namingAMachineFirstHandsOverToRemoteCompletion() {
        let result = Self.plan(["ed", "tuf", "doc"], 2)
        #expect(result.remoteMachine == "tuf")
        #expect(result.candidates.isEmpty)
    }

    @Test func aReservedWordIsNeverTreatedAsAMachine() {
        let result = Self.plan(["ed", "config", ""], 2)
        #expect(result.remoteMachine == nil)
        #expect(result.candidates.contains("set"))
    }

    @Test func settingKeysCompleteWhereAKeyGoes() {
        let result = Self.plan(["ed", "config", "set", "presenterB"], 3)
        #expect(result.candidates.contains("presenterBlurMoney"))
        #expect(!result.candidates.contains("warnPercent"))
    }

    @Test func allowedValuesCompleteAfterTheirKey() {
        let result = Self.plan(["ed", "config", "set", "limitsProvider", ""], 4)
        #expect(result.candidates == ["claude", "codex"])
    }

    @Test func booleanSettingsOfferTrueAndFalse() {
        let result = Self.plan(["ed", "config", "set", "preventSleep", ""], 4)
        #expect(result.candidates == ["true", "false"])
    }

    @Test func extensionIDsCompleteForEnable() {
        let result = Self.plan(["ed", "extensions", "enable", "cli"], 3)
        #expect(result.candidates == ["clipboard"])
    }

    @Test func permissionIDsCompleteForEveryTypedPermissionRoute() {
        for command in ["request", "settings"] {
            let result = Self.plan(["ed", "permissions", command, "screen"], 3)
            #expect(result.candidates == ["screenRecording"])
        }
    }

    @Test func extensionLifecycleCommandsCompleteIDsAndFlags() {
        for command in ["enable", "disable", "info", "status", "setup", "verify", "doctor"] {
            let ids = Self.plan(["ed", "extensions", command, "quin"], 3)
            #expect(ids.candidates == ["quinjet"])
        }
        let flags = Self.plan(["ed", "extensions", "setup", "--i"], 3)
        #expect(flags.candidates == ["--install-tools"])
    }
    @Test func toolIDsCompleteForInstall() {
        let result = Self.plan(["ed", "tools", "install", "q"], 3)
        #expect(result.candidates == ["quinjet"])
    }

    @Test func appInspectionTargetsCompleteFromTheirTypedDomains() {
        let paths = Self.plan(["ed", "app", "open-path", ""], 3)
        let links = CompletionEngine.plan(
            CompletionRequest(words: ["ed", "app", "open-link", "con"], index: 3),
            machines: Self.machines, configKeys: ConfigCatalog.keys,
            extensionIDs: Self.extensionIDs,
            appLinks: ["repository", "creator", "contributor:octo"])

        #expect(paths.candidates == AppPathID.allCases.map(\.rawValue))
        #expect(links.candidates == ["contributor:octo"])
    }

    @Test func colorPickerOperationsCompleteUnderColor() {
        let result = Self.plan(["ed", "color", ""], 2)

        #expect(result.candidates.contains("pick"))
        #expect(result.candidates.contains("copy"))
        #expect(result.candidates.contains("ls"))
        #expect(result.candidates.contains("clear"))
    }

    @Test func lidAwakeCommandsAndFlagsComplete() {
        let commands = Self.plan(["ed", "lid-awake", ""], 2)
        #expect(commands.candidates == ["status", "on", "off", "battery", "restore-on-quit"])
        let flags = Self.plan(["ed", "lid-awake", "on", "--u"], 3)
        #expect(flags.candidates == ["--until-lid-reopens"])
    }

    @Test func quinjetOperationsAndLaunchOptionsComplete() {
        let commands = Self.plan(["ed", "quinjet", ""], 2)
        #expect(
            commands.candidates
                == [
                    "projects", "worktrees", "open", "launch", "status", "sessions",
                    "new", "focus", "close", "restart", "switch",
                ])
        let appearance = Self.plan(["ed", "quinjet", "launch", "--a"], 3)
        #expect(appearance.candidates == ["--appearance"])
        let target = Self.plan(["ed", "quinjet", "projects", "--m"], 3)
        #expect(target.candidates == ["--machine"])
        let machines = Self.plan(["ed", "quinjet", "projects", "--machine", ""], 4)
        #expect(machines.candidates.contains("local"))
        #expect(machines.candidates.contains("tuf"))
        let themes = Self.plan(["ed", "quinjet", "open", "--theme", "to"], 4)
        #expect(themes.candidates == ["tokyo-night"])
        let appearances = Self.plan(["ed", "quinjet", "launch", "--appearance=l"], 3)
        #expect(appearances.candidates == ["--appearance=light"])
        #expect(Self.plan(["ed", "quinjet", "open", ""], 3).wantsFiles)
        #expect(
            Self.plan(["ed", "quinjet", "open", "--machine", "local", ""], 5).wantsFiles)
        #expect(
            !Self.plan(["ed", "quinjet", "open", "--machine", "tuf", ""], 5).wantsFiles)
        #expect(!Self.plan(["ed", "quinjet", "open", "--machine=tuf", ""], 4).wantsFiles)
        let sessions = Self.plan(
            ["ed", "quinjet", "focus", ""], 3, quinjetSessions: ["1", "2"])
        #expect(sessions.candidates == ["1", "2"])
        #expect(Self.plan(["ed", "quinjet", "switch", "1", ""], 4).wantsFiles)
    }

    @Test func machineNamesCompleteInsideTheMachinesTree() {
        let result = Self.plan(["ed", "machines", "docker", "ps", ""], 4)
        #expect(result.candidates.contains("tuf"))
    }

    @Test func machinesOffersBothItsVerbsAndTheMachineNames() {
        let result = Self.plan(["ed", "machines", ""], 2)
        #expect(result.candidates.contains("ls"))
        #expect(result.candidates.contains("docker"))
        #expect(result.candidates.contains("tuf"))
    }

    @Test func aMachineNamedFirstStillCompletesTheVerbsAfterIt() {
        let result = Self.plan(["ed", "machines", "tuf", ""], 3)
        #expect(result.candidates.contains("docker"))
        #expect(result.candidates.contains("files"))
    }

    @Test func aMachineNamedFirstCompletesNestedVerbsToo() {
        let result = Self.plan(["ed", "machines", "tuf", "docker", ""], 4)
        #expect(result.candidates.contains("ps"))
        #expect(result.candidates.contains("logs"))
    }

    @Test func flagsCompleteWhenTheWordStartsWithADash() {
        let result = Self.plan(["ed", "machines", "ls", "--j"], 3)
        #expect(result.candidates == ["--json"])
    }

    @Test func defaultSubcommandOptionsAndValuesCompleteOnBareGroups() {
        #expect(Self.plan(["ed", "config", "--c"], 2).candidates == ["--changed"])
        #expect(Self.plan(["ed", "completions", "--s"], 2).candidates == ["--shell"])
        #expect(Self.plan(["ed", "clipboard", "--s"], 2).candidates == ["--search"])
        #expect(Self.plan(["ed", "color", "--f"], 2).candidates == ["--format"])
        #expect(
            Self.plan(["ed", "color", "--format", ""], 3).candidates
                == ColorCopyFormat.allCases.map(\.rawValue))
    }

    @Test func defaultSubcommandSyntaxCommitsCompletionToThatRoute() {
        for words in [
            ["ed", "config", "--changed", ""],
            ["ed", "config", "--group", "general", ""],
            ["ed", "config", "prevent", ""],
            ["ed", "download", "--limit", "1", ""],
            ["ed", "extensions", "--json", ""],
            ["ed", "music", "--player", "spotify", ""],
            ["ed", "system", "--follow", ""],
        ] {
            let result = Self.plan(words, words.count - 1)
            #expect(result.candidates.isEmpty, "\(words) offered \(result.candidates)")
        }
    }

    @Test func passthroughRoutesNeverOfferLocalOptions() {
        for words in [
            ["ed", "machines", "broadcast", "--", "--v"],
            ["ed", "machines", "snippets", "add", "tuf", "title", "--v"],
            ["ed", "config", "get", "--", "--v"],
            ["ed", "config", "ls", "--group", "--", "--v"],
        ] {
            let result = Self.plan(words, words.count - 1)
            #expect(result.candidates.isEmpty, "\(words) offered \(result.candidates)")
            #expect(result.remoteMachine == nil)
        }
    }

    @Test func explicitExecHandsItsCapturedCommandToRemoteCompletion() throws {
        let first = Self.plan(["ed", "machines", "exec", "tuf", "--v"], 4)
        let nested = Self.plan(["ed", "machines", "exec", "tuf", "uptime", "--v"], 5)
        let separated = Self.plan(
            ["ed", "machines", "exec", "tuf", "--", "uptime", "--v"], 6)

        #expect(first.candidates.isEmpty)
        #expect(first.remoteMachine == "tuf")
        #expect(first.remoteRequest?.words == ["ed", "tuf", "--v"])
        #expect(first.remoteRequest?.index == 2)
        #expect(nested.remoteMachine == "tuf")
        #expect(nested.remoteRequest?.words == ["ed", "tuf", "uptime", "--v"])
        #expect(separated.remoteMachine == "tuf")
        #expect(separated.remoteRequest?.words == ["ed", "tuf", "uptime", "--v"])
    }

    @Test func freeOptionValuesDoNotConsumePositionalCompletionSlots() {
        let words = [
            "ed", "companion", "connectors", "import", "--endpoint",
            "http://localhost:8000", "calendar", "",
        ]
        #expect(Self.plan(words, 7).wantsFiles)

        let assignment = [
            "ed", "companion", "connectors", "import",
            "--endpoint=http://localhost:8000", "calendar", "",
        ]
        #expect(Self.plan(assignment, 6).wantsFiles)

        let value = Self.plan(
            ["ed", "companion", "connectors", "import", "--endpoint", "http"], 5)
        #expect(value.candidates.isEmpty)
        #expect(!value.wantsFiles)
    }

    @Test func shortOptionsAndSynthesizedHelpComplete() {
        #expect(Self.plan(["ed", "music", "status", "-h"], 3).candidates == ["-h"])
        #expect(Self.plan(["ed", "system", "stats", "-f"], 3).candidates == ["-f"])
        #expect(Self.plan(["ed", "machines", "files", "ls", "-a"], 4).candidates == ["-a"])
        #expect(Self.plan(["ed", "h"], 1).candidates == ["help", "herdr"])
        #expect(Self.plan(["ed", "help", "ext"], 2).candidates == ["extensions"])
        #expect(Self.plan(["ed", "help", "extensions", "st"], 3).candidates == ["status"])
        #expect(Self.plan(["ed", "help", "config", "--j"], 3).candidates.isEmpty)
    }

    @Test func machineShorthandFlagsCompleteAgainstTheLocalShowRoute() {
        let result = Self.plan(["ed", "tuf", "--j"], 2)
        #expect(result.candidates == ["--json"])
        #expect(result.remoteMachine == nil)
        #expect(Self.plan(["ed", "tuf", "upt"], 2).remoteMachine == "tuf")
    }

    @Test func completionNeverAddsGlobalsTheParserRejects() {
        for words in [["ed", "--j"], ["ed", "guide", "--j"], ["ed", "schema", "--j"]] {
            #expect(Self.plan(words, words.count - 1).candidates.isEmpty)
        }
    }

    @Test func typedOptionValuesComeFromTheirDomainModels() {
        #expect(
            Self.plan(["ed", "music", "status", "--player", ""], 4).candidates
                == MusicPlayer.allCases.map(\.rawValue))
        #expect(
            Self.plan(["ed", "download", "add", "--kind", ""], 4).candidates
                == DownloadKind.allCases.map(\.rawValue))
        #expect(
            Self.plan(["ed", "color", "ls", "--format", ""], 4).candidates
                == ColorCopyFormat.allCases.map(\.rawValue))
        #expect(
            Self.plan(["ed", "tools", "install", ""], 3).candidates.contains("quinjet"))
    }

    @Test func runningApplicationsCompleteForQuit() {
        let result = CompletionEngine.plan(
            CompletionRequest(words: ["ed", "apps", "quit", "Sa"], index: 3),
            machines: [], configKeys: [], extensionIDs: [],
            runningApps: ["Safari", "Music"])

        #expect(result.candidates == ["Safari"])
    }

    @Test func downloadCancellationAcceptsTheSameHistoryIndexAsOtherRecordActions() {
        let download = CommandTree.root.child("download")
        #expect(download?.child("cancel")?.arguments == [.historyIndex])
        #expect(Self.plan(["ed", "download", "cancel", ""], 3).wantsFiles == false)
    }

    @Test func typedOptionsWorkAfterOtherOptionsAndWithEqualsSyntax() {
        let sources = Self.plan(
            ["ed", "usage", "summary", "--range", "week", "--source", ""], 6,
            usageSources: ["claude", "codex"])
        #expect(sources.candidates == ["claude", "codex"])
        let player = Self.plan(["ed", "music", "status", "--player=sp"], 3)
        #expect(player.candidates == ["--player=spotify"])
        let nested = Self.plan(
            ["ed", "music", "--player", "spotify", "--player", ""], 5)
        #expect(nested.candidates == MusicPlayer.allCases.map(\.rawValue))
    }

    @Test func usageChatIDsCompleteOnlyForCopyChat() {
        let ids = ["chat-alpha", "chat-beta"]
        let copy = Self.plan(
            ["ed", "usage", "projects", "copy-chat", "chat-a"], 4,
            usageChatIDs: ids)
        let show = Self.plan(
            ["ed", "usage", "projects", "show", "chat-a"], 4,
            usageChatIDs: ids)
        #expect(copy.candidates == ["chat-alpha"])
        #expect(show.candidates.isEmpty)
    }

    @Test func usageRepositoriesCompleteOnlyForRepositoryArguments() {
        let projects = ["edith", "github.com/acme/edith"]
        for command in ["show", "open", "copy-link"] {
            let result = Self.plan(
                ["ed", "usage", "projects", command, "git"], 4,
                usageProjects: projects)
            #expect(result.candidates == ["github.com/acme/edith"])
        }
        let copyChat = Self.plan(
            ["ed", "usage", "projects", "copy-chat", "git"], 4,
            usageProjects: projects)
        #expect(copyChat.candidates.isEmpty)
    }

    @Test func localPathsAskTheShellForFiles() {
        let result = Self.plan(["ed", "config", "import", ""], 3)
        #expect(result.wantsFiles)
        #expect(result.lines.first == "#files")
    }

    @Test func theTerminatorIsNotMistakenForTheProgramName() {
        let stripped = CompletionRequest.stripSeparator(["--", "ed", "config"])
        #expect(stripped == ["ed", "config"])
    }

    @Test func remoteCompletionAsksForCommandNamesAtTheFirstWord() {
        let command = RemoteCompletion.commandNamesCommand(prefix: "doc")
        #expect(command.hasPrefix("compgen -c -- doc"))
    }

    @Test func remoteCompletionForwardsTheWholeWordListToBash() {
        let command = RemoteCompletion.harnessCommand(
            words: ["docker", "compose", ""], cursor: 2)
        #expect(command.hasPrefix("bash -c "))
        #expect(command.contains("ed-complete 2 docker compose"))
        #expect(command.contains("_completion_loader"))
    }

    @Test func everyCompletionTreeNodeExistsInTheParser() throws {
        var missing: [String] = []
        check(node: CommandTree.root, command: EdRoot.self, path: [], missing: &missing)
        #expect(
            missing.isEmpty, "completion tree names commands the parser does not have: \(missing)")
    }

    private func check(
        node: CommandNode, command: ParsableCommand.Type, path: [String], missing: inout [String]
    ) {
        let declared = command.configuration.subcommands
        for child in node.children {
            guard
                let match = declared.first(where: {
                    $0.configuration.commandName == child.name
                        || $0.configuration.aliases.contains(child.name)
                })
            else {
                missing.append((path + [child.name]).joined(separator: " "))
                continue
            }
            check(node: child, command: match, path: path + [child.name], missing: &missing)
        }
    }
}

@Suite struct CLICompletionProcessTests {
    struct ShellCompletionScenario: Sendable {
        let words: [String]
        let expected: Set<String>
        let requiresExactMatch: Bool
    }

    struct ShellCompletionInvocation: Sendable {
        let shell: CompletionScripts.Shell
        let scenario: ShellCompletionScenario
    }

    static let shellCompletionScenarios = [
        ShellCompletionScenario(
            words: ["ed", "machines", "docker", ""], expected: ["ps", "logs"],
            requiresExactMatch: false),
        ShellCompletionScenario(
            words: ["ed", "music", "status", "--h"], expected: ["--help"],
            requiresExactMatch: true),
        ShellCompletionScenario(
            words: ["ed", "extensions", "verify", "clipboard", "--v"],
            expected: ["--version"], requiresExactMatch: true),
        ShellCompletionScenario(
            words: ["ed", "config", "--c"], expected: ["--changed"],
            requiresExactMatch: true),
        ShellCompletionScenario(
            words: ["ed", "system", "stats", "-f"], expected: ["-f"],
            requiresExactMatch: true),
        ShellCompletionScenario(
            words: ["ed", "h"], expected: ["help", "herdr"], requiresExactMatch: true),
        ShellCompletionScenario(
            words: ["ed", "music", "status", "--player", ""],
            expected: Set(MusicPlayer.allCases.map(\.rawValue)), requiresExactMatch: true),
        ShellCompletionScenario(
            words: ["ed", "extensions", "verify", ""],
            expected: Set(ExtensionRegistry.entries.map(\.id)), requiresExactMatch: true),
    ]

    static let bashAndZshCompletionInvocations = [
        CompletionScripts.Shell.bash, .zsh,
    ].flatMap { shell in
        shellCompletionScenarios.map { ShellCompletionInvocation(shell: shell, scenario: $0) }
    }

    static var fishIsRequired: Bool {
        ProcessInfo.processInfo.environment["EDITH_REQUIRE_FISH_COMPLETION_TEST"] == "1"
    }

    static var fishExecutable: URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("fish") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-completion-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func completionWorksOutsideARepositoryAndRejectsInvalidGlobals() throws {
        let outside = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let invalid = try CLIProcessProbe.run(
            ["__complete", "--index", "1", "--", "ed", "--j"],
            currentDirectory: outside)
        let typed = try CLIProcessProbe.run(
            ["__complete", "--index", "4", "--", "ed", "music", "status", "--player", ""],
            currentDirectory: outside)

        #expect(invalid.code == 0)
        #expect(invalid.stdout.isEmpty)
        #expect(invalid.stderr.isEmpty)
        #expect(typed.code == 0)
        #expect(Set(typed.stdoutLines) == Set(MusicPlayer.allCases.map(\.rawValue)))
        #expect(typed.stderr.isEmpty)
    }

    @Test func packagedCompletionRejectsSiblingAndLocalPassthroughSuggestions() throws {
        let outside = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let routes = [
            ["ed", "config", "--changed", ""],
            ["ed", "download", "--limit", "1", ""],
            ["ed", "extensions", "--json", ""],
            ["ed", "system", "--follow", ""],
            ["ed", "machines", "exec", "not-configured", "--v"],
            ["ed", "machines", "broadcast", "--", "--v"],
            ["ed", "config", "get", "--", "--v"],
        ]
        for words in routes {
            let result = try CLIProcessProbe.run(
                ["__complete", "--index", String(words.count - 1), "--"] + words,
                currentDirectory: outside)
            #expect(result.code == 0, "\(words) exited \(result.code)")
            #expect(result.stdout.isEmpty, "\(words) offered \(result.stdoutLines)")
            #expect(result.stderr.isEmpty, "\(words) reported \(result.stderr)")
        }
    }

    @Test func inheritedHelpCompletesOutsideARepository() throws {
        let outside = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let result = try CLIProcessProbe.run(
            ["__complete", "--index", "3", "--", "ed", "music", "status", "--h"],
            currentDirectory: outside)

        #expect(result.code == 0)
        #expect(result.stdoutLines == ["--help"])
        #expect(result.stderr.isEmpty)
    }

    @Test func everyParserOptionCompletesOutsideARepository() throws {
        let outside = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let cases = [
            (["ed", "extensions", "verify", "clipboard", "--v"], ["--version"]),
            (["ed", "machines", "add", "box", "--password"], ["--password-stdin"]),
            (["ed", "machines", "add", "box", "--key-p"], ["--key-passphrase-stdin"]),
            (["ed", "machines", "edit", "box", "--password"], ["--password-stdin"]),
            (["ed", "machines", "edit", "box", "--key-p"], ["--key-passphrase-stdin"]),
            (["ed", "machines", "exec", "--t"], ["--tty"]),
            (["ed", "config", "--c"], ["--changed"]),
            (["ed", "completions", "--s"], ["--shell"]),
            (["ed", "clipboard", "--s"], ["--search"]),
            (["ed", "system", "stats", "-f"], ["-f"]),
            (["ed", "machines", "files", "ls", "-a"], ["-a"]),
            (["ed", "h"], ["help", "herdr"]),
        ]

        for (words, expected) in cases {
            let result = try CLIProcessProbe.run(
                ["__complete", "--index", String(words.count - 1), "--"] + words,
                currentDirectory: outside)
            #expect(result.code == 0)
            #expect(result.stdoutLines == expected)
            #expect(result.stderr.isEmpty)
        }
    }

    @Test func appInspectionCompletionWorksOutsideARepository() throws {
        let outside = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let result = try CLIProcessProbe.run(
            ["__complete", "--index", "3", "--", "ed", "app", "open-path", ""],
            currentDirectory: outside)

        #expect(result.code == 0)
        #expect(result.stdoutLines == AppPathID.allCases.map(\.rawValue))
        #expect(result.stderr.isEmpty)
    }

    @Test func requiredFishCompletionDependencyIsAvailable() {
        guard Self.fishIsRequired else { return }
        #expect(Self.fishExecutable != nil)
    }

    @Test(arguments: bashAndZshCompletionInvocations)
    func bashAndZshScriptsCompleteTheFullMatrix(invocation: ShellCompletionInvocation) throws {
        let outside = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let script = try Self.installCompletionScript(for: invocation.shell, outside: outside)
        let result = try Self.shellCompletion(
            invocation.scenario, shell: invocation.shell, script: script, outside: outside)
        Self.expect(result, matches: invocation.scenario)
    }

    @Test func bashPreservesMetacharacterCandidatesFromTheProductionShim() throws {
        let outside = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let fake = outside.appendingPathComponent("completion-source")
        try """
        #!/bin/bash
        printf '%s\\n' 'track * [mix].mp3'
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.path)
        try Data().write(to: outside.appendingPathComponent("track album m.mp3"))
        let script = CompletionScripts.defaultDirectory(for: .bash, home: outside)
            .appendingPathComponent(CompletionScripts.Shell.bash.scriptName)
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CompletionScripts.script(for: .bash, tool: fake.path)
            .write(to: script, atomically: true, encoding: .utf8)

        let scenario = ShellCompletionScenario(
            words: ["ed", "track"], expected: ["track * [mix].mp3"],
            requiresExactMatch: true)
        let result = try Self.shellCompletion(
            scenario, shell: .bash, script: script, outside: outside)

        Self.expect(result, matches: scenario)
    }

    @Test(.enabled(if: fishExecutable != nil), arguments: shellCompletionScenarios)
    func fishCompletesTheFullMatrix(scenario: ShellCompletionScenario) throws {
        let outside = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let script = try Self.installCompletionScript(for: .fish, outside: outside)
        let result = try Self.shellCompletion(
            scenario, shell: .fish, script: script, outside: outside)

        #expect(
            script.path == outside.appendingPathComponent(".config/fish/completions/ed.fish").path)
        Self.expect(result, matches: scenario)
    }

    static func installCompletionScript(for shell: CompletionScripts.Shell, outside: URL) throws
        -> URL
    {
        let directory = CompletionScripts.defaultDirectory(for: shell, home: outside)
        let script = directory.appendingPathComponent(shell.scriptName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CompletionScripts.script(for: shell, tool: CLIProcessProbe.binary.path)
            .write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    static func shellCompletion(
        _ scenario: ShellCompletionScenario, shell: CompletionScripts.Shell, script: URL,
        outside: URL
    ) throws -> CLIRun {
        let words = scenario.words.map(ShellQuote.quote).joined(separator: " ")
        switch shell {
        case .bash:
            return try CLIProcessProbe.run(
                [
                    "-c",
                    "source \"$1\"; COMP_WORDS=(\(words)); "
                        + "COMP_CWORD=\(scenario.words.count - 1); _ed_complete; "
                        + "printf '%s\\n' \"${COMPREPLY[@]}\"",
                    "completion-test", script.path,
                ], executable: URL(fileURLWithPath: "/bin/bash"), currentDirectory: outside)
        case .zsh:
            return try CLIProcessProbe.run(
                [
                    "-c",
                    "compdef() { :; }; compadd() { shift; print -l -- \"$@\"; }; "
                        + "source \"$1\"; words=(\(words)); CURRENT=\(scenario.words.count); "
                        + "_ed_complete",
                    "completion-test", script.path,
                ], executable: URL(fileURLWithPath: "/bin/zsh"), currentDirectory: outside)
        case .fish:
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = outside.path
            environment["XDG_CONFIG_HOME"] = outside.appendingPathComponent(".config").path
            environment["PATH"] =
                CLIProcessProbe.binary.deletingLastPathComponent().path + ":"
                + (environment["PATH"] ?? "")
            return try CLIProcessProbe.run(
                [
                    "--private", "-c", "source \"$argv[1]\"; complete -C \"$argv[2]\"",
                    script.path, scenario.words.joined(separator: " "),
                ], executable: fishExecutable, currentDirectory: outside, environment: environment)
        }
    }

    static func expect(_ result: CLIRun, matches scenario: ShellCompletionScenario) {
        let actual = Set(result.stdoutLines)
        #expect(result.code == 0)
        #expect(result.stderr.isEmpty)
        if scenario.requiresExactMatch {
            #expect(actual == scenario.expected)
        } else {
            #expect(actual.isSuperset(of: scenario.expected))
        }
    }

    @Test func everyShellGenerationCarriesAliasesAndTheAbsoluteEntryPath() {
        for shell in CompletionScripts.Shell.allCases {
            let script = CompletionScripts.script(for: shell, tool: CLIProcessProbe.binary.path)
            #expect(script.contains(CLIProcessProbe.binary.path))
            #expect(script.contains("edh"))
            #expect(script.contains("edith"))
            #expect(script.contains("__complete"))
        }
    }
}

@Suite struct CLIArgumentRewritingTests {
    static let machines = ["Asus TUF 7", "tuf"]

    @Test func aMachineNameTurnsIntoARemoteExec() {
        #expect(
            ArgumentRewriting.rewrite(["tuf", "docker", "ps"], machines: Self.machines)
                == ["machines", "exec", "tuf", "--", "docker", "ps"])
    }

    @Test func machineNamesAreMatchedCaseInsensitively() {
        #expect(
            ArgumentRewriting.rewrite(["TUF", "uptime"], machines: Self.machines)
                == ["machines", "exec", "TUF", "--", "uptime"])
    }

    @Test func aBareMachineNameShowsTheMachine() {
        #expect(
            ArgumentRewriting.rewrite(["tuf"], machines: Self.machines)
                == ["machines", "show", "tuf"])
    }

    @Test func reservedCommandsWinOverMachineNames() {
        #expect(
            ArgumentRewriting.rewrite(["config", "ls"], machines: ["config"])
                == ["config", "ls"])
        #expect(
            ArgumentRewriting.rewrite(["__complete", "--index", "1"], machines: ["__complete"])
                == ["__complete", "--index", "1"])
    }

    @Test func flagsAndUnknownWordsAreLeftAlone() {
        #expect(ArgumentRewriting.rewrite(["--help"], machines: Self.machines) == ["--help"])
        #expect(
            ArgumentRewriting.rewrite(["nope", "ls"], machines: Self.machines) == ["nope", "ls"])
        #expect(ArgumentRewriting.rewrite([], machines: Self.machines) == [])
    }

    @Test func theSeparatorIsStrippedBeforeTheCommandReachesSSH() {
        #expect(MachinesExecCommand.strippingSeparator(["--", "ls", "-la"]) == ["ls", "-la"])
        #expect(MachinesExecCommand.strippingSeparator(["ls", "-la"]) == ["ls", "-la"])
    }

    @Test func aBareMachineNameWithOnlyFlagsShowsTheMachine() {
        #expect(
            ArgumentRewriting.rewrite(["tuf", "--json"], machines: Self.machines)
                == ["machines", "show", "tuf", "--json"])
    }
}

@Suite struct MachineFirstOrderTests {
    static let machines = ["Asus TUF 7", "tuf"]

    static func rewrite(_ words: [String]) -> [String] {
        ArgumentRewriting.rewrite(words, machines: machines)
    }

    @Test func theMachineNameMayComeFirstUnderMachines() {
        #expect(
            Self.rewrite(["machines", "tuf", "docker", "ps"])
                == ["machines", "docker", "ps", "tuf"])
        #expect(
            Self.rewrite(["machines", "tuf", "metrics"]) == ["machines", "metrics", "tuf"])
        #expect(
            Self.rewrite(["machines", "tuf", "services", "--failed"])
                == ["machines", "services", "tuf", "--failed"])
    }

    @Test func aNestedSubcommandKeepsItsWholePathBeforeTheMachine() {
        #expect(
            Self.rewrite(["machines", "tuf", "files", "ls", "/etc"])
                == ["machines", "files", "ls", "tuf", "/etc"])
        #expect(
            Self.rewrite(["machines", "tuf", "docker", "logs", "api", "--tail", "5"])
                == ["machines", "docker", "logs", "tuf", "api", "--tail", "5"])
    }

    @Test func theOldMachineLastOrderStillParsesUntouched() {
        for words in [
            ["machines", "docker", "ps", "tuf"], ["machines", "files", "ls", "tuf", "/etc"],
            ["machines", "show", "tuf"], ["machines", "ls"],
        ] {
            #expect(Self.rewrite(words) == words)
        }
    }

    @Test func aMachineNameAloneUnderMachinesShowsIt() {
        #expect(Self.rewrite(["machines", "tuf"]) == ["machines", "show", "tuf"])
        #expect(
            Self.rewrite(["machines", "tuf", "--json"])
                == ["machines", "show", "tuf", "--json"])
    }

    @Test func aFreeCommandAfterTheMachineBecomesAnExec() {
        #expect(
            Self.rewrite(["machines", "tuf", "uptime"])
                == ["machines", "exec", "tuf", "--", "uptime"])
        #expect(
            Self.rewrite(["machines", "tuf", "exec", "uptime"])
                == ["machines", "exec", "tuf", "--", "uptime"])
        #expect(
            Self.rewrite(["machines", "tuf", "run", "ls", "-la"])
                == ["machines", "run", "tuf", "--", "ls", "-la"])
    }

    @Test func anUnknownMachineIsStillMovedSoTheErrorNamesIt() {
        #expect(
            Self.rewrite(["machines", "typo", "docker", "ps"])
                == ["machines", "docker", "ps", "typo"])
        #expect(Self.rewrite(["machines", "lss"]) == ["machines", "show", "lss"])
    }

    @Test func aSubcommandNameAlwaysWinsOverAMachineCalledTheSame() {
        let colliding = ["ls", "docker", "exec"]
        #expect(
            ArgumentRewriting.rewrite(["machines", "ls"], machines: colliding) == [
                "machines", "ls",
            ])
        #expect(
            ArgumentRewriting.rewrite(["machines", "docker", "ps", "ls"], machines: colliding)
                == ["machines", "docker", "ps", "ls"])
        #expect(
            ArgumentRewriting.rewrite(["machines", "show", "docker"], machines: colliding)
                == ["machines", "show", "docker"])
    }

    @Test func aFlagStraightAfterMachinesIsNeverAMachineName() {
        #expect(Self.rewrite(["machines", "--help"]) == ["machines", "--help"])
        #expect(Self.rewrite(["machines"]) == ["machines"])
    }

    @Test func completionSeesTheSameOrderTheParserWill() {
        #expect(
            ArgumentRewriting.completionOrder(["machines", "tuf", "docker"])
                == ["machines", "docker", "tuf"])
        #expect(ArgumentRewriting.completionOrder(["machines", "tuf"]) == ["machines", "tuf"])
        #expect(ArgumentRewriting.completionOrder(["machines"]) == ["machines"])
        #expect(ArgumentRewriting.completionOrder(["config", "set"]) == ["config", "set"])
    }
}

@Suite struct CompletionInstallTargetTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    @Test func prefersADirectoryTheShellAlreadySearches() {
        let fpath = """
            /usr/share/zsh/site-functions
            /Users/someone/.zsh/completions
            /Users/someone/.docker/completions
            """
        let candidates = CompletionScripts.candidateDirectories(fromFpath: fpath, home: home)
        #expect(
            candidates.map(\.path) == [
                "/Users/someone/.zsh/completions", "/Users/someone/.docker/completions",
            ])
    }

    @Test func ignoresSystemDirectoriesItCannotWriteTo() {
        let fpath = """
            /usr/share/zsh/5.9/functions
            /opt/homebrew/share/zsh/site-functions
            """
        #expect(CompletionScripts.candidateDirectories(fromFpath: fpath, home: home).isEmpty)
    }

    @Test func fallsBackToTheDefaultLocationPerShell() {
        #expect(
            CompletionScripts.defaultDirectory(for: .zsh, home: home).path
                == "/Users/someone/.local/share/zsh/site-functions")
        #expect(
            CompletionScripts.defaultDirectory(for: .fish, home: home).path
                == "/Users/someone/.config/fish/completions")
    }

    @Test func asksTheShellOnceHoweverOftenTheAnswerIsRead() {
        let cache = FpathProbeCache()
        let found = home.appendingPathComponent(".zsh/completions")
        var probes = 0
        for _ in 0..<4 {
            let answer = cache.directory(forHome: home.path) {
                probes += 1
                return found
            }
            #expect(answer == found)
        }
        #expect(probes == 1)
    }

    @Test func remembersThatTheShellSearchesNowhereWritable() {
        let cache = FpathProbeCache()
        var probes = 0
        for _ in 0..<3 {
            #expect(
                cache.directory(forHome: home.path) {
                    probes += 1
                    return nil
                } == nil)
        }
        #expect(probes == 1)
    }

    @Test func asksAgainAfterAnInstallCouldHaveChangedTheAnswer() {
        let cache = FpathProbeCache()
        var probes = 0
        _ = cache.directory(forHome: home.path) {
            probes += 1
            return nil
        }
        cache.forgetEverything()
        _ = cache.directory(forHome: home.path) {
            probes += 1
            return nil
        }
        #expect(probes == 2)
    }

    @Test func answersEachHomeSeparately() {
        let cache = FpathProbeCache()
        var probes = 0
        for path in [home.path, "/Users/other", home.path] {
            _ = cache.directory(forHome: path) {
                probes += 1
                return nil
            }
        }
        #expect(probes == 2)
    }
}

@Suite struct CompletionsCommandShapeTests {
    @Test func everyShellIsReachableAsItsOwnSubcommand() throws {
        for name in ["zsh", "bash", "fish", "install"] {
            let parsed = try EdRoot.parseAsRoot(["completions", name])
            #expect(type(of: parsed).configuration.commandName == name)
        }
    }

    @Test func installIsNoLongerSwallowedByAPositionalShellArgument() throws {
        let parsed = try EdRoot.parseAsRoot(["completions", "install"])
        #expect(type(of: parsed).configuration.commandName == "install")
    }
}

@Suite struct RemoteDirectoryCompletionTests {
    @Test func asksForDirectoriesAfterAChangeDirectory() {
        #expect(RemoteCompletion.wantsDirectories(words: ["cd", ""], cursor: 1))
        #expect(RemoteCompletion.wantsDirectories(words: ["pushd", "s"], cursor: 1))
    }

    @Test func leavesOtherCommandsToTheRemoteShell() {
        #expect(!RemoteCompletion.wantsDirectories(words: ["ls", ""], cursor: 1))
        #expect(!RemoteCompletion.wantsDirectories(words: ["docker", "ps"], cursor: 1))
    }

    @Test func neverTreatsTheCommandItselfAsADirectory() {
        #expect(!RemoteCompletion.wantsDirectories(words: ["cd"], cursor: 0))
        #expect(!RemoteCompletion.wantsDirectories(words: [], cursor: 0))
    }

    @Test func listsOnlyDirectoriesForThePrefix() {
        let command = RemoteCompletion.directoriesCommand(prefix: "Desk")
        #expect(command.contains("compgen -d --"))
        #expect(command.contains("Desk"))
    }

    @Test func quotesAPrefixThatWouldOtherwiseRunSomething() {
        let command = RemoteCompletion.directoriesCommand(prefix: "$(touch /tmp/pwned)")
        #expect(command.contains("'$(touch /tmp/pwned)'"))
    }
}
