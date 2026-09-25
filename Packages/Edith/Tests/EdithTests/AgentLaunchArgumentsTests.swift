import Foundation
import Testing

@testable import EdithKit

@Suite struct AgentLaunchArgumentsTests {
    private func build(_ kind: AgentLaunchKind, _ options: AgentLaunchOptions) throws -> [String] {
        try AgentLaunchArguments.arguments(options, in: kind.builtIn)
    }

    private func rejection(_ kind: AgentLaunchKind, _ options: AgentLaunchOptions)
        -> AgentLaunchOptionsError?
    {
        do {
            try AgentLaunchArguments.validate(options, in: kind.builtIn)
            return nil
        } catch {
            return error as? AgentLaunchOptionsError
        }
    }

    @Test func claudeCarriesModelEffortAndFastSettings() throws {
        #expect(
            try build(.claude, AgentLaunchOptions(model: "opus", effort: "high", fast: true))
                == ["--model", "opus", "--effort", "high", "--settings", #"{"fastMode":true}"#])
        #expect(
            try build(.claude, AgentLaunchOptions(fast: true)) == [
                "--settings", #"{"fastMode":true}"#,
            ])
        #expect(
            try build(.claude, AgentLaunchOptions(model: "claude-opus-5-5")) == [
                "--model", "claude-opus-5-5",
            ])
        #expect(try build(.claude, .none).isEmpty)
    }

    @Test func codexUsesConfigOverridesForEffortAndFast() throws {
        #expect(
            try build(.codex, AgentLaunchOptions(model: "gpt-6-sol", effort: "xhigh", fast: true))
                == [
                    "-m", "gpt-6-sol", "-c", #"model_reasoning_effort="xhigh""#, "-c",
                    #"service_tier="fast""#,
                ])
        #expect(
            try build(.codex, AgentLaunchOptions(model: "gpt-custom", effort: "high"))
                == ["-m", "gpt-custom", "-c", #"model_reasoning_effort="high""#])
    }

    @Test func theOtherKindsUseTheirOwnFlags() throws {
        #expect(
            try build(.pi, AgentLaunchOptions(model: "acme/reasoner-1", effort: "minimal"))
                == ["--model", "acme/reasoner-1", "--thinking", "minimal"])
        #expect(try build(.pi, AgentLaunchOptions(effort: "off")) == ["--thinking", "off"])
        #expect(try build(.cursor, AgentLaunchOptions(model: "auto")) == ["--model", "auto"])
        #expect(try build(.gemini, AgentLaunchOptions(model: "pro")) == ["-m", "pro"])
        #expect(try build(.amp, AgentLaunchOptions(model: "ultra")) == ["--mode", "ultra"])
        #expect(try build(.opencode, .none).isEmpty)
    }

    @Test func invalidCombinationsAreRejected() {
        #expect(
            rejection(.claude, AgentLaunchOptions(model: "sonnet", fast: true))
                == .fastUnsupported(model: "sonnet"))
        #expect(
            rejection(.claude, AgentLaunchOptions(model: "haiku", effort: "high"))
                == .effortUnsupported("high", model: "haiku", allowed: []))
        #expect(
            rejection(.codex, AgentLaunchOptions(model: "gpt-5.5", effort: "ultra"))
                == .effortUnsupported(
                    "ultra", model: "gpt-5.5", allowed: ["low", "medium", "high", "xhigh"]))
        #expect(rejection(.cursor, AgentLaunchOptions(model: "auto", fast: true)) != nil)
        #expect(rejection(.gemini, AgentLaunchOptions(effort: "high")) != nil)
        #expect(
            rejection(.amp, AgentLaunchOptions(model: "turbo"))
                == .unknownModel(
                    "turbo", kind: "Amp", allowed: ["low", "medium", "high", "ultra"]))
        #expect(
            rejection(.opencode, AgentLaunchOptions(model: "acme/model-one"))
                == .notSelectable("OpenCode"))
        #expect(
            rejection(.claude, AgentLaunchOptions(model: "opus", effort: "max", fast: true)) == nil)
    }

    @Test func launchesDropWhatTheModelCannotTake() {
        let stored = AgentLaunchOptions(model: "sonnet", effort: "ultra", fast: true)
        #expect(
            AgentLaunchArguments.sanitized(stored, in: AgentLaunchKind.claude.builtIn)
                == AgentLaunchOptions(model: "sonnet"))
        #expect(
            AgentLaunchArguments.launchArguments(kind: "Claude Code", options: stored)
                == ["--model", "sonnet"])
        #expect(
            AgentLaunchArguments.launchArguments(
                kind: "Amp", options: AgentLaunchOptions(model: "turbo")
            ).isEmpty)
        #expect(
            AgentLaunchArguments.launchArguments(
                kind: "OpenCode", options: AgentLaunchOptions(model: "acme/model-one")
            ).isEmpty)
        #expect(
            AgentLaunchArguments.launchArguments(
                kind: "Copilot CLI", options: AgentLaunchOptions(model: "anything")
            ).isEmpty)
    }

    @Test func aLiveCatalogDecidesWhatALaunchMayUse() throws {
        let catalog = try #require(
            AgentLaunchCatalogParser.catalog(.codex, from: AgentLaunchCatalogTests.codexJSON))
        let options = AgentLaunchOptions(model: "alpha-mini", effort: "high", fast: true)
        #expect(
            AgentLaunchArguments.launchArguments(kind: "codex", options: options, catalog: catalog)
                == ["-m", "alpha-mini"])
    }

    @Test func emptyStringsMeanNoChoice() {
        #expect(AgentLaunchOptions(model: "", effort: "").isEmpty)
    }

    @Test func agentStartAppendsAgentArgumentsAfterADoubleDash() {
        let arguments = ["--model", "opus", "--settings", #"{"fastMode":true}"#]
        #expect(
            HerdrAgentStartCommand.arguments(
                name: "claude", kindSlug: "claude", pane: "w1:p1", timeoutMS: 30_000,
                agentArguments: arguments)
                == [
                    "agent", "start", "claude", "--kind", "claude", "--pane", "w1:p1",
                    "--timeout", "30000", "--",
                ] + arguments)
        #expect(
            !HerdrAgentStartCommand.arguments(
                name: "claude", kindSlug: "claude", pane: "w1:p1", timeoutMS: 30_000
            ).contains("--"))
    }

    @Test func posixShellLinesQuoteTheJSONSettings() {
        let line = HerdrAgentStartCommand.shellLine(
            name: "codex", kindSlug: "codex", pane: "w1:p1", timeoutMS: 30_000,
            agentArguments: ["-c", #"service_tier="fast""#, "--settings", #"{"fastMode":true}"#],
            platform: .linux)
        #expect(
            line.hasSuffix(
                #"--timeout 30000 -- -c 'service_tier="fast"' --settings '{"fastMode":true}'"#))
    }

    @Test func powerShellLinesEscapeQuotesForNativeArguments() throws {
        let line = HerdrAgentStartCommand.shellLine(
            name: "claude", kindSlug: "claude", pane: "w1:p1", timeoutMS: 30_000,
            agentArguments: ["--settings", #"{"fastMode":true}"#], platform: .windows)
        let encoded = try #require(line.components(separatedBy: " ").last)
        let data = try #require(Data(base64Encoded: encoded))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(script.contains(#"'--', '--settings', '{\"fastMode\":true}'"#))
    }

    @Test func nativeArgumentEscapingFollowsWindowsRules() {
        #expect(PowerShell.nativeArgument("plain") == "plain")
        #expect(PowerShell.nativeArgument(#"{"a":1}"#) == #"{\"a\":1}"#)
        #expect(PowerShell.nativeArgument(#"a\"b"#) == #"a\\\"b"#)
        #expect(PowerShell.nativeArgument(#"C:\tools\bin\"#) == #"C:\tools\bin\"#)
        #expect(PowerShell.nativeArgument(#"C:\My Dir\"#) == #"C:\My Dir\\"#)
    }

    @Test func paneRunTextAppendsQuotedFlagsForTheShell() {
        let flags = ["--model", "opus", "--settings", #"{"fastMode":true}"#]
        #expect(
            HerdrPaneRunCommand.commandText("CC", appending: flags)
                == #"CC --model opus --settings '{"fastMode":true}'"#)
        #expect(
            HerdrPaneRunCommand.commandText("CC", appending: flags, platform: .windows)
                == #"CC '--model' 'opus' '--settings' '{\"fastMode\":true}'"#)
        #expect(HerdrPaneRunCommand.commandText("", appending: flags) == "")
        #expect(HerdrPaneRunCommand.commandText("CC", appending: []) == "CC")
    }
}
