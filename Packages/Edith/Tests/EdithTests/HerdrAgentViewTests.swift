import EdithKit
import Foundation
import Testing

@testable import Edith

@Suite struct HerdrAgentViewTests {
    @Test func defaultsToTheAgentSession() {
        let defaults = Self.defaults()
        #expect(HerdrAgentViews.view(for: "local|default|%1", defaults) == .agent)
        #expect(HerdrAgentViews.stored(defaults).isEmpty)
    }

    @Test func remembersDiffPerAgent() {
        let defaults = Self.defaults()
        HerdrAgentViews.set(.diff, for: "local|default|%1", defaults)
        HerdrAgentViews.set(.diff, for: "tuf|default|wN:p4", defaults)
        #expect(HerdrAgentViews.view(for: "local|default|%1", defaults) == .diff)
        #expect(HerdrAgentViews.view(for: "tuf|default|wN:p4", defaults) == .diff)
        #expect(HerdrAgentViews.view(for: "other|default|%9", defaults) == .agent)
    }

    @Test func returningToTheAgentClearsTheEntry() {
        let defaults = Self.defaults()
        HerdrAgentViews.set(.diff, for: "local|default|%1", defaults)
        HerdrAgentViews.set(.agent, for: "local|default|%1", defaults)
        #expect(HerdrAgentViews.view(for: "local|default|%1", defaults) == .agent)
        #expect(defaults.dictionary(forKey: HerdrAgentViews.key) == nil)
    }

    @Test func ignoresUnknownStoredValues() {
        let defaults = Self.defaults()
        defaults.set(["local|default|%1": "sidebar"], forKey: HerdrAgentViews.key)
        #expect(HerdrAgentViews.view(for: "local|default|%1", defaults) == .agent)
        #expect(HerdrAgentViews.stored(defaults).isEmpty)
    }

    @Test func titlesMatchTheButtonPair() {
        #expect(HerdrAgentView.diff.title == "Open diff")
        #expect(HerdrAgentView.agent.title == "Open agent")
    }

    private static func defaults() -> UserDefaults {
        let suite = "HerdrAgentViewTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
