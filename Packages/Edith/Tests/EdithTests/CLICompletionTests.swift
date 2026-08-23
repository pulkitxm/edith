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
        quinjetSessions: [String] = []
    ) -> CompletionResult {
        CompletionEngine.plan(
            CompletionRequest(words: words, index: index), machines: machines,
            configKeys: ConfigCatalog.keys, extensionIDs: extensionIDs,
            usageSources: usageSources, quinjetSessions: quinjetSessions)
    }

    @Test func theTopLevelOffersCommandsAndMachines() {
        let result = Self.plan(["ed", ""], 1)
        #expect(result.candidates.contains("config"))
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
            ["ed", "music", "--player", "spotify", "status", "--player", ""], 6)
        #expect(nested.candidates == MusicPlayer.allCases.map(\.rawValue))
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

    @Test func bashAndZshScriptsInvokeTheRealCompletionEntry() throws {
        let outside = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let bashScript = outside.appendingPathComponent("ed.bash")
        let zshScript = outside.appendingPathComponent("_ed")
        try CompletionScripts.script(for: .bash, tool: CLIProcessProbe.binary.path)
            .write(to: bashScript, atomically: true, encoding: .utf8)
        try CompletionScripts.script(for: .zsh, tool: CLIProcessProbe.binary.path)
            .write(to: zshScript, atomically: true, encoding: .utf8)

        let bash = try CLIProcessProbe.run(
            [
                "-c",
                "source \"$1\"; COMP_WORDS=(ed music status --player \"\"); "
                    + "COMP_CWORD=4; _ed_complete; printf '%s\\n' \"${COMPREPLY[@]}\"",
                "completion-test", bashScript.path,
            ], executable: URL(fileURLWithPath: "/bin/bash"), currentDirectory: outside)
        let zsh = try CLIProcessProbe.run(
            [
                "-c",
                "compdef() { :; }; compadd() { print -l -- \"$@\"; }; source \"$1\"; "
                    + "words=(ed music status --player ''); CURRENT=5; _ed_complete",
                "completion-test", zshScript.path,
            ], executable: URL(fileURLWithPath: "/bin/zsh"), currentDirectory: outside)

        #expect(bash.code == 0)
        #expect(Set(bash.stdoutLines) == Set(MusicPlayer.allCases.map(\.rawValue)))
        #expect(zsh.code == 0)
        #expect(Set(zsh.stdoutLines).isSuperset(of: Set(MusicPlayer.allCases.map(\.rawValue))))
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
