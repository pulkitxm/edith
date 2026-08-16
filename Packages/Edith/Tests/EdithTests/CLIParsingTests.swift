import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIParsingTests {
    static let commands = CommandCrawler.every()

    @Test func everyLeafCommandRejectsAFlagItDoesNotDefine() async {
        for walk in Self.commands
        where walk.type.configuration.subcommands.isEmpty
            && !Self.passthrough.contains(walk.label)
        {
            let result = await CLIProbe.run(walk.invocation + ["--definitely-not-a-flag"])
            #expect(result.code == ExitCodes.usage, "\(walk.label) exited \(result.code)")
        }
    }

    @Test func everyCommandWithARequiredArgumentSaysSoRatherThanCrashing() async {
        for walk in Self.commands where walk.type.configuration.subcommands.isEmpty {
            guard !CommandCrawler.requiredPositionals(walk.type).isEmpty else { continue }
            let result = await CLIProbe.run(walk.invocation)
            #expect(
                result.code == ExitCodes.usage,
                "`ed \(walk.invocation.joined(separator: " "))` exited \(result.code)")
            #expect(
                result.stderr.contains("Missing expected argument")
                    || result.stderr.contains("Usage:"),
                "`ed \(walk.invocation.joined(separator: " "))` said nothing useful")
        }
    }

    @Test func anUnknownTopLevelCommandIsAUsageError() async {
        let result = await CLIProbe.run(["definitelynotacommand"])
        #expect(result.code == ExitCodes.usage)
        #expect(result.stdout.isEmpty)
    }

    static let passthrough: Set<String> = [
        "ed __complete", "ed machines exec", "ed machines docker logs",
    ]

    @Test func helpIsSuccessForEveryCommand() async {
        for walk in Self.commands where !Self.passthrough.contains(walk.label) {
            let result = await CLIProbe.run(walk.invocation + ["--help"])
            #expect(result.code == 0, "`ed \(walk.label) --help` exited \(result.code)")
            #expect(result.stderr.isEmpty, "`ed \(walk.label) --help` complained")
        }
    }

    @Test func everyCommandCanRenderItsOwnHelp() {
        for walk in Self.commands {
            let help = CommandCrawler.help(walk.type)
            #expect(help.contains("USAGE:"), "\(walk.label) renders no usage line")
            #expect(
                help.contains(walk.type.configuration.abstract),
                "\(walk.label) help does not carry its abstract")
        }
    }

    @Test func everyCommandNamesItselfInItsOwnUsage() {
        for walk in Self.commands where walk.path.count > 1 {
            let usage = CommandCrawler.usageLine(walk.type)
            #expect(
                usage.contains(CommandCrawler.name(of: walk.type)),
                "\(walk.label) usage line does not name the command: \(usage)")
        }
    }

    @Test func theTerminatorLetsARemoteCommandUseFlagsOfItsOwn() throws {
        let parsed = try EdRoot.parseAsRoot(["machines", "exec", "tuf", "--", "ls", "-la"])
        let exec = try #require(parsed as? MachinesExecCommand)
        #expect(exec.machine == "tuf")
        #expect(MachinesExecCommand.strippingSeparator(exec.command) == ["ls", "-la"])
    }

    @Test func aRemoteCommandWithNoWordsIsRejectedBeforeAnySSH() async {
        let result = await CLIProbe.run(["machines", "exec", "tuf"])
        #expect(result.code == ExitCodes.failure)
        #expect(result.stderr.contains("name a command to run"))
    }

    @Test func flagAbbreviationsDoNotSilentlyPickTheWrongOption() async {
        let result = await CLIProbe.run(["config", "ls", "--js"])
        #expect(result.code == ExitCodes.usage)
    }
}

