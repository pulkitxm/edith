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

    private static func scratchDefaults() -> UserDefaults {
        let suite = "HerdrLaunchSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
