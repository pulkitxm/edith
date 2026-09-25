import Foundation
import Testing

@testable import EdithKit

@Suite struct HerdrLaunchSettingsTests {
    @Test func everyFilterKindExceptFXHasADefaultSlug() {
        let withSlugs = HerdrKind.filterLabels.filter {
            HerdrLaunchSettings.defaultHerdrSlug(for: $0) != nil
        }
        #expect(Set(withSlugs) == Set(HerdrKind.filterLabels).subtracting(["FX.sh"]))
        #expect(HerdrLaunchSettings.defaultHerdrSlug(for: "FX.sh") == nil)
        #expect(HerdrLaunchSettings.defaultHerdrSlug(for: "Claude Code") == "claude")
    }

    @Test func commandFallsBackToTheDefaultSlugWhenUnset() {
        let defaults = Self.scratchDefaults()
        #expect(HerdrLaunchSettings.command(for: "Claude Code", in: defaults) == "claude")
        #expect(HerdrLaunchSettings.command(for: "FX.sh", in: defaults) == "")
    }

    @Test func setAndResetRoundTripThroughDefaults() {
        let defaults = Self.scratchDefaults()
        HerdrLaunchSettings.setCommand("CC", for: "Claude Code", in: defaults)
        #expect(HerdrLaunchSettings.command(for: "Claude Code", in: defaults) == "CC")
        #expect(HerdrLaunchSettings.command(for: "Codex", in: defaults) == "codex")

        HerdrLaunchSettings.resetToDefault(for: "Claude Code", in: defaults)
        #expect(HerdrLaunchSettings.command(for: "Claude Code", in: defaults) == "claude")
    }

    @Test func usesHerdrAgentStartTracksWhetherTheCommandWasOverridden() {
        let defaults = Self.scratchDefaults()
        #expect(HerdrLaunchSettings.usesHerdrAgentStart(for: "Claude Code", in: defaults))
        #expect(!HerdrLaunchSettings.usesHerdrAgentStart(for: "FX.sh", in: defaults))

        HerdrLaunchSettings.setCommand("CC", for: "Claude Code", in: defaults)
        #expect(!HerdrLaunchSettings.usesHerdrAgentStart(for: "Claude Code", in: defaults))

        HerdrLaunchSettings.setCommand("claude", for: "Claude Code", in: defaults)
        #expect(HerdrLaunchSettings.usesHerdrAgentStart(for: "Claude Code", in: defaults))
    }

    @Test func launchOptionsRoundTripAndClearWhenEmpty() {
        let defaults = Self.scratchDefaults()
        #expect(HerdrLaunchSettings.options(for: "Codex", in: defaults) == .none)

        let options = AgentLaunchOptions(model: "gpt-6-sol", effort: "high", fast: true)
        HerdrLaunchSettings.setOptions(options, for: "Codex", in: defaults)
        HerdrLaunchSettings.setOptions(
            AgentLaunchOptions(model: "pro"), for: "Gemini", in: defaults)
        #expect(HerdrLaunchSettings.options(for: "Codex", in: defaults) == options)
        #expect(
            HerdrLaunchSettings.options(for: "Gemini", in: defaults)
                == AgentLaunchOptions(model: "pro"))

        HerdrLaunchSettings.setOptions(.none, for: "Codex", in: defaults)
        #expect(HerdrLaunchSettings.options(for: "Codex", in: defaults) == .none)
        let stored = defaults.dictionary(forKey: AppStorageKeys.Herdr.launchDefaults)
        #expect(stored?.keys.sorted() == ["Gemini"])
    }

    @Test func ampLaunchesThroughHerdrAgentStart() {
        #expect(HerdrLaunchSettings.kinds.contains("Amp"))
        #expect(HerdrLaunchSettings.defaultHerdrSlug(for: "Amp") == "amp")
    }

    @Test func launchingWithDefaultsAppendsTheAgentFlags() {
        let defaults = Self.scratchDefaults()
        HerdrLaunchSettings.setOptions(
            AgentLaunchOptions(model: "opus", effort: "high", fast: true), for: "Claude Code",
            in: defaults)
        let launch = HerdrLaunchOperations.agentLaunch(
            kind: "Claude Code", name: "claude", pane: "w5:p1",
            options: HerdrLaunchSettings.options(for: "Claude Code", in: defaults),
            defaults: defaults)
        #expect(
            launch.local
                == [
                    "agent", "start", "claude", "--kind", "claude", "--pane", "w5:p1",
                    "--timeout", "30000", "--", "--model", "opus", "--effort", "high",
                    "--settings", #"{"fastMode":true}"#,
                ])
        #expect(launch.remote(.linux).hasSuffix(#"--settings '{"fastMode":true}'"#))
    }

    @Test func anOverriddenCommandGetsTheSameFlagsTyped() {
        let defaults = Self.scratchDefaults()
        HerdrLaunchSettings.setCommand("cx --yolo", for: "Codex", in: defaults)
        let launch = HerdrLaunchOperations.agentLaunch(
            kind: "Codex", name: "codex", pane: "w5:p1",
            options: AgentLaunchOptions(model: "gpt-6-sol", fast: true), defaults: defaults)
        #expect(
            launch.local
                == [
                    "pane", "run", "w5:p1",
                    #"cx --yolo -m gpt-6-sol -c 'service_tier="fast"'"#,
                ])
    }

    @Test func kindsWithoutOptionsLaunchUnchanged() {
        let defaults = Self.scratchDefaults()
        let launch = HerdrLaunchOperations.agentLaunch(
            kind: "Copilot CLI", name: "copilot", pane: "w5:p1",
            options: AgentLaunchOptions(model: "anything"), defaults: defaults)
        #expect(!launch.local.contains("--"))
        #expect(!launch.local.contains("anything"))
    }

    private static func scratchDefaults() -> UserDefaults {
        let suite = "HerdrLaunchSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