@Suite struct CLIValueValidationTests {
    @Test func anUnknownConfigKeyIsNotFoundAndSuggestsNeighbours() async {
        let result = await CLIProbe.run(["config", "get", "preventSlep"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("no setting named preventSlep"))
        #expect(result.stderr.contains("did you mean") || result.stderr.contains("config ls"))
    }

    @Test func anUnknownConfigGroupIsNotFoundAndListsTheRealOnes() async {
        let result = await CLIProbe.run(["config", "ls", "--group", "nowhere"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("groups:"))
    }

    @Test func anUnknownUsageRangeIsNotFoundAndListsTheRealOnes() async {
        for arguments in [
            ["usage", "summary", "--range", "decade"],
            ["usage", "daily", "--range", "decade"],
            ["usage", "models", "--range", "decade"],
            ["usage", "projects", "--range", "decade"],
        ] {
            let result = await CLIProbe.run(arguments)
            #expect(result.code == ExitCodes.notFound, "\(arguments) exited \(result.code)")
            #expect(result.stderr.contains("ranges:"))
        }
    }

    @Test func anUnknownExtensionIsNotFoundAndListsTheRealOnes() async {
        let result = await CLIProbe.run(["extensions", "enable", "teleporter"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("known ids:"))
    }

    @Test func anUnknownPermissionIsNotFoundAndListsTheRealOnes() async {
        let result = await CLIProbe.run(["permissions", "request", "telepathy"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("known:"))
    }

    @Test func anUnknownShellIsNotFound() async {
        let result = await CLIProbe.run(["completions", "install", "--shell", "klingon"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("not a supported shell"))
    }

    @Test func anUnknownGuideTopicIsNotFound() async {
        let result = await CLIProbe.run(["guide", "quantum"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("ed guide claude"))
    }

    @Test func aVolumeOutsideZeroToOneIsRejected() async {
        for level in ["5", "1.0001", "99"] {
            let result = await CLIProbe.run(["music", "volume", level])
            #expect(result.code == ExitCodes.usage, "volume \(level) exited \(result.code)")
            #expect(result.stderr.contains("between 0 and 1"))
        }
    }

    @Test func aVolumeThatIsNotANumberIsAUsageError() async {
        let result = await CLIProbe.run(["music", "volume", "loud"])
        #expect(result.code == ExitCodes.usage)
    }

    @Test func aNegativeDayCountIsRejectedBeforeTheAppIsAsked() async {
        let result = await CLIProbe.run(["calendar", "ls", "--days=-3"])
        #expect(result.code == ExitCodes.usage)
        #expect(result.stderr.contains("--days cannot be negative"))
    }

    @Test func aNegativeProjectLimitIsRejected() async {
        let result = await CLIProbe.run(["usage", "projects", "--limit=-1"])
        #expect(result.code == ExitCodes.usage)
        #expect(result.stderr.contains("--limit must be greater than zero"))
    }

    @Test func aNonPositiveSampleIntervalIsRejected() async {
        for arguments in [
            ["system", "stats", "--interval", "0"],
            ["machines", "metrics", "--interval=-2", "somewhere"],
        ] {
            let result = await CLIProbe.run(arguments)
            #expect(result.code == ExitCodes.usage, "\(arguments) exited \(result.code)")
            #expect(result.stderr.contains("--interval must be greater than zero"))
        }
    }

    @Test func aNegativeProcessCountIsRejected() async {
        let result = await CLIProbe.run(["system", "stats", "--processes=-4"])
        #expect(result.code == ExitCodes.usage)
        #expect(result.stderr.contains("--processes cannot be negative"))
    }

    @Test func aNegativeLogTailIsRejectedBeforeAnySSH() async {
        let result = await CLIProbe.run([
            "machines", "docker", "logs", "--tail=-10", "somewhere", "api",
        ])
        #expect(result.code == ExitCodes.usage)
        #expect(result.stderr.contains("--tail cannot be negative"))
    }

    @Test func aMachineNameThatCannotExistIsNotFoundRatherThanAHang() async {
        for arguments in [
            ["machines", "show", "no-such-machine-anywhere"],
            ["machines", "connect", "no-such-machine-anywhere"],
            ["machines", "disconnect", "no-such-machine-anywhere"],
            ["machines", "files", "ls", "no-such-machine-anywhere"],
            ["machines", "docker", "ps", "no-such-machine-anywhere"],
        ] {
            let result = await CLIProbe.run(arguments)
            #expect(
                result.code == ExitCodes.notFound,
                "`ed \(arguments.joined(separator: " "))` exited \(result.code)")
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func aMissingImportFileIsNotFound() async {
        let result = await CLIProbe.run(["config", "import", "/nonexistent/settings.json"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("could not read"))
    }

    @Test func aFileThatIsNotJSONFailsRatherThanApplyingNothingQuietly() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-import-\(UUID().uuidString).json")
        try Data("not json at all".utf8).write(to: url)
        let result = await CLIProbe.run(["config", "import", url.path])
        #expect(result.code == ExitCodes.failure)
        #expect(result.stderr.contains("not a JSON object"))
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite struct CLIExitCodeTests {
    @Test func theKindsMapOntoTheDocumentedCodes() {
        #expect(CLIFailure("x").kind.rawValue == ExitCodes.failure)
        #expect(CLIFailure.notFound("x").kind.rawValue == ExitCodes.notFound)
        #expect(CLIFailure.unavailable("x").kind.rawValue == ExitCodes.unavailable)
        #expect(ExitCodes.usage == 2)
    }

    @Test func aParseFailureBecomesTheDocumentedUsageCode() {
        let error = ValidationError("nope")
        #expect(ExitCodes.code(for: error) == ExitCodes.usage)
    }

    @Test func aCleanExitIsSuccess() {
        #expect(ExitCodes.code(for: CleanExit.message("done")) == 0)
    }

    @Test func helpIsHandledByTheParserRatherThanBecomingAnError() throws {
        let parsed = try EdRoot.parseAsRoot(["--help"])
        #expect(!(parsed is EdRoot))
    }

    @Test func aRemoteStatusIsPassedThroughUntouched() {
        #expect(ExitCodes.code(for: ExitCode(64)) == 64)
        #expect(ExitCodes.code(for: ExitCode(137)) == 137)
    }

    @Test func everyFailureKindSurvivesTheExecuteWrapper() async {
        for kind in [CLIFailure.Kind.failure, .notFound, .unavailable] {
            let result = await CLIProbe.isolate {
                try await execute { throw CLIFailure(kind, "boom") }
            }
            #expect(result.code == kind.rawValue)
            #expect(result.stderr.contains("error: boom"))
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func anUnexpectedErrorStillExitsOne() async {
        struct Odd: Error {}
        let result = await CLIProbe.isolate { try await execute { throw Odd() } }
        #expect(result.code == ExitCodes.failure)
        #expect(result.stderr.hasPrefix("error: "))
    }

    @Test func aFailureIsReportedOnStderrWithItsHint() async {
        let result = await CLIProbe.run(["config", "get", "nothinglikethis"])
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.hasPrefix("error: "))
        #expect(result.stderr.contains("hint: "))
    }
}
