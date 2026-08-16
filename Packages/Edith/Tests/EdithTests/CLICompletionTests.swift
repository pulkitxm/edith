import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLICompletionTests {
    static let machines = ["Asus TUF 7", "tuf"]
    static let extensionIDs = ExtensionRegistry.entries.map(\.id)

    static func plan(_ words: [String], _ index: Int) -> CompletionResult {
        CompletionEngine.plan(
            CompletionRequest(words: words, index: index), machines: machines,
            configKeys: ConfigCatalog.keys, extensionIDs: extensionIDs)
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

    @Test func lidAwakeCommandsAndFlagsComplete() {
        let commands = Self.plan(["ed", "lid-awake", ""], 2)
        #expect(commands.candidates == ["status", "on", "off", "battery", "restore-on-quit"])
        let flags = Self.plan(["ed", "lid-awake", "on", "--u"], 3)
        #expect(flags.candidates == ["--until-lid-reopens"])
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
